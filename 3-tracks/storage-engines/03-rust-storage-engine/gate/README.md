# Storage engine recovery and read-cost gate

Run from the learner workspace after lesson 08. The gate builds offline, verifies formatting and linting, checks the engine against an ordered reference model, and starts its own temporary databases and subprocesses.

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/03-rust-storage-engine/gate/run.sh" "$PWD"
~~~

| Check | Required result |
|---|---|
| Framed WAL | Recover the verified prefix, trim an incomplete tail, and refuse a complete corrupt frame while preserving its bytes. |
| Flush and compaction | At every interruption boundary, reopen the run list and active WAL named by the manifest. Preserve acknowledged writes and deletes. The next write gets the next sequence. |
| Interrupted writes | A write paused before append stays absent. A write paused after WAL sync survives reopen. The client received no acknowledgment for either attempt. |
| Point reads and scans | An independently copied model agrees with every tested current and pinned view across flushes, compaction, and reopen. |
| Bloom filter | Lookups agree with and without the filter. The fixed absent-heavy workload needs fewer logical block probes with the filter enabled. |
| Compaction control | In a disposable source copy, ignore the oldest pin when choosing the retention horizon. The same pinned-view assertion must fail with a mismatch. |

The build with `fault-injection` is for the gate. Try the normal CLI in a fresh database and pass byte keys and values as hex. The scan below returns `6a6f62=6e6577`.

~~~bash
db="$(mktemp -d)"
cargo run --offline --locked --quiet -- "$db" put 6a6f62 6e6577
cargo run --offline --locked --quiet -- "$db" flush
cargo run --offline --locked --quiet -- "$db" scan 00 ff
~~~

See the [reference results](../evidence/README.md).
