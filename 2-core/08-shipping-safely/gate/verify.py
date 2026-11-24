"""Exercise the local TLS boundary, external alert, and recovery runbook."""

import argparse
import contextlib
import datetime
import http.client
import json
import re
import ssl
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "07-distributed-systems-fundamentals/gate"))
from verify import Cluster, baseline, until


class MissingAlert(Exception):
    pass


def event(message):
    print(f"{datetime.datetime.now(datetime.UTC).isoformat(timespec='milliseconds')} {message}", flush=True)


def tls_client(certs, identity=None, issuer=None):
    ctx = ssl.create_default_context(cafile=str(certs / "ca.crt"))
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    if identity:
        files = issuer or certs
        ctx.load_cert_chain(files / f"{identity}.crt", files / f"{identity}.key")
    return ctx


def command(port, tls, op, key, value=""):
    with contextlib.closing(http.client.HTTPSConnection("127.0.0.1", port, context=tls, timeout=2)) as conn:
        conn.request("POST", "/command", json.dumps({"Op": op, "Key": key, "Value": value}),
                     {"Content-Type": "application/json"})
        with conn.getresponse() as response:
            return response.status, response.read()


def flags(certs, name):
    return ["-ca", certs / "ca.crt", "-cert", certs / f"{name}.crt", "-key", certs / f"{name}.key"]


@contextlib.contextmanager
def process(args, log):
    with log.open("ab") as out:
        child = subprocess.Popen(args, stdout=out, stderr=out)
        try:
            yield child
        finally:
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
                raise
            if "DATA RACE" in log.read_text():
                raise AssertionError(f"race reported in {log.name}")


def start_gateway(stack, args, certs, active, log, port=0):
    offset = log.stat().st_size if log.exists() else 0
    upstream = active.read_text().rstrip("\n")
    child = stack.enter_context(process([
        args.bin / "gateway", "-listen", f"127.0.0.1:{port}", "-upstream", upstream,
        *flags(certs, "gateway"),
    ], log))

    def listen():
        if child.poll() is not None:
            raise AssertionError(f"gateway exited: {log.read_text()}")
        match = re.search(rb"listen=127\.0\.0\.1:(\d+)", log.read_bytes()[offset:])
        return int(match.group(1)) if match else None

    return until(listen, "gateway listening")


def observations(log):
    if not log.exists():
        return []
    lines = log.read_bytes().split(b"\n")[:-1]  # A concurrent append may leave an incomplete line.
    return [json.loads(line) for line in lines]


def verify_boundary(port, certs, other, key, secret):
    reader = tls_client(certs, "reader")
    writer = tls_client(certs, "writer")
    for ctx in (tls_client(certs), tls_client(certs, "reader", other)):
        try:
            status, _ = command(port, ctx, "get", key)
        # With TLS 1.3 the peer can close while the client is still writing
        # the HTTP body. The authorized requests below check the same listener.
        except (ssl.SSLError, BrokenPipeError, ConnectionResetError):
            continue
        raise AssertionError(f"invalid certificate reached HTTP: {status}")
    assert command(port, reader, "put", key, "refused")[0] == 403
    status, raw = command(port, writer, "put", key, secret)
    assert status == 200 and json.loads(raw) == {"found": True, "value": secret}
    status, raw = command(port, reader, "get", key)
    assert status == 200 and json.loads(raw) == {"found": True, "value": secret}
    event("TLS rejected missing and untrusted credentials; roles enforced read/write permissions")
    return reader


def game(args, root):
    pki, rogue = root / "pki", root / "other-ca"
    for out in (pki, rogue):
        subprocess.run(["bash", args.source / "ops/pki.sh", out], check=True, capture_output=True)
    gwlog, probes = root / "gateway.log", root / "probe.jsonl"
    active, known = root / "upstream", root / "known-upstream"
    missing = root / "unavailable.sock"
    key, secret = "ship-canary-key", "ship-canary-value-5c41f"
    expected = root / "expected"
    expected.write_text(secret)
    expected.chmod(0o600)
    with (Cluster(root, args.bin / "metad", args.bin / "metad-wal") as cluster,
          contextlib.ExitStack() as probe_stack, contextlib.ExitStack() as gateway):
        leader, _ = baseline(cluster)
        good = cluster.sock(leader)
        for path in (active, known):
            path.write_text(f"{good}\n")
        port = start_gateway(gateway, args, pki, active, gwlog)
        reader = verify_boundary(port, pki, rogue, key, secret)
        probe = probe_stack.enter_context(process([
            args.bin / ("broken-probe" if args.broken else "probe"),
            "-url", f"https://127.0.0.1:{port}/command", "-lookup", key,
            "-expect-file", expected, *flags(pki, "reader"),
            "-interval", "100ms", "-deadline", "900ms",
        ], probes))

        def rows():
            assert probe.poll() is None, f"probe stopped: {probes.read_text()}"
            return observations(probes)

        until(lambda: (data := rows()) and data[-1]["good"] == 4, "four healthy observations")
        event("baseline: four good observations in the window")
        index = len(rows())
        active.write_text(f"{missing}\n")
        event("fault: deployed a configuration with an unavailable upstream socket")
        gateway.close()
        start_gateway(gateway, args, pki, active, gwlog, port)

        def alert():
            observed = rows()[index:]
            for row in observed:
                if row.get("transition") == "firing":
                    return row
            if sum(row["status"] == 503 for row in observed) >= 4:
                raise MissingAlert("failed HTTP probes never triggered the alert")
            return None

        firing = until(alert, "availability alert to fire")
        failures = [row for row in rows()[index:] if row["attempt"] <= firing["attempt"] and row["reason"] != "good"]
        assert 2 <= len(failures) <= 4 and firing["good"] < 3 and firing["total"] == 4, firing
        until(lambda: any(row["status"] == 503 for row in rows()[index:]), "gateway upstream failure")
        event(f"alert: firing at attempt {firing['attempt']} ({firing['good']}/4 good)")
        assert not missing.exists() and good.is_socket()
        assert command(port, reader, "get", key)[0] == 503
        event("diagnosis: TLS and the gateway work; configured upstream socket is missing")
        subprocess.run(["bash", args.source / "ops/restore-upstream.sh", known, active], check=True)
        assert active.read_text() == f"{good}\n"
        event("rollback: restored the saved upstream configuration")
        restart = len(rows())
        gateway.close()
        start_gateway(gateway, args, pki, active, gwlog, port)

        cleared = until(lambda: next((row for row in rows()[restart:] if row.get("transition") == "clear"), None),
                        "availability alert to clear")
        returning = [row for row in rows()[restart:] if row["attempt"] <= cleared["attempt"] and row["reason"] == "good"]
        assert 1 <= len(returning) <= 4 and cleared["good"] >= 3, cleared
        status, raw = command(port, reader, "get", key)
        assert status == 200 and json.loads(raw) == {"found": True, "value": secret}
        event(f"recovery: alert cleared and the original value was readable ({cleared['good']}/4 good)")
        for log in (gwlog, probes, *(cluster.log_path(peer) for peer in cluster.ids)):
            log_text = log.read_text()
            assert all(item not in log_text for item in (secret, key, "PRIVATE KEY")), log.name
        event("privacy: gateway, probe, and peer logs omitted the synthetic key, value, and private-key material")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("bin", type=Path)
    parser.add_argument("--broken", action="store_true")
    args = parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="ship-", dir="/tmp") as root:
            game(args, Path(root))
    except MissingAlert as failure:
        print(f"FAIL {failure}")
        return 42
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
