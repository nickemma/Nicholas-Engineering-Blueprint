# 03 Measure throughput, latency, and memory

> Programmable edge proxy capstone · Week 2 · Builds on lesson 02

## The problem

The reload experiment verifies a serving invariant at one rate. Throughput and latency need a separate steady-state experiment over matched paths.

## The mental model

Keep the origin, protocol, 4 KiB object, warm-up, and schedule fixed. Measure the same direct, Rust, and Envoy paths as Part 02. Read Linux process VmRSS for the Rust proxy, and keep that scope separate from sidecar memory or container totals.

## The pattern

Collect scheduled-start latency, completed requests per second, errors, drops, and repeated trial ranges. Use a pilot to select the higher rate. Measure the Rust process at roughly 25 ms intervals, so the largest observed sample is a sampled peak.

## Build it

### Step 1 — Capture memory with each Rust trial

Read the proxy PID from the launcher. Sample in a joined background thread while the driver runs and log the profile scope. Keep direct and Envoy workload runs for comparison.

<details>
<summary>Implementation</summary>

Find these regions in `bench/run.py` in order.

<!-- edit: bench/run.py -->
~~~python
import socket
import subprocess
import time
from urllib.error import URLError
~~~

Replace the selected lines with this block.

~~~python
import socket
import subprocess
import threading
import time
from urllib.error import URLError
~~~

<!-- edit: bench/run.py -->
~~~python
                if not line:
                    raise RuntimeError(f"no startup address: {args[0]}")
                yield line
            else:
                yield child
~~~

Replace the selected lines with this block.

~~~python
                if not line:
                    raise RuntimeError(f"no startup address: {args[0]}")
                yield child, line
            else:
                yield child
~~~

<!-- edit: bench/run.py -->
~~~python


def trial(driver, address, stats, rate, seconds, path):
    before = json.loads(read(stats))
    raw = subprocess.check_output(
        [driver, "load", f"http://{address}{OBJECT}", str(rate), str(seconds)],
        env=ENV, timeout=seconds + 15,
    )
    after = json.loads(read(stats))
    data = json.loads(raw)
    data["origin"] = {key: after[key] - before[key] for key in before}
    with gzip.open(path, "wt", encoding="utf-8") as stream:
~~~

Replace the selected lines with this block.

~~~python


def vmrss(pid):
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        if line.startswith("VmRSS:"):
            _, count, unit = line.split()
            if unit == "kB":
                return int(count)
    raise RuntimeError(f"VmRSS unavailable for process {pid}")


@contextmanager
def sampling_rss(pid, interval=0.025):
    samples = []
    if pid is None:
        yield samples
        return
    start = time.monotonic_ns()
    stop = threading.Event()
    errors = []

    def sample():
        try:
            while not stop.is_set():
                elapsed = (time.monotonic_ns() - start) // 1000
                samples.append({"at_us": elapsed, "kib": vmrss(pid)})
                stop.wait(interval)
        except (OSError, RuntimeError) as error:
            errors.append(error)

    thread = threading.Thread(target=sample)
    thread.start()
    try:
        yield samples
    finally:
        stop.set()
        thread.join()
    if errors or len(samples) < 2:
        raise RuntimeError(f"RSS sampling failed for process {pid}: {errors}")


def trial(driver, address, stats, rate, seconds, path, pid):
    before = json.loads(read(stats))
    with sampling_rss(pid) as memory:
        raw = subprocess.check_output(
            [driver, "load", f"http://{address}{OBJECT}", str(rate), str(seconds)],
            env=ENV, timeout=seconds + 15,
        )
    after = json.loads(read(stats))
    data = json.loads(raw)
    data["proxy_rss"] = memory
    data["origin"] = {key: after[key] - before[key] for key in before}
    with gzip.open(path, "wt", encoding="utf-8") as stream:
~~~

<!-- edit: bench/run.py -->
~~~python
        "status_counts": dict(Counter(row["status"] for row in rows)),
        "origin": data["origin"],
        "raw": path.name,
    }
~~~

Replace the selected lines with this block.

~~~python
        "status_counts": dict(Counter(row["status"] for row in rows)),
        "origin": data["origin"],
        "sampled_peak_rss_kib": max((item["kib"] for item in memory), default=None),
        "rss_samples": len(memory),
        "raw": path.name,
    }
~~~

<!-- edit: bench/run.py -->
~~~python
def capture(args):
    args.out.mkdir()
    with process([args.driver, "origin"], stdout=subprocess.PIPE) as first:
        address, observer = first.split()
        stats = f"http://{observer}/stats"
        with process([args.driver, "origin"], stdout=subprocess.PIPE) as second:
            other, _ = second.split()
            with process(
                [args.proxy, "http", "127.0.0.1:0", address, other], stdout=subprocess.PIPE,
            ) as listening:
                rust = listening.removeprefix("listening ")
                run_comparison(args, address, stats, rust)


def run_comparison(args, address, stats, rust):
    # Docker starts Envoy in the host network namespace so all paths are loopback.
    with socket.socket() as candidate:
~~~

Replace the selected lines with this block.

~~~python
def capture(args):
    args.out.mkdir()
    with process([args.driver, "origin"], stdout=subprocess.PIPE) as (_, first):
        address, observer = first.split()
        stats = f"http://{observer}/stats"
        with process([args.driver, "origin"], stdout=subprocess.PIPE) as (_, second):
            other, _ = second.split()
            with process(
                [args.proxy, "http", "127.0.0.1:0", address, other], stdout=subprocess.PIPE,
            ) as (proxy, listening):
                rust = listening.removeprefix("listening ")
                run_comparison(args, address, stats, rust, proxy.pid)


def run_comparison(args, address, stats, rust, rust_pid):
    # Docker starts Envoy in the host network namespace so all paths are loopback.
    with socket.socket() as candidate:
~~~

<!-- edit: bench/run.py -->
~~~python
        "warmup_requests_per_trial": 32,
        "payload_bytes": len(PAYLOAD),
        "rates": args.rates,
        "trials": args.trials,
~~~

Replace the selected lines with this block.

~~~python
        "warmup_requests_per_trial": 32,
        "payload_bytes": len(PAYLOAD),
        "rss_scope": "Rust proxy process from driver launch through sample collection",
        "rss_sampling_ms": 25,
        "rates": args.rates,
        "trials": args.trials,
~~~

<!-- edit: bench/run.py -->
~~~python
                        for label, target in paths[offset:] + paths[:offset]:
                            path = args.out / f"{rate}-{repeat + 1}-{label}.json.gz"
                            summary = trial(args.driver, target, stats, rate, args.seconds, path)
                            row = {"path": label, "offered_rps": rate, "trial": repeat + 1, **summary}
                            results.write(json.dumps(row) + "\n")
~~~

Replace the selected lines with this block.

~~~python
                        for label, target in paths[offset:] + paths[:offset]:
                            path = args.out / f"{rate}-{repeat + 1}-{label}.json.gz"
                            summary = trial(args.driver, target, stats, rate, args.seconds, path,
                                            rust_pid if label == "rust" else None)
                            row = {"path": label, "offered_rps": rate, "trial": repeat + 1, **summary}
                            results.write(json.dumps(row) + "\n")
~~~

</details>

### Step 2 — Run the reference protocols

Build the optimized binary, run the pilot, then choose two rates for repeated trials. For the separate managed comparison, run the same paced workload with and without reloads. Select the Rust release binary and use separate report paths.

## Check it

~~~bash
cargo build --release --locked --target-dir target
go build -trimpath -o bench/edge-bench bench/main.go
docker pull envoyproxy/envoy@sha256:36a2dc72f4b0b2639af3dfeaf92dced4063058f200664c6c4f5d443f5d9ea51d
python3 bench/run.py pilot --rates 1000 2500 5000 --trials 1 --seconds 1
python3 bench/run.py steady --rates 200 2500 --trials 3 --seconds 2
export EDGE_BIN="$PWD/target/release/switchyard-edge"
EDGE_RELOAD_REPORT="$PWD/managed-steady.json" go test -count=1 -v ./control -run '^TestCapstoneSteady$'
EDGE_RELOAD_REPORT="$PWD/reload.json" go test -count=1 -v ./control -run "^TestCapstoneReload$"
~~~

<!-- run: python3 -m py_compile bench/run.py -->

Compare per-path throughput and scheduled-start latency ranges, then read the Rust RSS alongside its trial scope. The release records each timed reload separately. [Reference results](../evidence/README.md)

## If it goes wrong

If the driver caps out, include those arrivals in the report and use the direct run to identify shared limits. If RSS cannot be sampled, verify that the proxy process is visible under Linux /proc.

Continue to [Profile and change one hot path](04-profile-the-origin-uri-path.md).
