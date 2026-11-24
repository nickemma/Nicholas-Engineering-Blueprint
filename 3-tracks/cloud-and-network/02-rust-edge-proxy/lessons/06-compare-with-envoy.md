# 06 Compare the proxy with Envoy

> A Rust edge proxy · Week 3 · Builds on lesson 05

## The problem

A proxy benchmark measures the client, the path, and the origin together. If the direct path also falls behind, timing the two proxies alone cannot assign the bottleneck.

## The mental model

Send the same fixed schedule and 4 KiB object through three paths. Use HTTP/1.1, persistent connections, and the same origin. Compare the intended start, actual start, and completed response. Keep driver-cap drops and non-200 responses alongside the successful latency percentiles.

## The pattern

Check bytes and protocol during warm-up and in every successful sample. Rotate the path order across repeated trials. Use the upstream counters to see how many requests and sockets actually crossed the origin boundary. The Envoy route and Rust exchange use a 750 ms upstream budget on this bodyless GET profile. [Envoy route timeout documentation](https://www.envoyproxy.io/docs/envoy/v1.38.5/faq/configuration/timeouts)

## Build it

### Step 1 — Make the workload reproducible

Use the Go helper to serve the fixture with a separate counter listener and issue arrivals on a fixed schedule. Limit driver work to 64 outstanding requests and record any dropped arrival.

<details>
<summary>Hint</summary>

Compute latency from the scheduled start and capture launch lag separately.

</details>

<details>
<summary>Implementation</summary>

Create `bench/main.go`.

<!-- file: bench/main.go -->
~~~go
// Command edge-bench serves an instrumented origin or generates a fixed arrival schedule.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

var payload = bytes.Repeat([]byte("switchyard-edge\n"), 256)

func main() {
	switch {
	case len(os.Args) == 2 && os.Args[1] == "origin":
		log.Fatal(origin())
	case len(os.Args) == 5 && os.Args[1] == "load":
		rate, err := strconv.Atoi(os.Args[3])
		if err != nil || rate < 1 || rate > 100000 {
			log.Fatal("rate must be an integer in 1..100000")
		}
		seconds, err := strconv.Atoi(os.Args[4])
		if err != nil || seconds < 1 || seconds > 60 {
			log.Fatal("duration must be an integer in 1..60 seconds")
		}
		log.SetFlags(0)
		if err := load(os.Args[2], rate, seconds); err != nil {
			log.Fatal(err)
		}
	default:
		log.Fatal("usage: edge-bench origin | load URL RATE SECONDS")
	}
}

type counters struct {
	Requests uint64 `json:"requests"`
	Sockets  uint64 `json:"sockets"`
}

func origin() error {
	var requests, sockets atomic.Uint64
	data, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer data.Close()
	admin, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer admin.Close()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /a/obj/4096/1", func(w http.ResponseWriter, _ *http.Request) {
		requests.Add(1)
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
		_, _ = w.Write(payload)
	})
	server := &http.Server{
		Handler: mux, ReadHeaderTimeout: 2 * time.Second, IdleTimeout: 30 * time.Second,
		ConnState: func(_ net.Conn, state http.ConnState) {
			if state == http.StateNew {
				sockets.Add(1)
			}
		},
	}
	observer := http.NewServeMux()
	observer.HandleFunc("GET /stats", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(counters{requests.Load(), sockets.Load()})
	})
	adminServer := &http.Server{Handler: observer, ReadHeaderTimeout: 2 * time.Second}
	go func() { log.Print(adminServer.Serve(admin)) }()
	fmt.Printf("%s %s\n", data.Addr(), admin.Addr())
	return server.Serve(data)
}

type sample struct {
	ID          int    `json:"id"`
	ScheduledUS int64  `json:"scheduled_us"`
	StartedUS   int64  `json:"started_us"`
	FinishedUS  int64  `json:"finished_us"`
	Status      int    `json:"status"`
	Outcome     string `json:"outcome"`
}

func load(url string, rate, seconds int) error {
	transport := &http.Transport{
		MaxIdleConns: 64, MaxIdleConnsPerHost: 64, MaxConnsPerHost: 64,
		IdleConnTimeout: 30 * time.Second, DisableCompression: true,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport: transport, Timeout: 2 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}

	// Warm route and client before starting the schedule. Exit on any mismatch.
	for range 32 {
		if _, outcome := fetch(client, url); outcome != "ok" {
			return fmt.Errorf("warm-up failed: %s", outcome)
		}
	}

	samples := make([]sample, rate*seconds)
	slots := make(chan struct{}, 64)
	var active sync.WaitGroup
	start := time.Now()
	timer := time.NewTimer(0)
	defer timer.Stop()
	for id := range samples {
		offset := time.Duration(id) * time.Second / time.Duration(rate)
		timer.Reset(time.Until(start.Add(offset)))
		<-timer.C
		row := &samples[id]
		row.ID = id
		row.ScheduledUS = offset.Microseconds()
		select {
		case slots <- struct{}{}:
			active.Go(func() {
				row.StartedUS = time.Since(start).Microseconds()
				row.Status, row.Outcome = fetch(client, url)
				row.FinishedUS = time.Since(start).Microseconds()
				<-slots
			})
		default:
			row.StartedUS = time.Since(start).Microseconds()
			row.FinishedUS = row.StartedUS
			row.Outcome = "driver_full"
		}
	}
	active.Wait()
	// Leave the full offered window in the throughput denominator.
	time.Sleep(time.Until(start.Add(time.Duration(seconds) * time.Second)))
	return json.NewEncoder(os.Stdout).Encode(struct {
		Warmup    int      `json:"warmup"`
		ElapsedUS int64    `json:"elapsed_us"`
		Samples   []sample `json:"samples"`
	}{32, time.Since(start).Microseconds(), samples})
}

func fetch(client *http.Client, url string) (int, string) {
	response, err := client.Get(url)
	if err != nil {
		return 0, classify(err)
	}
	defer response.Body.Close()
	content, err := io.ReadAll(io.LimitReader(response.Body, int64(len(payload)+1)))
	if err != nil {
		return response.StatusCode, classify(err)
	}
	if response.StatusCode != http.StatusOK {
		return response.StatusCode, "http_error"
	}
	if response.Proto != "HTTP/1.1" || !bytes.Equal(content, payload) {
		return response.StatusCode, "mismatch"
	}
	return response.StatusCode, "ok"
}

func classify(err error) string {
	var networkError net.Error
	if errors.Is(err, context.DeadlineExceeded) || errors.As(err, &networkError) && networkError.Timeout() {
		return "timeout"
	}
	return "io_error"
}
~~~

</details>

### Step 2 — Match the three paths

Start each trial with 32 warm-up requests. Use the pinned Envoy on loopback and record the generated configuration, versions, and full sample rows. Confirm there are no protocol or body mismatches before comparing the results.

<details>
<summary>Implementation</summary>

Create `bench/run.py`.

<!-- file: bench/run.py -->
~~~python
"""Compare direct, Rust and Envoy HTTP/1.1 paths against the same local origin."""
import argparse
from collections import Counter
from contextlib import contextmanager
import gzip
import json
import math
import os
from pathlib import Path
import platform
import select
import socket
import subprocess
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener
from uuid import uuid4


IMAGE = "envoyproxy/envoy@sha256:36a2dc72f4b0b2639af3dfeaf92dced4063058f200664c6c4f5d443f5d9ea51d"
OBJECT = "/a/obj/4096/1"
PAYLOAD = b"switchyard-edge\n" * 256
LOCAL = build_opener(ProxyHandler({}))
ENV = {**os.environ, "GOMAXPROCS": "2"}


@contextmanager
def process(args, *, cleanup=None, stdout=None, stderr=None):
    with subprocess.Popen(args, env=ENV, text=True, stdout=stdout, stderr=stderr) as child:
        try:
            if stdout == subprocess.PIPE:
                if not select.select([child.stdout], [], [], 10)[0]:
                    raise RuntimeError(f"startup timed out: {args[0]}")
                line = child.stdout.readline().strip()
                if not line:
                    raise RuntimeError(f"no startup address: {args[0]}")
                yield line
            else:
                yield child
        finally:
            if cleanup:
                cleanup()
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


def envoy_config(port, origin):
    return {
        "static_resources": {
            "listeners": [{
                "name": "edge",
                "address": {"socket_address": {"address": "127.0.0.1", "port_value": port}},
                "filter_chains": [{"filters": [{
                    "name": "envoy.filters.network.http_connection_manager",
                    "typed_config": {
                        "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
                        "stat_prefix": "edge",
                        "codec_type": "HTTP1",
                        "common_http_protocol_options": {"idle_timeout": "30s"},
                        "route_config": {"name": "edge", "virtual_hosts": [{
                            "name": "objects",
                            "domains": ["*"],
                            "routes": [{
                                "match": {"path": OBJECT},
                                "route": {"cluster": "origin", "timeout": "0.750s"},
                            }],
                        }]},
                        "http_filters": [{
                            "name": "envoy.filters.http.router",
                            "typed_config": {"@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"},
                        }],
                    },
                }]}],
            }],
            "clusters": [{
                "name": "origin",
                "type": "STATIC",
                "connect_timeout": "0.750s",
                "typed_extension_protocol_options": {
                    "envoy.extensions.upstreams.http.v3.HttpProtocolOptions": {
                        "@type": "type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions",
                        "common_http_protocol_options": {"idle_timeout": "30s"},
                        "explicit_http_config": {"http_protocol_options": {}},
                    },
                },
                "load_assignment": {
                    "cluster_name": "origin",
                    "endpoints": [{"lb_endpoints": [{"endpoint": {"address": {
                        "socket_address": {"address": "127.0.0.1", "port_value": origin},
                    }}}]}],
                },
            }],
        },
    }


def read(url, timeout=2):
    with LOCAL.open(url, timeout=timeout) as result:
        return result.read()


def wait_for_envoy(child, address):
    deadline = time.monotonic() + 15
    while child.poll() is None and time.monotonic() < deadline:
        try:
            if read(f"http://{address}{OBJECT}", timeout=0.4) == PAYLOAD:
                return
        except (URLError, TimeoutError):
            pass
        time.sleep(0.1)
    raise RuntimeError("Envoy did not serve the fixture; see envoy.log")


def percentile(values, p):
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * p) - 1] if ordered else None


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
        json.dump(data, stream, separators=(",", ":"))
    rows = data["samples"]
    outcomes = Counter(row["outcome"] for row in rows)
    success = [row["finished_us"] - row["scheduled_us"] for row in rows if row["outcome"] == "ok"]
    assert len(rows) == rate * seconds
    assert outcomes["mismatch"] == 0 and success, outcomes
    lag = [row["started_us"] - row["scheduled_us"] for row in rows]
    return {
        "ok_rps": round(outcomes["ok"] * 1_000_000 / data["elapsed_us"], 1),
        "p50_us": percentile(success, 0.50),
        "p99_us": percentile(success, 0.99),
        "p99_launch_lag_us": percentile(lag, 0.99),
        "outcomes": dict(outcomes),
        "status_counts": dict(Counter(row["status"] for row in rows)),
        "origin": data["origin"],
        "raw": path.name,
    }


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
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    envoy = f"127.0.0.1:{port}"
    config = envoy_config(port, int(address.split(":")[1]))
    (args.out / "envoy.json").write_text(json.dumps(config, indent=2) + "\n")
    name = "switchyard-edge-" + uuid4().hex[:12]
    docker = ["docker", "run", "--pull=never", "--rm", "--network", "host"]

    def stop_envoy():
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=10, check=False)

    metadata = {
        "envoy_image": IMAGE,
        "envoy_version": subprocess.check_output(
            ["docker", "run", "--pull=never", "--rm", IMAGE, "--version"], text=True,
        ).strip(),
        "rust": subprocess.check_output(["rustc", "--version"], text=True).strip(),
        "go": subprocess.check_output(["go", "version"], text=True).strip(),
        "kernel": platform.platform(),
        "available_cpus": len(os.sched_getaffinity(0)),
        "workers_per_process": 2,
        "warmup_requests_per_trial": 32,
        "payload_bytes": len(PAYLOAD),
        "rates": args.rates,
        "trials": args.trials,
        "seconds": args.seconds,
        "path": OBJECT,
    }
    (args.out / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
    cmd = [*docker, "--name", name, IMAGE, "--concurrency", "2",
           "--log-level", "warning", "--config-yaml", json.dumps(config)]
    paths = [("direct", address), ("rust", rust), ("envoy", envoy)]
    with (args.out / "envoy.log").open("w") as log:
        with process(cmd, cleanup=stop_envoy, stdout=log, stderr=log) as child:
            wait_for_envoy(child, envoy)
            with (args.out / "results.jsonl").open("w") as results:
                for rate in args.rates:
                    for repeat in range(args.trials):
                        offset = repeat % len(paths)
                        for label, target in paths[offset:] + paths[:offset]:
                            path = args.out / f"{rate}-{repeat + 1}-{label}.json.gz"
                            summary = trial(args.driver, target, stats, rate, args.seconds, path)
                            row = {"path": label, "offered_rps": rate, "trial": repeat + 1, **summary}
                            results.write(json.dumps(row) + "\n")
                            results.flush()
                            print(json.dumps(row), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=Path)
    parser.add_argument("--rates", type=int, nargs="+", required=True)
    parser.add_argument("--seconds", type=int, default=2)
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--driver", default="./bench/edge-bench")
    parser.add_argument("--proxy", default="./target/release/switchyard-edge")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60 or args.trials < 1:
        parser.error("seconds must be in 1..60 and trials must be positive")
    if len(set(args.rates)) != len(args.rates) or not all(1 <= rate <= 100000 for rate in args.rates):
        parser.error("rates must be distinct integers in 1..100000")
    capture(args)
~~~

</details>

### Step 3 — Read the offered rate and achieved rate together

Use the light runs to check correctness. In the heavier runs, compare completion rates, errors and driver drops. Check the range over repeats before drawing a conclusion.

<details>
<summary>Hint</summary>

Driver launch lag is part of scheduled-start latency. Direct-path slowdown also limits what can be attributed to either proxy.

</details>

## Check it

~~~bash
cargo build --release --locked --target-dir target
go build -trimpath -o bench/edge-bench bench/main.go
docker pull envoyproxy/envoy@sha256:36a2dc72f4b0b2639af3dfeaf92dced4063058f200664c6c4f5d443f5d9ea51d
python3 bench/run.py edge-evidence --rates 200 8000 --trials 3 --seconds 2
~~~

<!-- run: test -z "$(gofmt -l bench/main.go)" && go build -trimpath -o bench/edge-bench bench/main.go && python3 -m py_compile bench/run.py -->

The reference experiment includes a light rate and a heavier rate selected from a pilot sweep. Read the trial ranges beside the launch lag, direct baseline, and error counts. [Benchmark report and raw results](../evidence/README.md)

## If it goes wrong

If Envoy never serves the object, read `edge-evidence/envoy.log` and confirm the daemon shares the local host network. If the direct path cannot keep pace and driver lag rises, the run found a limit of the shared setup. Save that result and repeat at smaller steps around the knee.

Continue to [Run the gate and explain the limits](07-run-the-edge-proxy-gate.md).
