# 05 Capstone: a distributed KV store

> Storage engines track · Time 2 weeks at 12–15 hours a week · Status ready

## What you'll build

Ship a Switchyard key-value service with one fixed three-peer Raft group. Use Go for consensus and the client API, and a Rust process on each peer for indexed storage. Support tenant-scoped reads, writes, and deletes. Run YCSB through the public client API and package a standalone project with reproducible benchmarks, before-and-after flame graphs, and a design decision record.

Seal values before proposing them so both the authoritative Raft storage and the Rust store persist ciphertext. Treat the Rust store as rebuildable from the Raft snapshot and committed suffix. During restart, refuse client success until the peer can serve the required committed state. This capstone combines the completed storage parts and introduces a new integration and benchmark harness. [Consensus in depth](../02-consensus-in-depth/README.md) · [A Rust storage engine](../03-rust-storage-engine/README.md) · [Integrity and encryption](../04-integrity-and-encryption/README.md)

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|
| 1 | 01 | [Define the replicated client contract](lessons/01-define-the-replicated-client-contract.md) | Authenticate the tenant, scope the key, and seal a value before Raft receives the proposal. |
| 1 | 02 | [Apply committed operations to Rust](lessons/02-apply-committed-operations-to-rust.md) | Use a bounded child protocol and rebuild the Rust view from the snapshot image and committed suffix. |
| 1 | 03 | [Recover from a lost reply and a lost peer](lessons/03-recover-after-a-lost-reply.md) | Retry after leader loss, rebuild a lagging replica, and check the client history and minority-write control. |
| 2 | 04 | [Benchmark the public API with YCSB](lessons/04-benchmark-the-client-api-with-ycsb.md) | Run workloads A and C on both read paths and account for every operation. |
| 2 | 05 | [Profile two equivalent read paths](lessons/05-profile-equivalent-read-paths.md) | Capture sampled CPU stacks and unprofiled timings for the same Rust lookup replay. |
| 2 | 06 | [Package the project and run the gate](lessons/06-package-and-run-the-capstone-gate.md) | Export the standalone source, launch and benchmark commands, exact results, and ADR. |

## The gate

- Run the real three-peer service. Stop the leader after a committed write but before it responds. Require the new leader to preserve the write, return the same logical result on retry, and complete an independent write. On the minority side, a fresh write must receive no success.
- Keep a follower behind the snapshot boundary, then restart it with an empty Rust projection. Require snapshot installation and suffix replay, including a delete. Compare reads with the surviving peers and check the client history with Porcupine. Require an early-acknowledgment control to fail the minority-write assertion.
- Give two tenants the same key and verify independent values through failover. Inspect both the Raft and Rust storage files for the fixture’s plaintext canaries.
- Run both YCSB workloads on both read paths with the same setup. Require equivalent client behavior and account for every measured operation, including errors. Save raw output and paired flame graphs. A measured improvement is reported with its workload and variance. Performance is measured separately from the correctness verdict.

The reference runs locally with one Raft group, loopback fixture authentication, and a rebuildable projection per peer. The recovery evidence covers the tested process crashes and partitions. All 3,200 YCSB operations succeeded. Indexed point lookup was about 1.75× as fast on the isolated Rust replay, and the end-to-end results varied by workload. [Gate](gate/README.md) · [Evidence](evidence/README.md) · [Standalone source archive](evidence/switchyard-kv-capstone.tar.gz)

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Start the three peers, run the client, and explain a missing key, a redirect, and an indeterminate result. |
| Intermediate | Reproduce the recovery schedules and explain how Raft and the Rust store agree about the state a client may observe. |
| Senior | Defend the crash and acknowledgment boundaries, interpret the paired profiles and system benchmarks, and explain the cost of rebuilding a peer. |

## Practice

- Extend the failure schedule and repeat the comparison with one different workload variable. [Exercises](exercises.md)
- Explain the recovery boundaries and the evidence from memory. [Self-check](self-check.md)
- Reproduce the checks and prepare a source package for review. [Gate and export](gate/README.md)
