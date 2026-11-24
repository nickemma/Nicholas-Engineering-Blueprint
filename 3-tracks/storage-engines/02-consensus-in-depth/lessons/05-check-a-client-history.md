# 05 Check client histories for linearizability

> Consensus in depth · Week 3 · Builds on lesson 04

## The problem

A minority leader can hold a stale value while the connected peers acknowledge a new one. Per-peer log traces alone cannot tell you whether client return values admit a valid ordering.

## The mental model

Label each client operation with its call and return times. Draw the interval for each operation. If a write returns before a read begins, a legal sequence has to put that write before the read.

## The pattern

Linearizability asks whether the observed results fit a sequential model within those intervals. Porcupine searches for a legal order. An indeterminate operation can be omitted or take effect after its call. The model uses one value per key, and the recovery drill checks retry receipts separately.

## Build it

### Step 1 — Pin the checker

Keep the Porcupine module and its checksums in the learner workspace. Run `go mod download` once if the dependency is missing.

<details>
<summary>Hint 1</summary>

Go verifies downloads against go.sum.

</details>

<details>
<summary>Hint 2</summary>

Use the same module version for the reference and control.

</details>

<details>
<summary>Implementation</summary>

Replace `go.mod` with the version below.

<!-- file: go.mod -->
~~~text
module switchyard/metad

go 1.26

require github.com/anishathalye/porcupine v1.3.1
~~~

Create `go.sum`.

<!-- file: go.sum -->
~~~text
github.com/anishathalye/porcupine v1.3.1 h1:fBZ4/NGNPnIDdd6xNtrNk9/GiEQ0L4FO5+scINN+t0E=
github.com/anishathalye/porcupine v1.3.1/go.mod h1:WM0SsFjWNl2Y4BqHr/E/ll2yY1GY1jqn+W7Z/84Zoog=
~~~

</details>

### Step 2 — Define the sequential model

Write expected results for get, put, and CAS, including an absent value. For an indeterminate operation, list the possible next states.

<details>
<summary>Hint 1</summary>

A pending write may have no effect, or it may change the register.

</details>

<details>
<summary>Hint 2</summary>

Give a pending operation an artificial endpoint after the last observation so it never creates a false real-time requirement.

</details>

<details>
<summary>Implementation</summary>

Create `cmd/check-history/main.go`.

<!-- file: cmd/check-history/main.go -->
~~~go
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/anishathalye/porcupine"
)

type input struct {
	Op, Key, Value, Expect string
}

type value struct {
	Found bool
	Value string
}

type result struct {
	value
	Swapped bool
}

type observation struct {
	Input  input
	Call   int64
	Return *int64
	Result *result
	Client int
}

func register() porcupine.Model {
	spec := porcupine.NondeterministicModel{
		Init: func() []any { return []any{value{}} },
		Step: func(state, argument, output any) []any {
			before := state.(value)
			request := argument.(input)
			after := before
			expected := result{value: before}
			switch request.Op {
			case "get":
			case "put":
				after = value{Found: true, Value: request.Value}
				expected.value = after
			case "cas":
				if before.Found && before.Value == request.Expect {
					after = value{Found: true, Value: request.Value}
					expected = result{value: after, Swapped: true}
				}
			}
			if output.(*result) == nil {
				return []any{before, after}
			}
			if *output.(*result) == expected {
				return []any{after}
			}
			return nil
		},
	}
	return spec.ToModel()
}

func operations(rows []observation) ([]porcupine.Operation, error) {
	if len(rows) == 0 {
		return nil, fmt.Errorf("empty history")
	}
	var end int64
	for _, row := range rows {
		if row.Input.Key == "" || row.Input.Key != rows[0].Input.Key {
			return nil, fmt.Errorf("use one populated key per history")
		}
		switch row.Input.Op {
		case "get", "put", "cas":
		default:
			return nil, fmt.Errorf("unknown operation %q", row.Input.Op)
		}
		end = max(end, row.Call)
		if (row.Return == nil) != (row.Result == nil) || row.Call < 0 {
			return nil, fmt.Errorf("invalid observation for client %d", row.Client)
		}
		if row.Return != nil {
			if *row.Return < row.Call {
				return nil, fmt.Errorf("return precedes call")
			}
			end = max(end, *row.Return)
		}
	}
	if end == 1<<63-1 {
		return nil, fmt.Errorf("history timestamp overflow")
	}
	history := make([]porcupine.Operation, 0, len(rows))
	for _, row := range rows {
		finish := end + 1 // A missing result may take effect at any later point.
		if row.Return != nil {
			finish = *row.Return
		}
		history = append(history, porcupine.Operation{
			ClientId: row.Client, Input: row.Input, Call: row.Call,
			Output: row.Result, Return: finish,
		})
	}
	return history, nil
}

func run(path string) (int, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return 2, err
	}
	var rows []observation
	if err := json.Unmarshal(body, &rows); err != nil {
		return 2, err
	}
	history, err := operations(rows)
	if err != nil {
		return 2, err
	}
	switch porcupine.CheckOperationsTimeout(register(), history, 5*time.Second) {
	case porcupine.Ok:
		fmt.Printf("linearizable (%d observations)\n", len(history))
		return 0, nil
	case porcupine.Illegal:
		return 1, fmt.Errorf("no legal order for %d observations", len(history))
	default:
		return 2, fmt.Errorf("checker inconclusive")
	}
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: check-history HISTORY.json")
		os.Exit(2)
	}
	status, err := run(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	os.Exit(status)
}
~~~

</details>

### Step 3 — Observe the real cluster

Use Core 07’s Unix-socket harness for the three peers. Isolate a follower through compaction, observe InstallSnapshot, then restart the leader on the minority side and check the majority’s results.

<details>
<summary>Hint 1</summary>

Capture calls before sending HTTP and returns after reading the response.

</details>

<details>
<summary>Hint 2</summary>

Keep the known-lost or ambiguous outcome in the trace. Change the final completed read in a copy for the negative control.

</details>

<details>
<summary>Implementation</summary>

Create `lab/consensus.py`.

<!-- file: lab/consensus.py -->
~~~python
"""Drive the local three-peer binary through recovery and a range move."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

core_gate = Path(os.environ["BLUEPRINT_ROOT"]) / "2-core/07-distributed-systems-fundamentals/gate"
sys.path.insert(0, str(core_gate))
from verify import Cluster, until  # noqa: E402


def result(cluster, peer, op, key="", value="", **fields):
    status, body = cluster.command(peer, op, key, value, **fields)
    assert status == 200, (status, body)
    return body


def record(rows, cluster, peer, op, value="", **fields):
    row = {
        "Input": {"Op": op, "Key": "job", "Value": value, "Expect": fields.get("Expect", "")},
        "Call": time.monotonic_ns(), "Client": len(rows),
    }
    rows.append(row)
    status, body = cluster.command(peer, op, "job", value, **fields)
    finish = time.monotonic_ns()
    if status == 200:
        assert "error" not in body, body
        row.update(Return=finish, Result=body)
    else:
        assert status in (409, 504), (status, body)
    return status, body


def check_files(checker, directory, rows):
    good = directory / "history.json"
    good.write_text(json.dumps(rows, indent=2) + "\n")
    subprocess.run([checker, good], check=True, timeout=8)
    stale = copy.deepcopy(rows)
    assert stale[-1]["Input"]["Op"] == "get" and stale[-1]["Result"]["value"] == "failover"
    stale[-1]["Result"]["value"] = "queued"
    bad = directory / "stale.json"
    bad.write_text(json.dumps(stale, indent=2) + "\n")
    control = subprocess.run([checker, bad], capture_output=True, text=True, timeout=8)
    assert control.returncode == 1 and "no legal order" in control.stderr, control
    print("negative control: " + control.stderr.strip())


def recover(cluster, checker, directory):
    rows = []
    leader = cluster.leader()["ID"]
    lagging = leader % 3 + 1
    cluster.isolate(lagging, True)
    assert record(rows, cluster, leader, "put", "queued")[0] == 200
    swap = {"Expect": "queued", "Client": "worker", "Sequence": 1}
    code, original = record(rows, cluster, leader, "cas", "running", **swap)
    assert code == 200 and original["swapped"], original
    with ThreadPoolExecutor(max_workers=2) as clients:
        read = clients.submit(record, rows, cluster, leader, "get")
        write = clients.submit(record, rows, cluster, leader, "put", "done")
        assert read.result()[0] == write.result()[0] == 200
    for i in range(8):
        cluster.write(leader, f"filler-{i}", "v")
    snap = until(lambda: (s := cluster.status(leader))["Snapshot"] >= 8 and s, "leader snapshot")
    lagging_index = cluster.status(lagging)["Applied"]
    assert lagging_index < snap["Snapshot"]
    cluster.isolate(lagging, False)
    installed = until(
        lambda: f"installed peer={lagging}" in cluster.log(lagging) and cluster.status(lagging),
        "snapshot installation",
    )
    assert installed["Snapshot"] >= snap["Snapshot"]
    cluster.isolate(leader, True)
    code, _ = record(rows, cluster, leader, "put", "indeterminate")
    assert code in (409, 504)
    cluster.stop(leader, force=True)
    cluster.start(leader)
    recovered = until(lambda: cluster.status(leader), "isolated restart")
    assert (recovered["Snapshot"], recovered["Vote"], recovered["Term"]) == (
        snap["Snapshot"], snap["Vote"], snap["Term"]
    ), (snap, recovered)
    assert recovered["Applied"] == snap["Snapshot"], recovered
    winner = cluster.leader([p for p in cluster.ids if p != leader])["ID"]
    cluster.isolate(leader, False)
    assert result(cluster, winner, "cas", "job", "running", **swap) == original
    assert result(cluster, winner, "get", "job") == {"found": True, "value": "done"}
    assert record(rows, cluster, winner, "put", "failover")[0] == 200
    assert record(rows, cluster, winner, "get") == (200, {"found": True, "value": "failover"})
    until(lambda: cluster.status(leader)["Applied"] >= cluster.status(winner)["Applied"],
          "restarted peer catches up")
    cluster.check_history()
    print(f"snapshot recovery: lagging index {lagging_index}, installed {installed['Snapshot']}, restored vote and term")
    print("retry after failover returned the original compare-and-swap result and preserved done")
    check_files(checker, directory, rows)


def main(metad, writer, checker, output):
    with tempfile.TemporaryDirectory(prefix="st02-", dir="/tmp") as temporary:
        with Cluster(Path(temporary), metad, writer) as cluster:
            recover(cluster, checker, output)


if __name__ == "__main__":
    phase, *paths = sys.argv[1:]
    if phase != "recovery":
        raise ValueError(f"unknown live check {phase}")
    main(*(Path(arg) for arg in paths))
~~~

</details>

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/02-consensus-in-depth/gate/run.sh" "$PWD" recovery
~~~

<!-- run: test -z "$(gofmt -l cmd internal)" && go vet ./... && go test -race -count=1 ./... -->

The reference accepted seven observations, including one indeterminate write, and rejected the copy with the stale read. The replay records the individual calls and returns. [Captured histories](../evidence/README.md)

## If it goes wrong

A checker timeout is inconclusive. Keep the fixture on one key and check clock ordering, matching results, and how pending outcomes were captured.
