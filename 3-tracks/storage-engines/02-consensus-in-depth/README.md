# 02 Consensus in depth

> Storage engines track · Time 4 weeks at 12–15 hours a week · Builds on Core 07 and Storage 01 · Status ready

## What you'll build

Extend Switchyard's `metad` into a replicated key-value store with retry-safe writes and reads through the Raft log. Use the seeded network to repeat election and catch-up failures, then bring snapshot recovery and client history checks to the real three-peer runtime. Move one key range between two fixed replica groups. Use a separate two-Postgres lab to compare a prepared transfer with a compensating workflow.

Start from the Go Raft core, its Linux runtime, and the Rust `klog` writer. The transfer lab uses the PostgreSQL transaction and recovery work from the previous part. The lesson sequence introduces Porcupine and TLC when they first appear. [Core 07 Distributed-systems fundamentals](../../../2-core/07-distributed-systems-fundamentals/README.md) · [01 Postgres in depth](../01-postgres-in-depth/README.md)

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Give clients a replicated key-value store](lessons/01-replicate-key-value-commands.md) | Add deterministic `Put`, `Get`, and compare-and-swap commands. Keep a per-client sequence and cached result within a key. Retry a committed swap and verify that it returns the original result. |
| 1 | 02 | [Compact a log and install a snapshot](lessons/02-compact-and-install-a-snapshot.md) | Snapshot applied values and retry records. Track absolute indexes across compaction and install the snapshot on a lagging peer. |
| 2 | 03 | [Recover across the snapshot and log boundary](lessons/03-recover-and-reclaim-the-wal.md) | Restart around snapshot publication and WAL replacement. Check that the peer preserves its term, vote, and retained suffix. |
| 2 | 04 | [Keep an election from disrupting a healthy majority](lessons/04-protect-a-healthy-majority.md) | Replay a returning follower and a partial partition with PreVote. Use CheckQuorum to make an isolated leader step down. |
| 3 | 05 | [Check client histories for linearizability](lessons/05-check-a-client-history.md) | Capture operation calls and returns during a leader change. Use Porcupine on the live history and a stale-read control. |
| 3 | 06 | [Model election safety with TLA+](lessons/06-model-election-safety.md) | Check a bounded election model with TLC. Allow a peer to vote twice in one term and inspect the resulting counterexample. |
| 4 | 07 | [Move a key range between replica groups](lessons/07-move-a-key-range.md) | Fence the source, transfer values and retry receipts, and activate the destination at a higher routing epoch. Interrupt the move and recover it. |
| 4 | 08 | [Recover a transaction across two shards](lessons/08-recover-a-cross-shard-transfer.md) | Recover PostgreSQL prepared transactions after two coordinator crashes. Compare the outcome with a saga that exposes an intermediate state and retries its compensation. |
| 4 | 09 | [Run the consensus and recovery gate](lessons/09-run-the-consensus-gate.md) | Rebuild the lessons and compare the client, replica, and disk evidence. |

Lesson 07 builds on [Core 07's placement lesson](../../../2-core/07-distributed-systems-fundamentals/lessons/10-move-fewer-keys-with-consistent-hashing.md) by moving durable state between groups. [Networking in depth](../../cloud-and-network/01-networking-in-depth/README.md) covers the network side of partial partitions.

## The gate

- Hold one follower behind the compaction point. Commit writes through the other two peers, snapshot their state, and restart a peer after the snapshot is published with the pre-compaction log still present. Rejoin the lagging peer through snapshot installation. Verify final values, preserved term and vote, and the original response when a client retries an acknowledged command after recovery.
- Replay the same partial partition with and without the election safeguards. With them enabled, the leader and its reachable follower must complete a write in the same term even as the third peer times out. In a separate schedule, a leader that loses majority contact must step down when its quorum check expires. Porcupine must accept the captured single-key histories and reject the stale-read control. A checker timeout fails the gate as inconclusive.
- Run TLC through the complete state space of the configured finite election model. Require the invariant to hold in the reference model and require the double-vote variant to produce an election-safety violation.
- Interrupt range movement and recover it. Require the source to refuse stale writes once fenced, the destination to preserve every acknowledged write and retry result, and the destination to accept a write once the new epoch is active. In the separate PostgreSQL lab, recover a prepared transfer to the recorded outcome on both shards and require both prepared-transaction lists to be empty. Check the compensation outcome independently.

The history checks cover observed single-key operations. The election model covers its bounded configuration. Range moves pause writes and keep each Raft group's membership fixed. The PostgreSQL lab checks the recovered outcome and observes the period in which participant locks are held. [Run the gate](gate/README.md)

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Trace a peer from a snapshot boundary through log replay and explain why it needs the boundary term. |
| Intermediate | Diagnose a disruptive election from a network trace and identify the completed operations that make a history impossible to linearize. |
| Senior | Defend the snapshot and range handoff crash boundaries, explain what the checker and model cover, and choose between 2PC and compensation for a concrete workflow. |

## Practice

- Use a separate protocol to test what you learned about retry receipts and client histories. [Chain replication exercise](exercises.md)
- Draw the failure timelines before opening the reference evidence. [Self-check](self-check.md)
- Inspect the WAL, client history, model checker, and transfer results. [Evidence](evidence/README.md)

Continue to [A Rust storage engine](../03-rust-storage-engine/README.md).
