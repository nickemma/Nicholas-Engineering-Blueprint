# Distributed KV capstone gate and source export

From the assembled learner workspace, run the full gate with an evidence directory outside the temporary cluster.

~~~bash
module="$BLUEPRINT_ROOT/3-tracks/storage-engines/05-capstone-distributed-kv-store"
export KV_EVIDENCE_DIR="$PWD/results"
bash "$module/gate/run.sh" "$PWD"
~~~

Use `recovery` for the crash, partition, and early-acknowledgment checks, `benchmark` for the complete paired YCSB matrix, or `profile` for the isolated CPU samples and timings. Lesson replay runs recovery and a short paired YCSB matrix. Set `YCSB_CACHE_DIR` to a dependency directory you can reuse. The gate verifies the supplied jars against the pinned hashes.

| Check | Required result |
|---|---|
| Lost reply and follower restart | The new leader recovers the committed value and receipt. A peer with an empty Rust view installs a snapshot and catches up. The tenant values and committed deletion survive. |
| Client history and minority control | Porcupine accepts the captured history. The reference isolated leader gives no success. The deliberately early acknowledgment returns success and fails that check. |
| Persistence | The two tenants can use the same key independently, and the sampled Raft and Rust files contain none of the fixture’s plaintext canaries. |
| YCSB | Both read modes finish workloads A and C with every operation accounted for. Per-operation statuses stay in the raw output. |
| CPU sampling | Both read modes process 75,000 identical lookups, return the expected hit count, and produce positive CPU sample counts. |

Export the project after a successful rebuild with a new destination path.

~~~bash
bash "$module/gate/export.sh" "$PWD" /tmp/switchyard-kv-capstone.tar.gz
~~~

The archive includes the locked source, local launcher, benchmark harness, profiles, captured results, and ADR. Extract it into an empty directory and run `bash gate/run.sh "$PWD" recovery` from the project root to verify that it can run without the Blueprint checkout. See the [reference evidence](../evidence/README.md).
