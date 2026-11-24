"""Run real metad peers and control their directed Unix-socket links."""

import argparse
import contextlib
import http.client
import http.server
import json
import os
import re
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


class MinorityAcknowledged(Exception):
    pass


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("peer", timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


def request(path, method, endpoint, data=None, timeout=2):
    with contextlib.closing(UnixHTTP(path, timeout)) as client:
        client.request(method, endpoint, body=data, headers={"Content-Type": "application/json"})
        with client.getresponse() as response:
            return response.status, response.read()


def until(check, description, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if value := check():
                return value
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(0.015)
    raise AssertionError(f"timed out waiting for {description}")


class Proxy(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class LinkHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.connection.settimeout(1)
        length = int(self.headers.get("Content-Length", 0))
        if self.path != "/raft" or not 0 < length <= 256 << 10:
            self.send_error(400)
            return
        payload = self.rfile.read(length)
        source = json.loads(payload)["From"]
        cluster, target = self.server.cluster, self.server.peer
        with cluster.lock:
            blocked = (source, target) in cluster.blocked
        status = 503
        if not blocked:
            try:
                status, _ = request(cluster.sock(target), "POST", "/raft", payload, 0.15)
            except (OSError, http.client.HTTPException):
                pass
        with contextlib.suppress(OSError):
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def log_message(self, *_):
        pass


class Cluster:
    ids = (1, 2, 3)

    def __init__(self, root, metad, writer):
        self.root = root
        self.metad = metad
        self.writer = writer
        self.processes = {}
        self.proxies = []
        self.lock = threading.Lock()
        self.blocked = set()

    def __enter__(self):
        try:
            for peer in self.ids:
                proxy = Proxy(str(self.root / f"link-{peer}"), LinkHandler)
                proxy.cluster, proxy.peer = self, peer
                thread = threading.Thread(target=proxy.serve_forever, kwargs={"poll_interval": 0.05})
                thread.start()
                self.proxies.append((proxy, thread))
            for peer in self.ids:
                self.start(peer)
            for peer in self.ids:
                until(lambda: self.status(peer), f"peer {peer} to listen")
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def __exit__(self, exc_type, *_):
        try:
            errors = []
            for peer in self.ids:
                try:
                    self.stop(peer, force=exc_type is not None)
                except Exception as error:
                    errors.append(error)
            if exc_type not in (None, MinorityAcknowledged):
                for peer in self.ids:
                    print(f"--- peer {peer} ---\n{self.log(peer)}", flush=True)
            if errors and exc_type is None:
                raise ExceptionGroup("failed to stop metad peers", errors)
        finally:
            for proxy, thread in self.proxies:
                proxy.shutdown()
                thread.join()
                proxy.server_close()
        return False

    def sock(self, peer):
        return self.root / f"peer-{peer}.sock"

    def wal(self, peer):
        return self.root / f"peer-{peer}.klog"

    def arm(self, peer):
        return self.root / f"writer-{peer}.arm"

    def log_path(self, peer):
        return self.root / f"peer-{peer}.log"

    def log(self, peer):
        path = self.log_path(peer)
        return path.read_text() if path.exists() else ""

    def args(self, peer, wal=None):
        routes = ",".join(str(self.root / f"link-{i}") for i in self.ids)
        return [
            str(self.metad), "-id", str(peer), "-listen", str(self.sock(peer)),
            "-peers", routes, "-wal", str(wal or self.wal(peer)), "-writer", str(self.writer),
        ]

    def start(self, peer):
        if self.processes.get(peer) is not None:
            raise AssertionError("peer already running")
        self.sock(peer).unlink(missing_ok=True)
        with self.log_path(peer).open("ab") as log:
            self.processes[peer] = subprocess.Popen(
                self.args(peer),
                env={**os.environ, "METAD_GATE_ARM": str(self.arm(peer))},
                stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
            )

    def stop(self, peer, force=False):
        child = self.processes.pop(peer, None)
        if child is None:
            return
        if child.poll() is None:
            if force:
                os.killpg(child.pid, signal.SIGKILL)
            else:
                child.send_signal(signal.SIGTERM)
        try:
            status = child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=5)
            raise
        if not force and status != 0:
            raise AssertionError(f"peer {peer} exited with {status}\n{self.log(peer)}")

    def isolate(self, peer, blocked):
        with self.lock:
            self.blocked = {(i, j) for i in self.ids for j in self.ids if i != j and peer in (i, j)} if blocked else set()

    def status(self, peer):
        code, payload = request(self.sock(peer), "GET", "/status")
        return json.loads(payload) if code == 200 else None

    def leader(self, choices=None):
        choices = choices if choices is not None else self.ids

        def elected():
            leaders = [s for peer in choices if (s := self.status(peer)) and s["Role"] == "leader"]
            return max(leaders, key=lambda s: s["Term"]) if leaders else None

        return until(elected, f"a leader among {choices}")

    def command(self, peer, op, key, value="", **fields):
        code, payload = request(
            self.sock(peer), "POST", "/command",
            json.dumps({"Op": op, "Key": key, "Value": value, **fields}).encode(),
        )
        return code, json.loads(payload) if payload else None

    def write(self, peer, key, value):
        status, result = self.command(peer, "put", key, value)
        assert (status, result) == (200, {"found": True, "value": value}), (status, result)

    def check_history(self):
        winners = {}
        applied = {}
        for peer in self.ids:
            run = self.log(peer)
            assert "DATA RACE" not in run, run
            for elected, term in re.findall(r"elected peer=(\d+) term=(\d+)", run):
                assert winners.setdefault(term, elected) == elected, f"two winners in term {term}"
            for source, index, term, digest in re.findall(
                r"applied peer=(\d+) index=(\d+) term=(\d+) digest=([0-9a-f]+)", run
            ):
                assert int(source) == peer, run
                assert applied.setdefault(index, (term, digest)) == (term, digest), (
                    f"different entries committed at index {index}"
                )
        assert winners and applied, "missing history"
        return len(winners), len(applied)


def baseline(cluster):
    leader = cluster.leader()
    peer, term = leader["ID"], leader["Term"]
    cluster.write(peer, "baseline", "kept")
    index = max(2, leader["Applied"] + 1)
    for other in cluster.ids:
        until(lambda: (s := cluster.status(other)) and s["Applied"] >= index, "baseline application")
    return peer, term


def run_smoke(cluster):
    peer, term = baseline(cluster)
    cluster.stop(peer, force=True)
    others = tuple(i for i in cluster.ids if i != peer)
    successor = cluster.leader(others)
    assert successor["Term"] > term
    cluster.start(peer)
    code, result = cluster.command(successor["ID"], "get", "baseline")
    assert (code, result) == (200, {"found": True, "value": "kept"}), (code, result)
    successor_index = cluster.status(successor["ID"])["Applied"]
    until(lambda: (s := cluster.status(peer)) and s["Applied"] >= successor_index, "restarted peer to replay")
    cluster.check_history()
    print("three Unix-socket peers applied the write")
    print("SIGKILL stopped the leader; a higher-term leader read the value")
    print("the restarted peer caught up")


def run_companion(cluster):
    peer, _ = baseline(cluster)
    cluster.isolate(peer, True)
    before = cluster.wal(peer).stat().st_size
    code, _ = cluster.command(peer, "put", "minority", "locally stored")
    assert cluster.wal(peer).stat().st_size > before, "the append never reached disk"
    if code == 200:
        raise MinorityAcknowledged("isolated leader acknowledged after local append")
    assert code == 504, f"expected quorum timeout after local save, got {code}"
    print("isolation: local append completed, but the client timed out without success")


def run_leases(cluster):
    peer, _ = baseline(cluster)
    status, a = cluster.command(peer, "acquire", "job", Owner="A", TTL=200)
    assert status == 200 and a["granted"] and a["token"] > 0, (status, a)

    def acquire_after_expiry():
        status, response = cluster.command(peer, "acquire", "job", Owner="B", TTL=5000)
        assert status == 200, (status, response)
        return response if response.get("granted") else None

    b = until(acquire_after_expiry, "A's lease to expire")
    assert b["token"] > a["token"]
    status, response = cluster.command(peer, "renew", "job", Owner="A", Token=a["token"], TTL=5000)
    assert status == 200 and not response.get("granted"), (status, response)
    print("client API: expiry allowed a higher grant; the old owner could not renew")


def run_torn(cluster, klog):
    peer, term = baseline(cluster)
    cluster.isolate(peer, True)
    prefix = cluster.wal(peer).read_bytes()
    assert prefix, "baseline never reached disk"
    cluster.arm(peer).touch()

    def propose():
        try:
            return cluster.command(peer, "put", "interrupted", "must disappear")[0]
        except (OSError, http.client.HTTPException):
            return None

    with ThreadPoolExecutor(max_workers=1) as callers:
        pending = callers.submit(propose)
        try:
            until(cluster.arm(peer).with_suffix(".ready").exists, "Rust writer's after-header barrier")
            torn = cluster.wal(peer).read_bytes()
            assert torn.startswith(prefix) and len(torn) - len(prefix) == 12, "expected header only"
            assert not pending.done(), "client returned before the crash"
        finally:
            cluster.stop(peer, force=True)
        assert pending.result(timeout=3) != 200, "interrupted proposal received success"
    print("SIGKILL: interrupted append left a 12-byte header and no client success")

    majority = tuple(i for i in cluster.ids if i != peer)
    successor = cluster.leader(majority)
    assert successor["Term"] > term
    cluster.write(successor["ID"], "majority", "committed")
    print("partition: the connected pair elected a higher-term leader and committed a write")

    cluster.start(peer)
    until(lambda: cluster.status(peer), "isolated peer to restart")
    assert re.search(rf"recovered peer={peer} bytes=12\b", cluster.log(peer)), cluster.log(peer)
    assert cluster.wal(peer).read_bytes().startswith(prefix), "repair changed the verified prefix"
    code, _ = cluster.command(peer, "put", "while-isolated", "must be refused")
    assert code == 409, f"isolated restart returned {code}"
    cluster.isolate(peer, False)
    # The restarted candidate may have incremented its term while isolated.
    # Wait for a leader that can actually commit a read after the links heal.
    def read_with_quorum(key, expected):
        def read():
            leader = cluster.leader()
            status, result = cluster.command(leader["ID"], "get", key)
            if status == 200:
                assert result == expected, (key, result)
                return cluster.status(leader["ID"])
            return None

        return until(read, f"a committed read of {key}")

    read_with_quorum("baseline", {"found": True, "value": "kept"})
    read_with_quorum("majority", {"found": True, "value": "committed"})
    last = read_with_quorum("interrupted", {"found": False})["Applied"]
    for other in cluster.ids:
        until(lambda: (s := cluster.status(other)) and s["Applied"] >= last, "all peers to apply the healed prefix")
    cluster.check_history()
    print("heal: trimmed the torn header, preserved the prefix, and agreed on elections and applied entries")
    print("client reads: both acknowledged writes survived and the interrupted key is absent")

    for other in cluster.ids:
        cluster.stop(other)
        subprocess.run([klog, "check", cluster.wal(other)], check=True, capture_output=True, timeout=5)
    print("disk: all three peer logs passed the Rust integrity check")

    damaged = cluster.root / "damaged.klog"
    contents = bytearray(cluster.wal(peer).read_bytes())
    contents[12] ^= 1
    damaged.write_bytes(contents)
    rejected = subprocess.run(cluster.args(peer, damaged), capture_output=True, timeout=5)
    assert rejected.returncode != 0 and b"Corrupt" in rejected.stderr, rejected.stderr
    assert damaged.read_bytes() == contents, "startup changed the damaged log"
    print("corruption: startup refused a complete damaged frame and preserved its bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("metad", type=Path)
    parser.add_argument("writer", type=Path)
    parser.add_argument("klog", type=Path)
    parser.add_argument("--only", choices=("smoke", "companion", "torn", "leases"))
    args = parser.parse_args()
    try:
        for scenario in ([args.only] if args.only else ("companion", "torn")):
            # Linux pathname sockets have a small address limit.
            with tempfile.TemporaryDirectory(prefix="metad-", dir="/tmp") as path:
                with Cluster(Path(path), args.metad.resolve(), args.writer.resolve()) as cluster:
                    if scenario == "smoke":
                        run_smoke(cluster)
                    elif scenario == "leases":
                        run_leases(cluster)
                    elif scenario == "companion":
                        run_companion(cluster)
                    else:
                        run_torn(cluster, args.klog.resolve())
    except MinorityAcknowledged as failure:
        print(f"FAIL {failure}")
        return 42
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
