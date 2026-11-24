# 14 Measure the fix under contention

## The problem

An optimization can improve a microbenchmark while requests still wait on the network. You need a matched end-to-end run.

## The mental model

The HTTP client sends open-loop traffic into Go. Go competes for one CPU while the wire crosses a shaped link to Rust. The CPU profile attributes CPU time. The paired measurements and qdisc counter show what the workload experienced.

## The pattern

Verify correctness first, attribute CPU time, change one implementation, and repeat the same offered workload. Keep error and send-lag checks with the p99 measurement.

## Build it

### Step 1. Prove the contract through both sockets

The smoke test starts the real data plane, sends the same frame in pieces, sends a bad header, then starts the real Switchyard HTTP API. It checks the bounded request size, the Rust acknowledgment, and the Go-side trace ancestry.

Create `wire/processes.py`.

<!-- file: wire/processes.py -->
~~~python
"""Helpers shared by the local wire drills."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request


@contextmanager
def running(command, log, env=None):
    with Path(log).open("w") as output:
        process = subprocess.Popen(command, stdout=output, stderr=output, env=env)
        try:
            yield process
        finally:
            process.terminate()
            try:
                process.wait(timeout=12)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def wait_for(process, log, parse, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for line in Path(log).read_text().splitlines():
            found = parse(line)
            if found is not None:
                return found
        if process.poll() is not None:
            break
        time.sleep(0.05)
    raise RuntimeError(f"startup failed: {Path(log).read_text()}")


def message(line, kind):
    try:
        event = json.loads(line)
    except ValueError:
        return None
    if event.get("msg") == kind:
        return event.get("addr")
    return None


def request(url, payload=None, headers=None):
    req = urllib.request.Request(url, data=payload, headers=headers or {})
    with urllib.request.urlopen(req, timeout=4) as response:
        return json.load(response)


def control_env(wire_target, trace=False, profile=False):
    return {
        **os.environ,
        "SWITCHYARD_DATABASE_URL": "",
        "LISTEN_ADDR": "127.0.0.1:0",
        "GRPC_ADDR": "127.0.0.1:0",
        "WIRE_TARGET": wire_target,
        "WIRE_TRACE": "1" if trace else "",
        "WIRE_PROFILE_ADDR": "127.0.0.1:0" if profile else "",
    }


def wait_http(process, log):
    address = wait_for(process, log, lambda line: message(line, "listening"))
    deadline = time.monotonic() + 8
    url = f"http://{address}"
    while time.monotonic() < deadline:
        try:
            if request(url + "/health")["status"] == "ok":
                return url
        except OSError:
            pass
        time.sleep(0.05)
    raise RuntimeError(f"HTTP readiness failed: {Path(log).read_text()}")
~~~

Create `wire/smoke.py`.

<!-- file: wire/smoke.py -->
~~~python
"""Exercise Rust framing and the actual Go HTTP endpoint over both transports."""

import argparse
from contextlib import closing
import json
from pathlib import Path
import socket
from tempfile import TemporaryDirectory
import urllib.error

from processes import control_env, request, running, wait_for, wait_http

FIXTURE = bytes.fromhex("03000000 117863d6 389d964c 6a6f62")


def need(condition, message):
    if not condition:
        raise RuntimeError(message)


def connect(transport, address):
    if transport == "tcp":
        host, port = address.rsplit(":", 1)
        return socket.create_connection((host, int(port)), timeout=2)
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(2)
    client.connect(address)
    return client


def read_exact(sock, length):
    chunks = bytearray()
    while len(chunks) < length:
        chunk = sock.recv(length - len(chunks))
        if not chunk:
            break
        chunks.extend(chunk)
    return bytes(chunks)


def check_socket(transport, address):
    with closing(connect(transport, address)) as conn:
        conn.sendall(FIXTURE[:3])
        conn.sendall(FIXTURE[3:] + FIXTURE)
        for _ in range(2):
            ack = read_exact(conn, 20)
            need(len(ack) == 20 and int.from_bytes(ack[12:], "little") == 3, "bad wire acknowledgment")

    with closing(connect(transport, address)) as conn:
        damaged = bytes([FIXTURE[0] ^ 1]) + FIXTURE[1:]
        conn.sendall(damaged)
        try:
            received = conn.recv(20)
        except ConnectionResetError:
            received = b""
        need(not received, "Rust acknowledged a damaged header")


def check_http(url, log):
    header = {"traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}
    need(request(url + "/wire", b"job", header) == {"bytes": 3}, "wire route returned wrong body")
    try:
        request(url + "/wire", b"x" * (96 * 1024 + 1))
    except urllib.error.HTTPError as error:
        need(error.code == 413, f"oversized wire request returned {error.code}")
    else:
        raise RuntimeError("wire route accepted an oversized request")

    expected_trace = "4bf92f3577b34da6a3ce929d0e0e4736"
    spans = {
        event["span"]: event for event in map(json.loads, log.read_text().splitlines())
        if "span" in event and event["trace"] == expected_trace
    }
    child, parent = spans["rust.exchange"], spans["POST /wire"]
    need(child["parent"] == parent["id"] and child["trace"] == parent["trace"], "broken span ancestry")


def main():
    args = argparse.ArgumentParser()
    args.add_argument("data_plane")
    args.add_argument("switchyard")
    parsed = args.parse_args()
    with TemporaryDirectory(prefix="wire-") as tmp:
        work = Path(tmp)
        for transport, listen in (("tcp", "127.0.0.1:0"), ("unix", str(work / "wire.sock"))):
            data_log = work / f"{transport}-data.log"
            with running([parsed.data_plane, transport, listen], data_log) as data:
                address = wait_for(data, data_log, lambda line: line.removeprefix(transport + " ") if line.startswith(transport + " ") else None)
                check_socket(transport, address)
                env = control_env(f"{transport}://{address}", trace=True)
                api_log = work / f"{transport}-api.log"
                with running([parsed.switchyard], api_log, env) as api:
                    check_http(wait_http(api, api_log), api_log)
            print(f"{transport}: split frames, corrupt header refusal, HTTP bounds, and span ancestry passed")


if __name__ == "__main__":
    main()
~~~

~~~text
tcp: split frames, corrupt header refusal, HTTP bounds, and span ancestry passed
unix: split frames, corrupt header refusal, HTTP bounds, and span ancestry passed
~~~

### Step 2. Run controlled pairs under fault and contention

Use the same data plane, wire body, CPU, offered load, and packet shaping for both modes. The Go process and its competitor share one CPU, and the competitor alternates four milliseconds of work and sleep. The lab shapes only the Rust container’s egress. The HTTP load enters an isolated Switchyard process using the memory backend; the timed route does not need PostgreSQL.

Create `wire/profile_gate.py`.

<!-- file: wire/profile_gate.py -->
~~~python
"""Measure the Go/Rust wire with a shaped lab link and CPU competition."""

import argparse
from contextlib import contextmanager
import csv
import os
from pathlib import Path
import random
import re
import subprocess
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from processes import control_env, message, running, wait_for, wait_http


PAYLOAD = "x" * (64 * 1024)
BURN = """
import time
while True:
    until = time.monotonic() + .004
    while time.monotonic() < until:
        pass
    time.sleep(.004)
"""


def checked(*argv, **kwargs):
    return subprocess.check_output(argv, text=True, stderr=subprocess.STDOUT, timeout=45, **kwargs).strip()


def need(condition, message):
    if not condition:
        raise RuntimeError(message)


@contextmanager
def shaped_data_plane(binary, image):
    name = f"c06-wire-{os.getuid()}-{os.getpid()}"
    try:
        checked("docker", "run", "-d", "--name", name, "--cap-add", "NET_ADMIN",
                "-p", "127.0.0.1::9000", image, "sleep", "infinity")
        checked("docker", "cp", binary, f"{name}:/tmp/data-plane")
        checked("docker", "exec", name, "ethtool", "-K", "eth0", "tso", "off", "gso", "off", "gro", "off")
        checked("docker", "exec", name, "tc", "qdisc", "replace", "dev", "eth0", "root",
                "netem", "delay", "1ms", "loss", "0.05%")
        checked("docker", "exec", "-d", name, "/tmp/data-plane", "tcp", "0.0.0.0:9000")
        address = checked("docker", "port", name, "9000/tcp")
        for _ in range(40):
            if ":9000" in checked("docker", "exec", name, "ss", "-ltn"):
                break
            time.sleep(.1)
        else:
            raise RuntimeError("Rust listener did not start")
        yield name, f"tcp://{address}"
    finally:
        subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False, timeout=15)


def cpu_ticks(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])


def capture_profile(base, path, seconds):
    with urllib.request.urlopen(f"http://{base}/debug/pprof/profile?seconds={seconds}", timeout=seconds + 10) as stream:
        path.write_bytes(stream.read())


def render(binary, profile, stem, flamegraph):
    top = checked("go", "tool", "pprof", "-top", "-nodecount=18", binary, profile)
    stem.with_suffix(".top.txt").write_text(top + "\n")
    stacks = subprocess.check_output(["go", "tool", "pprof", "-raw", binary, profile], timeout=20)
    folded = subprocess.check_output(["perl", str(flamegraph / "stackcollapse-go.pl")],
                                     input=stacks, timeout=20)
    with stem.with_suffix(".svg").open("wb") as output:
        subprocess.run(["perl", str(flamegraph / "flamegraph.pl"), "--title", stem.name],
                       input=folded, stdout=output, check=True, timeout=20)
    return top


def load(kload, base, rate, duration, file):
    command = [str(kload), "load", "--url", base, "--method", "POST", "--path", "/wire",
               "--body", PAYLOAD, "--rate", str(rate), "--duration", str(duration), "--out", str(file)]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=duration + 20)
    print(result.stdout, end="")
    need(result.returncode == 0, "kload failed or fell behind")
    with file.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    bad = [row["status"] for row in rows if row["status"] != "200"]
    need(len(rows) == rate * duration and not bad, f"unexpected responses: {len(rows)} rows, failures={bad[:10]}")


def matched_pair(kload, variants, target, cpu, rate, duration, out, pairs):
    rng = random.Random(606)
    for index in range(1, pairs + 1):
        order = list(variants)
        rng.shuffle(order)
        for mode in order:
            print(f"pair {index}: {mode}", flush=True)
            log = out / f"{mode}-{index}.log"
            env = control_env(target)
            env["GOMAXPROCS"] = "1"
            with running(["taskset", "-c", str(cpu), variants[mode]], log, env) as api:
                base = wait_http(api, log)
                load(kload, base, rate, 2, out / "warmup.csv")
                load(kload, base, rate, duration, out / mode / f"run-{index}.csv")


def profile_cases(kload, variants, target, cpu, rate, duration, out, flamegraph):
    for mode, binary in variants.items():
        log = out / f"{mode}-profile.log"
        env = control_env(target, profile=True)
        env["GOMAXPROCS"] = "1"
        with running(["taskset", "-c", str(cpu), binary], log, env) as api:
            base = wait_http(api, log)
            profile = wait_for(api, log, lambda line: message(line, "wire profiler listening"))
            load(kload, base, rate, 2, out / "warmup.csv")
            path = out / f"{mode}.pb.gz"
            with ThreadPoolExecutor(max_workers=1) as thread:
                result = thread.submit(capture_profile, profile, path, 2)
                load(kload, base, rate, max(duration, 3), out / f"{mode}-profile.csv")
                result.result()
        top = render(binary, path, out / mode, flamegraph)
        if mode == "slow":
            need("internal/wire.checksum" in top, f"baseline profile did not identify the checksum\n{top}")
        print(top)


def main():
    command = argparse.ArgumentParser(description=__doc__)
    command.add_argument("rust", type=Path)
    command.add_argument("slow", type=Path)
    command.add_argument("fast", type=Path)
    command.add_argument("output", type=Path)
    command.add_argument("--rate", type=int, default=95)
    command.add_argument("--duration", type=int, default=4)
    command.add_argument("--pairs", type=int, default=5)
    command.add_argument("--pilot", action="store_true")
    args = command.parse_args()

    need(args.rate > 0 and args.duration > 0 and args.pairs >= 2, "use a positive rate and at least two pairs")
    out = args.output.resolve()
    out.mkdir()
    for case in ("slow", "fast"):
        (out / case).mkdir()
    kload = Path(os.environ["KLOAD"]).resolve()
    flamegraph = Path(os.environ["FLAMEGRAPH_DIR"]).resolve()
    image = os.environ.get("WIRE_NET_IMAGE", "switchyard-wire-tools:lab")
    cpu = min(os.sched_getaffinity(0))
    variants = {"slow": args.slow.resolve(), "fast": args.fast.resolve()}

    with shaped_data_plane(args.rust.resolve(), image) as (box, target):
        with running(["taskset", "-c", str(cpu), "python3", "-c", BURN], out / "contention.log") as load_cpu:
            before = cpu_ticks(load_cpu.pid)
            print(f"CPU {cpu}, 4 ms busy / 4 ms sleep, {args.rate}/s, {args.duration} s, 64 KiB")
            if not args.pilot:
                profile_cases(kload, variants, target, cpu, args.rate, args.duration, out, flamegraph)
            matched_pair(kload, variants, target, cpu, args.rate, args.duration, out, args.pairs)
            delta = cpu_ticks(load_cpu.pid) - before
            need(load_cpu.poll() is None and delta > 0, "CPU competitor did not run")
            print(f"competitor used {delta} CPU ticks")

        stats = checked("docker", "exec", box, "tc", "-s", "qdisc", "show", "dev", "eth0")
        print(stats)
        match = re.search(r"dropped (\d+)", stats)
        need(match and int(match[1]) > 0, "qdisc reported no dropped packets")

    compare = checked(str(kload), "compare", out / "slow", out / "fast")
    (out / "comparison.txt").write_text(compare + "\n")
    print(compare)
    if not args.pilot:
        effect = re.search(r"p99 B - A: .*? 95% CI \[[^,]+, ([+-]?[\d.]+)\]", compare)
        need(effect and float(effect[1]) < 0, "p99 improvement was not resolved under this run's conditions")


if __name__ == "__main__":
    main()
~~~

Use the tools image from lesson 10. Set KLOAD to the executable you built in Core 02 and FLAMEGRAPH_DIR to the FlameGraph checkout from lesson 03. Use a fresh results directory. Then run the [extended gate](../gate/README.md).

~~~bash
export KLOAD=/path/to/kload
export FLAMEGRAPH_DIR=/path/to/FlameGraph
export WIRE_PROFILE_OUT="$(mktemp -d)/wire-profile"
bash /path/to/Blueprint/2-core/06-linux-networking-and-profiling/gate/run.sh "$PWD" --extended
~~~

~~~text
CPU 0, 4 ms busy / 4 ms sleep, 95/s, 4 s, 64 KiB
competitor used 3558 CPU ticks
qdisc netem 8006: root refcnt 17 limit 1000 delay 1ms loss 0.05%
 Sent 1511162 bytes 20821 pkt (dropped 8, overlimits 0 requeues 0)
p99 A (/tmp/tmp.rjyi0qfQLj/wire-profile/slow, 5 runs): 22.79 28.83 24.75 24.85 22.09 ms
p99 B (/tmp/tmp.rjyi0qfQLj/wire-profile/fast, 5 runs): 8.76 8.48 9.10 8.82 9.06 ms
p99 B - A: -15.81 ms, 95% CI [-17.97, -13.97] ms: B is faster
~~~

### Step 3. Read the profiles as CPU evidence

The profiles come from separate runs with the same offered load. The baseline graph puts the bitwise checksum in the wide part of the stack. The graphs use separate horizontal scales, so compare the total samples in the top tables before comparing widths. The optimized profile has 16 samples, which gives a coarse view of its remaining CPU work. Use the p99 comparison for the latency claim.

[Before flame graph](../images/wire-before.svg) · [After flame graph](../images/wire-after.svg)

~~~text
File: slow
     790ms 91.86% 91.86%      790ms 91.86%  switchyard/internal/wire.checksum (inline)
File: fast
      80ms 50.00% 50.00%       80ms 50.00%  internal/runtime/syscall/linux.Syscall6
~~~

<!-- run: bash "$BLUEPRINT_ROOT/2-core/06-linux-networking-and-profiling/gate/run.sh" "$PWD" -->

## Check it

Find the checksum in the baseline graph and compare what remains after the change. Read the p99 interval and the number of actual drops. Explain why a profile with fewer CPU samples cannot alone establish a p99 gain.

## If it goes wrong

If kload falls behind, use a pilot to find a rate the generator can keep up with, then use the same rate for both builds. If no packets were dropped, verify the interface and path before comparing the result.
