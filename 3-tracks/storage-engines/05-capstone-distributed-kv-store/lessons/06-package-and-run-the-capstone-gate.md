# 06 Package the project and run the gate

> Distributed KV capstone · Week 2 · Builds on lesson 05

## The problem

A reviewer needs more than a source tree. They need a reproducible way to start the service, reproduce the recovery results, rerun both benchmarks, and understand the design assumptions.

## The mental model

The source package includes the Rust and Go manifests, a local cluster launcher, the Java binding, pinned dependency hashes, a recovery harness, and an ADR. It carries the evidence alongside commands to regenerate it.

## The pattern

Use a standalone archive of the replayed learner source. Export fixture-free inputs and keep credentials in temporary local files. The gate independently rebuilds release, race-enabled, and fault-control binaries as needed.

## Build it

### Step 1 — Write independent launch instructions

Document a disposable cluster, then a put and get over the authorized endpoint.

<details>
<summary>Hint</summary>

Print the token file path only and clean the lab when it stops.

</details>

<details>
<summary>Implementation</summary>

Create `README.md`.

<!-- file: README.md -->
~~~~markdown
# Switchyard distributed key-value capstone

A local three-peer Go Raft service with Rust-backed tenant values. Build on Linux with Go 1.26.6+, Rust 1.89+, Python 3.11+, JDK 21, and curl. The first build fetches pinned dependencies. Peers use Unix sockets. The client API binds to loopback.

Run the complete recovery, benchmark, and profile gate.

~~~bash
export KV_EVIDENCE_DIR="$PWD/results"
bash gate/run.sh "$PWD"
~~~

Set `YCSB_CACHE_DIR` to a Java dependency cache if you have one. The gate verifies each jar with a pinned digest. Pass `recovery`, `benchmark`, or `profile` after the learner workspace to select one check. The benchmark records YCSB A and C for both read paths. The isolated profile uses the Rust lookup function on a fixed replay. [Design decisions](ADR.md)

For a disposable interactive cluster, run `bash lab/launch.sh point`. It prints the peer URLs, initial leader ID, and the path to a JSON file containing the per-tenant tokens. In a second terminal, set `PEER` to the leader's URL and `TOKEN_FILE` to the printed token path. The keys and cluster files are removed when the launcher stops.

~~~bash
token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["a"])' "$TOKEN_FILE")
curl -fsS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
  -d '{"op":"put","key":"job","value":"queued","client":"demo","sequence":1}' "$PEER/kv"
curl -fsS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
  -d '{"op":"get","key":"job"}' "$PEER/kv"
~~~

Run `recovery` mode for the tested restart and partition schedules. The peer binary's flags expose its data paths for a persistent learner deployment.
~~~~

Create `.gitignore`.

<!-- file: .gitignore -->
~~~text
/results/
/target/
/storage/target/
/klog/target/
/storage/klog/target/
__pycache__/
~~~

Create `lab/serve.py`.

<!-- file: lab/serve.py -->
~~~python
"""Start a disposable cluster until interrupted."""

import argparse
from contextlib import suppress
import json
from pathlib import Path
import tempfile
import time

from capstone import KVCluster


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("metad", type=lambda arg: Path(arg).resolve())
    parser.add_argument("writer", type=lambda arg: Path(arg).resolve())
    parser.add_argument("engine", type=lambda arg: Path(arg).resolve())
    parser.add_argument("mode", choices=("point", "range"))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="kv-demo-", dir="/tmp") as directory:
        with KVCluster(Path(directory), args.metad, args.writer, args.engine, args.mode) as cluster:
            print(json.dumps({
                "peers": ["http://" + cluster.address(peer) for peer in cluster.ids],
                "leader": cluster.leader()["ID"],
                "token_file": str(cluster.token_path),
            }), flush=True)
            with suppress(KeyboardInterrupt):
                while True:
                    time.sleep(1)


if __name__ == "__main__":
    main()
~~~

Create `lab/launch.sh`.

<!-- file: lab/launch.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
mode=${1:-point}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cargo build --quiet --locked --release --manifest-path klog/Cargo.toml --bin metad-wal
cargo build --quiet --locked --release --manifest-path storage/Cargo.toml --bin kv-project
target_dir() {
    cargo metadata --locked --no-deps --format-version 1 --manifest-path "$1" |
        python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])'
}
go build -buildvcs=false -o "$work/peer" ./cmd/metad
python3 -B lab/serve.py "$work/peer" "$(target_dir klog/Cargo.toml)/release/metad-wal" \
    "$(target_dir storage/Cargo.toml)/release/kv-project" "$mode"
~~~

</details>

### Step 2 — Explain the source of truth

Record the Raft snapshot and Rust rebuild boundary. Describe the retry and same-ID behavior and the costs of retaining a ciphertext state image.

<details>
<summary>Hint</summary>

Separate the replicated client semantics from local lookup work.

</details>

<details>
<summary>Implementation</summary>

Create `ADR.md`.

<!-- file: ADR.md -->
~~~markdown
# One replicated history and rebuildable local indexes

## Decision

The Go Raft group owns mutation order and durable recovery. Each peer uses a bounded child protocol to apply committed operations to a local Rust LSM engine. A peer rebuilds a fresh projection from the ciphertext values in an installed or restored Raft snapshot, then applies the committed suffix in order. It can recompute the projection from an uncompacted committed log too. A client sees success only after quorum commit and local application. Reads go through the committed log, which keeps the same freshness contract across failover.

The authenticated tenant is part of every physical key. Rust seals writes before the Go proposal so both persistence layers see ciphertext. The transport above the peer boundary is a loopback lab API with temporary bearer tokens. Keys, operation type, sizes, and access patterns remain visible. The keyring is supplied outside both persistence directories.

A mutation receipt is keyed by tenant, key, and client ID. A client uses one outstanding mutation per key and reuses its sequence and operation when retrying. The latest matching receipt returns the original success. The first accepted payload wins for that identifier. Older sequences and reuse for a different operation are refused. The snapshot carries both encrypted state and these receipts.

## Consequences

The projection is replaceable, and its storage sequence is independent of the Raft index. Rebuilding costs local writes and delays readiness. The Raft snapshot also retains a value image, so the capstone targets bounded workloads. Each restart builds a fresh view. Abruptly stopped processes can leave an old view in the lab directory until it is removed.

The reference compares a singleton range and an indexed point lookup under the same replicated read contract. The isolated CPU stacks locate lookup work. The YCSB matrix also pays for HTTP, replica exchange, Raft persistence, and local application, so the observed system effect can be smaller or vary by workload.
~~~

</details>

### Step 3 — Run the gate

Run the real recovery and minority fixtures, the deliberately early reply, and the paired YCSB workloads. Sample the two release read paths for the comparison artifacts.

<details>
<summary>Hint</summary>

Run the smoke gate when replaying the course. Use the default gate for a full benchmark and profiles.

</details>

### Step 4 — Export and verify

Use the export helper to make a clean archive. Expand it in a fresh directory and repeat the recovery check there.

<details>
<summary>Hint</summary>

Keep the lockfiles, raw outputs, and profiles with the project. Choose a public repo or workplace deployment for the learner’s submission.

</details>

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/05-capstone-distributed-kv-store/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/05-capstone-distributed-kv-store/gate/run.sh" "$PWD" replay -->

The [gate and export guide](../gate/README.md) shows how to save evidence, export the source package, and rerun the gate outside the Blueprint checkout.

## If it goes wrong

If the archive’s local harness cannot import its proxy driver, check that the export contains the shared fixture. If the benchmark cannot authenticate, verify the temporary per-tenant token configuration without printing it.
