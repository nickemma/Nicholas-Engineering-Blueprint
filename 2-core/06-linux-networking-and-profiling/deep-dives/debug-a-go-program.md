# Debug a failing Go program with Delve

Build a tiny job-capacity program with an intentional bug. On Linux, use Go 1.26, Python 3 and Delve 1.26.3. Use Docker and a disposable kind cluster for the last part. Install Delve into a local path and put it on your PATH.

~~~~bash
GOBIN="$PWD/bin" go install github.com/go-delve/delve/cmd/dlv@v1.26.3
export PATH="$PWD/bin:$PATH"
~~~~

## 1. Freeze the failure in a test

A queue with capacity ten and three jobs has seven free slots. The fixture computes the wrong sign. The test and the CLI give you independent ways to observe it.

Create `go.mod`.

<!-- file: go.mod -->
~~~~text
module debugjobs

go 1.26
~~~~

Create `main.go`.

<!-- file: main.go -->
~~~~go
package main

import (
	"flag"
	"fmt"
	"strconv"
)

func remaining(capacity, queued int) int {
	return queued - capacity
}

func main() {
	crash := flag.Bool("crash", false, "panic when the invariant fails")
	flag.Parse()
	if flag.NArg() != 2 {
		panic("pass capacity and queued")
	}
	capacity, err := strconv.Atoi(flag.Arg(0))
	if err != nil {
		panic(err)
	}
	queued, err := strconv.Atoi(flag.Arg(1))
	if err != nil {
		panic(err)
	}
	room := remaining(capacity, queued)
	if *crash && room < 0 {
		panic(fmt.Sprintf("negative remaining capacity: %d", room))
	}
	fmt.Printf("capacity=%d queued=%d remaining=%d\n", capacity, queued, room)
}
~~~~

Create `main_test.go`.

<!-- file: main_test.go -->
~~~~go
package main

import "testing"

func TestRemaining(t *testing.T) {
	if got := remaining(10, 3); got != 7 {
		t.Fatalf("remaining(10, 3) = %d, want 7", got)
	}
}

func BenchmarkRemaining(b *testing.B) {
	queued := 0
	for b.Loop() {
		queued = (queued + remaining(10, queued)) & 7
	}
}
~~~~

Create `check-failure.sh`.

<!-- file: check-failure.sh -->
~~~~bash
#!/usr/bin/env bash
set -euo pipefail
if go test -count=1 ./... > failing-test.txt 2>&1; then
  echo "expected the bug to fail TestRemaining" >&2
  exit 1
fi
grep -F 'remaining(10, 3) = -7, want 7' failing-test.txt
~~~~

<!-- run: bash check-failure.sh && go build -buildvcs=false -gcflags='all=-N -l' -o debugjobs . -->
~~~~bash
bash check-failure.sh && go build -buildvcs=false -gcflags='all=-N -l' -o debugjobs .
~~~~

The failing run prints `remaining(10, 3) = -7, want 7`. The build keeps frame locations simple for stepping.

## 2. Stop, inspect, trace and change the process

Set a breakpoint at the function. Check its arguments and caller, then step onto the subtraction. Set another breakpoint before the crash condition and replace the computed value in the running process. This tests the value you expect without changing the source.

Create `inspect.dlv`.

<!-- file: inspect.dlv -->
~~~~text
break main.remaining
continue
args
stack
next
~~~~

Create `observed.dlv`.

<!-- file: observed.dlv -->
~~~~text
source inspect.dlv
break main.go:28
continue
print room
set room = 7
print room
continue
quit
~~~~

~~~~bash
dlv exec --allow-non-terminal-interactive=true ./debugjobs -- 10 3 < observed.dlv
dlv trace --exec ./debugjobs '^main\.remaining$' -- 10 3
~~~~

The first session showed `capacity = 10`, `queued = 3` and the caller `main.main`. Setting `room` to seven produced `capacity=10 queued=3 remaining=7`. The trace ran the original code and printed `main.remaining => (-7)`. Run `goroutines` or `frame 1` at the first breakpoint to inspect other runtime goroutines and the caller. [Delve command reference](https://github.com/go-delve/delve/blob/master/Documentation/cli/README.md)

## 3. Inspect the crash after exit and connect over JSON-RPC

On a lab machine where `/proc/sys/kernel/core_pattern` is `core`, run this in the scratch directory. If the host collects dumps through systemd, export the relevant dump from that service instead. Keep the binary next to the dump.

~~~~bash
(ulimit -c unlimited; GOTRACEBACK=crash ./debugjobs -crash 10 3 > panic.txt 2>&1)
printf 'bt\nquit\n' | dlv core --allow-non-terminal-interactive=true ./debugjobs core
~~~~

The panic was `negative remaining capacity: -7`. The post-mortem backtrace included `main.main` at the panic site. A core records the stopped process state. To see execution history, capture a trace or record a run.

The script below starts a headless debugger bound to an ephemeral loopback port, sets the same breakpoint through JSON-RPC, and evaluates `queued` in the stopped thread. If you place the debugger on another lab host, keep the listener on remote loopback and forward it through an authenticated tunnel. [Delve JSON-RPC](https://github.com/go-delve/delve/blob/master/Documentation/api/json-rpc/README.md)

Create `remote.py`.

<!-- file: remote.py -->
~~~~python
import json
import os
import socket
import subprocess


def main():
    command = [
        os.environ.get("DLV", "dlv"), "exec", "--headless", "--api-version=2",
        "--listen=127.0.0.1:0", "./debugjobs", "--", "10", "3",
    ]
    with subprocess.Popen(command, stdout=subprocess.PIPE, text=True) as debugger:
        try:
            line = debugger.stdout.readline()
            prefix = "API server listening at: "
            if not line.startswith(prefix):
                raise RuntimeError(f"debugger did not publish an address: {line!r}")
            host, port = line.removeprefix(prefix).strip().split(":")
            with socket.create_connection((host, int(port)), timeout=5) as connection:
                with connection.makefile("rwb") as stream:
                    request_id = 0

                    def call(method, arguments):
                        nonlocal request_id
                        request_id += 1
                        request = {"method": "RPCServer." + method,
                                   "params": [arguments], "id": request_id}
                        stream.write((json.dumps(request) + "\n").encode())
                        stream.flush()
                        reply = json.loads(stream.readline())
                        if reply["id"] != request_id or reply.get("error"):
                            raise RuntimeError(reply)
                        return reply["result"]

                    call("CreateBreakpoint", {"Breakpoint": {"functionName": "main.remaining"}})
                    state = call("Command", {"name": "continue"})["State"]
                    assert state["currentThread"]["function"]["name"] == "main.remaining"
                    queued = call("Eval", {"Scope": {"GoroutineID": -1, "Frame": 0},
                                           "Expr": "queued"})["Variable"]["value"]
                    assert queued == "3", queued
                    print(f"remote breakpoint main.remaining: queued={queued}")
        finally:
            debugger.terminate()
            debugger.wait(timeout=5)


if __name__ == "__main__":
    main()
~~~~

~~~~bash
python3 remote.py
~~~~

The run printed `remote breakpoint main.remaining: queued=3`. On a host that allows rr to use the required performance counters, record the same run and step backward from the subtraction.

~~~~bash
rr record -n -o "$PWD/rr-jobs" ./debugjobs 10 3
dlv replay "$PWD/rr-jobs"
~~~~

In Delve, run `break main.remaining`, `continue`, `next`, `reverse-step`, and `args`. The reference host recorded the failing run with `rr record -n`. Replay stopped at startup because the host's `perf_event_paranoid` setting is 2. Run the replay section on a development host configured for rr. [Delve replay](https://github.com/go-delve/delve/blob/master/Documentation/usage/dlv_replay.md)

## 4. Follow it into a container and Pod

Build the image while the bug is still present. Delve runs inside the image with the matching binary and source. The local run changes seccomp for this disposable debugging container so Delve can trace its own child.

Create `Dockerfile`.

<!-- file: Dockerfile -->
~~~~dockerfile
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -gcflags='all=-N -l' -o /out/debugjobs . \
    && CGO_ENABLED=0 GOBIN=/out go install github.com/go-delve/delve/cmd/dlv@v1.26.3

FROM busybox:1.37
WORKDIR /lab
COPY --from=build /out/debugjobs /usr/local/bin/debugjobs
COPY --from=build /out/dlv /usr/local/bin/dlv
COPY main.go inspect.dlv observed.dlv /lab/
ENTRYPOINT ["debugjobs"]
~~~~

~~~~bash
docker build -t blueprint-delve-lab:local .
docker run --rm blueprint-delve-lab:local -crash 10 3
docker run --rm -i --security-opt seccomp=unconfined --entrypoint dlv \
  blueprint-delve-lab:local exec --allow-non-terminal-interactive=true \
  /usr/local/bin/debugjobs -- 10 3 < observed.dlv
~~~~

For the Pod, load the same image into the dedicated kind cluster from the [Kubernetes workload build](../../../3-tracks/shared-units/kubernetes-and-delivery/deep-dives/workloads-and-rollouts.md). Use that cluster's kubeconfig. The crashing Pod should log the same panic. Check its terminated container status before debugging the temporary second Pod.

~~~~bash
kind load docker-image blueprint-delve-lab:local --name blueprint-platform-build
kubectl create namespace delve-lab
kubectl -n delve-lab run crash --image=blueprint-delve-lab:local \
  --image-pull-policy=Never --restart=Never -- -crash 10 3
kubectl -n delve-lab wait --for=jsonpath='{.status.phase}'=Failed pod/crash --timeout=60s
kubectl -n delve-lab logs crash
kubectl -n delve-lab describe pod crash
kubectl -n delve-lab run inspect --image=blueprint-delve-lab:local \
  --image-pull-policy=Never --restart=Never \
  --overrides='{"spec":{"securityContext":{"seccompProfile":{"type":"Unconfined"}}}}' \
  --command -- sleep 600
kubectl -n delve-lab wait --for=condition=Ready pod/inspect --timeout=60s
kubectl -n delve-lab exec -i inspect -- dlv exec --allow-non-terminal-interactive=true \
  /usr/local/bin/debugjobs -- 10 3 < observed.dlv
kubectl delete namespace delve-lab
~~~~

The crashing Pod logged `negative remaining capacity: -7`. Delve in the second Pod showed the same `-7` at the breakpoint, accepted the edit, and printed `capacity=10 queued=3 remaining=7`. If kind reports a missing digest when loading the image, use the [single-platform import](../../../3-tracks/shared-units/kubernetes-and-delivery/deep-dives/workloads-and-rollouts.md#3-run-the-rollout-and-recovery-check) with `blueprint-delve-lab:local` in place of the BusyBox image.

## 5. Fix the source and compare profiling with stepping

Replace the mistaken subtraction in `main.go`.

<!-- edit: main.go -->
~~~~go
	return queued - capacity
~~~~
~~~~go
	return capacity - queued
~~~~

<!-- run: go test -count=1 ./... && test "$(go run -buildvcs=false . 10 3)" = 'capacity=10 queued=3 remaining=7' -->
~~~~bash
go test -count=1 ./... && test "$(go run -buildvcs=false . 10 3)" = 'capacity=10 queued=3 remaining=7'
~~~~

An optimized benchmark runs without a breakpoint. Collect a CPU profile and read the largest entries. Compare that aggregation with the values Delve printed for one call. Use the [Core 06 perf build](../lessons/04-perf-the-whole-machines-view.md) to sample the same compiled Go benchmark on a host that permits hardware counters.

~~~~bash
go test -run '^$' -bench '^BenchmarkRemaining$' -cpuprofile cpu.out
go tool pprof -top cpu.out
go test -c -o debugjobs.test
perf stat ./debugjobs.test -test.run '^$' -test.bench '^BenchmarkRemaining$'
~~~~

In the captured CPU profile, all 550 ms of samples were attributed to the inlined benchmark loop, with `BenchmarkRemaining` in the calling stack. This tiny optimized operation makes the loop visible in the profile. Use a workload with meaningful I/O or computation to decide where production time goes.
