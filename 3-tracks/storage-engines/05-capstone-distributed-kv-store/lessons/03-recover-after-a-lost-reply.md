# 03 Recover from a lost reply and a lost peer

> Distributed KV capstone · Week 1 · Builds on lesson 02

## The problem

A leader can commit a write and stop before the client reads its response. The next leader needs to return the committed result even when one follower has no Rust files left.

## The mental model

Hold one follower behind the snapshot boundary. Commit through the remaining quorum, then pause the leader after local application and before reply. Restart the lagging follower with an empty Rust view and let the surviving peers restore and extend the committed history.

## The pattern

An idempotent mutation receipt reports the existing success after re-election. A client history records successful response intervals and logical retries. The model checks whether the completed results can be ordered consistently with those intervals.

## Build it

### Step 1 — Place the interruption precisely

Add a test-build barrier immediately before replying to a committed put. The normal binary has an empty hook.

<details>
<summary>Hint</summary>

Pause only when the harness arms the learner-owned leader.

</details>

<details>
<summary>Implementation</summary>

Create `internal/metad/reply_barrier.go`.

<!-- file: internal/metad/reply_barrier.go -->
~~~go
//go:build !capstonegate

package metad

func beforeKVReply(string) {}
~~~

Create `internal/metad/reply_barrier_gate.go`.

<!-- file: internal/metad/reply_barrier_gate.go -->
~~~go
//go:build capstonegate

package metad

import (
	"log"
	"os"
	"time"
)

func beforeKVReply(op string) {
	file := os.Getenv("METAD_GATE_ARM")
	if op != "kv_put" || file == "" || os.Remove(file) != nil {
		return
	}
	log.Print("capstone: committed and applied; reply paused")
	for {
		time.Sleep(time.Second)
	}
}
~~~

Find these regions in `internal/metad/runtime.go` in order.

<!-- edit: internal/metad/runtime.go -->
~~~go
			payload, _ := json.Marshal(entry.Entry) // Entry has only JSON scalar fields.
			log.Printf("applied peer=%d index=%d term=%d digest=%x", r.id, entry.Index, entry.Term, sha256.Sum256(payload))
			if p, exists := pending[entry.Index]; exists && p.term == entry.Term {
				p.reply <- outcome{result: value, code: 200}
				delete(pending, entry.Index)
			}
~~~

Replace the selected lines with this block.

~~~go
			payload, _ := json.Marshal(entry.Entry) // Entry has only JSON scalar fields.
			log.Printf("applied peer=%d index=%d term=%d digest=%x", r.id, entry.Index, entry.Term, sha256.Sum256(payload))
			if p, exists := pending[entry.Index]; exists && p.term == entry.Term {
				beforeKVReply(entry.Command.Op)
				p.reply <- outcome{result: value, code: 200}
				delete(pending, entry.Index)
			}
~~~

</details>

### Step 2 — Keep the trace independent

Add delete to the existing Porcupine model. Annotate the logical put from its first invocation through the successful retry.

<details>
<summary>Hint</summary>

The API returns a receipt for writes. The model can use the submitted value after checking the reported success.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `cmd/check-history/main.go` in order.

<!-- edit: cmd/check-history/main.go -->
~~~go
			expected := result{value: before}
			switch request.Op {
			case "get":
			case "put":
				after = value{Found: true, Value: request.Value}
				expected.value = after
~~~

Replace the selected lines with this block.

~~~go
			expected := result{value: before}
			switch request.Op {
			case "get":
			case "delete":
				after = value{}
				expected.value = after
			case "put":
				after = value{Found: true, Value: request.Value}
				expected.value = after
~~~

<!-- edit: cmd/check-history/main.go -->
~~~go
			return nil, fmt.Errorf("use one populated key per history")
		}
		switch row.Input.Op {
		case "get", "put", "cas":
		default:
			return nil, fmt.Errorf("unknown operation %q", row.Input.Op)
		}
~~~

Replace the selected lines with this block.

~~~go
			return nil, fmt.Errorf("use one populated key per history")
		}
		switch row.Input.Op {
		case "get", "put", "cas", "delete":
		default:
			return nil, fmt.Errorf("unknown operation %q", row.Input.Op)
		}
~~~

</details>

### Step 3 — Exercise restart and quorum loss

Drive the public TCP endpoint and reuse directed Unix-socket links for Raft. Inspect the durable files for the tenant canaries.

<details>
<summary>Hint</summary>

Hold the lagging peer below the snapshot index, and check that its install succeeds after its Rust files are gone.

</details>

<details>
<summary>Implementation</summary>

Create `lab/capstone.py`.

<!-- file: lab/capstone.py -->
~~~python
"""Local three-peer fixtures for the capstone and the YCSB client."""

import base64
import contextlib
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

if not Path(__file__).with_name("verify.py").is_file() and "BLUEPRINT_ROOT" in os.environ:
    sys.path.insert(0, str(Path(os.environ["BLUEPRINT_ROOT"]) / "2-core/07-distributed-systems-fundamentals/gate"))
from verify import Cluster, MinorityAcknowledged, until  # noqa: E402


class KVCluster(Cluster):
    def __init__(self, directory, peer, writer, engine, mode="point"):
        super().__init__(directory, peer, writer)
        self.engine, self.mode = engine, mode
        secret_dir = directory / "keys"
        secret_dir.mkdir(mode=0o700)
        self.keyring = secret_dir / "values"
        self.keyring.write_text("1:" + secrets.token_hex(32) + "\n")
        self.tokens = {"a": secrets.token_hex(24), "b": secrets.token_hex(24)}
        self.token_path = secret_dir / "tokens"
        self.token_path.write_text(json.dumps(self.tokens))
        for path in (self.keyring, self.token_path):
            path.chmod(0o600)

    def projection(self, peer):
        return self.root / f"lsm-{peer}"

    def args(self, peer, wal=None):
        return [*super().args(peer, wal), "-client", "127.0.0.1:0",
                "-engine", str(self.engine), "-projection-root", str(self.projection(peer)),
                "-tenant-tokens", str(self.token_path), "-keyring", str(self.keyring),
                "-read-path", self.mode]

    def address(self, peer):
        return re.findall(r"kv client=(127\.0\.0\.1:[0-9]+)", self.log(peer))[-1]

    def kv(self, peer, op, key, value=None, sequence=None, tenant="a", client="test"):
        body = {"op": op, "key": key}
        if value is not None:
            body["value"] = value
        if sequence is not None:
            body.update(client=client, sequence=sequence)
        headers = {"Content-Type": "application/json"}
        if tenant in self.tokens:
            headers["Authorization"] = f"Bearer {self.tokens[tenant]}"
        with contextlib.closing(http.client.HTTPConnection(self.address(peer), timeout=2)) as conn:
            conn.request("POST", "/kv", json.dumps(body), headers)
            with conn.getresponse() as response:
                content = response.read()
                return response.status, json.loads(content) if content.startswith(b"{") else None


def ok(cluster, peer, op, key, value=None, seq=None, tenant="a"):
    status, result = cluster.kv(peer, op, key, value, seq, tenant)
    assert status == 200 and not result.get("error"), (status, result)
    return result


def recover(cluster, checker, output):
    rows = []

    def begin(op, value=""):
        row = {"Input": {"Op": op, "Key": "job", "Value": value},
               "Call": time.monotonic_ns(), "Client": 0}
        rows.append(row)
        return row

    def complete(row, result):
        assert result.get("error") is None
        if row["Input"]["Op"] == "put":
            assert result == {"found": True}
            result = {"found": True, "value": row["Input"]["Value"]}
        if row["Input"]["Op"] == "delete":
            assert result == {"found": True}
            result = {"found": False}
        row.update(Return=time.monotonic_ns(), Result=result)

    first = cluster.leader()["ID"]
    lagging = first % 3 + 1
    voter = next(p for p in cluster.ids if p not in (first, lagging))
    canary = "value-private-before-failover"
    other = "value-private-other-tenant"
    latest = "value-private-after-lost-reply"
    complete(begin("put", canary), ok(cluster, first, "put", "job", canary, 1))
    assert ok(cluster, first, "put", "job", other, 1, "b") == {"found": True}
    assert cluster.kv(first, "get", "job", tenant="unknown")[0] == 401

    cluster.isolate(lagging, True)
    cluster.stop(lagging, force=True)
    if cluster.projection(lagging).exists():
        shutil.rmtree(cluster.projection(lagging))
    ok(cluster, first, "put", "erased", "old", 1)
    ok(cluster, first, "delete", "erased", seq=2)
    for i in range(10):
        ok(cluster, first, "put", f"filler-{i}", "x", 1)
    for peer in (first, voter):
        until(lambda: cluster.status(peer)["Snapshot"] >= 8, "durable snapshot")

    cluster.arm(first).touch()
    row = begin("put", latest)
    with ThreadPoolExecutor(max_workers=1) as pool:
        call = pool.submit(cluster.kv, first, "put", "job", latest, 2)
        until(lambda: "committed and applied; reply paused" in cluster.log(first), "lost-reply barrier")
        cluster.stop(first, force=True)
        try:
            code, _ = call.result()
        except (OSError, http.client.HTTPException):
            pass
        else:
            assert code != 200, code

    cluster.start(lagging)
    cluster.isolate(lagging, False)
    leader = cluster.leader([voter, lagging])["ID"]
    assert ok(cluster, leader, "get", "job") == {"found": True, "value": latest}
    complete(row, ok(cluster, leader, "put", "job", latest, 2))
    complete(begin("get"), ok(cluster, leader, "get", "job"))
    assert ok(cluster, leader, "get", "job", tenant="b")["value"] == other
    assert ok(cluster, leader, "get", "erased") == {"found": False}
    until(lambda: "installed peer=" in cluster.log(lagging), "lagging follower installs snapshot")
    ok(cluster, leader, "put", "independent", "committed", 1)

    cluster.start(first)
    until(lambda: cluster.status(first)["Applied"] >= cluster.status(leader)["Applied"], "restarted leader catches up")
    cluster.stop(leader, force=True)
    survivor = cluster.leader([p for p in cluster.ids if p != leader])["ID"]
    assert ok(cluster, survivor, "get", "job")["value"] == latest
    assert ok(cluster, survivor, "get", "erased") == {"found": False}
    complete(begin("delete"), ok(cluster, survivor, "delete", "job", seq=3))
    complete(begin("get"), ok(cluster, survivor, "get", "job"))
    assert rows[-1]["Result"] == {"found": False}
    assert ok(cluster, survivor, "get", "job", tenant="b")["value"] == other

    paths = [cluster.wal(p) for p in cluster.ids]
    for peer in cluster.ids:
        paths += list(cluster.projection(peer).glob("view-*/*/wal-*"))
        paths += list(cluster.projection(peer).glob("view-*/*/run-*"))
    assert len(paths) > 3
    for path in paths:
        try:
            data = path.read_bytes()
        except FileNotFoundError:  # Local WAL rotation can retire a file during inspection.
            continue
        for value in (canary, other, latest):
            raw = value.encode()
            assert all(form not in data for form in (raw, raw.hex().encode(), base64.b64encode(raw))), path

    cluster.check_history()
    history = output / "history.json"
    history.write_text(json.dumps(rows, indent=2) + "\n")
    subprocess.run([checker, history], check=True, timeout=10)
    print("lost reply recovered; lagging peer rebuilt from snapshot; tenants and deletes survived")
    print(f"no plaintext canaries in Raft or Rust storage ({len(paths)} paths inspected)")


def minority(cluster):
    leader = cluster.leader()["ID"]
    ok(cluster, leader, "put", "baseline", "kept", 1)
    cluster.isolate(leader, True)
    code, result = cluster.kv(leader, "put", "minority", "must-not-commit", 1)
    if code == 200:
        raise MinorityAcknowledged("isolated leader acknowledged a fresh write")
    assert code in (409, 504), (code, result)
    print(f"minority write received no success (HTTP {code})")


def main(mode, metad, writer, engine, checker, output):
    output.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="st05-", dir="/tmp") as temp:
            with KVCluster(Path(temp), metad, writer, engine, read_path(mode)) as cluster:
                if mode == "minority":
                    minority(cluster)
                else:
                    recover(cluster, checker, output)
    except MinorityAcknowledged as error:
        print(error, file=sys.stderr)
        return 42
    return 0


def read_path(mode):
    return mode if mode in ("point", "range") else "point"


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1], *(Path(arg).resolve() for arg in sys.argv[2:])))
~~~

</details>

### Step 4 — Make an early reply fail the gate

In the control, return success directly from leader proposal acceptance. Isolate that leader and require the reference and control to disagree.

<details>
<summary>Hint</summary>

A minority leader may still accept a local proposal. Commit and application remain the acknowledgment boundary.

</details>

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/05-capstone-distributed-kv-store/gate/run.sh" "$PWD" recovery
~~~

<!-- run: go test -race -count=1 ./internal/metad -->

Porcupine accepted five logical observations. The lost write, tenant values, and the deletion survived the fixture. The isolated reference leader did not return success, and the early-reply control failed.

## If it goes wrong

If the lost-reply barrier never appears, verify the test build tag and that the peer still has a quorum. If the lagging follower never logs installation, compare its applied index with the leader’s snapshot base.
