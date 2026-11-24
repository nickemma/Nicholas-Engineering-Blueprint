# 07 Distributed-systems fundamentals

> The core · Time: 6 weeks at 12–15 hours a week · Builds on [03 Docker and Postgres](../03-docker-and-postgres/README.md), [04 Rust foundations](../04-rust-foundations/README.md), and [06 Linux, networking, and profiling](../06-linux-networking-and-profiling/README.md) · Status: ready

## What you'll learn

Use a seeded network to replay crashes, pauses, message loss, and one-way partitions. Distinguish timeout-based suspicion from knowledge, and identify the conditions under which a protocol can make progress. Build Raft elections and log replication, then take the same Go core from simulated disks to real Linux processes backed by the Rust `klog`.

## What you'll build

**`metad`**, a Go service that replicates a small set of Switchyard coordination metadata across three fixed peers. A committed command can set a metadata value or grant a lease. A Rust writer opens each peer's own `klog` and acknowledges batches after synchronization. The lesson on fencing uses a paused worker to show why the resource accepting a write has to check its token. The final lesson distributes a disposable metadata cache across a hash ring and measures how many keys move when cache membership changes.

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [What a node can know](lessons/01-what-a-node-can-know.md) | Build a seeded scheduler and directed links. Make a heartbeat monitor mistake a long pause for a crash. Use that trace to introduce timing models, logical clocks, FLP, and CAP. |
| 1 | 02 | [Elect a leader with a quorum](lessons/02-elect-a-leader-with-a-quorum.md) | Give a single-threaded Go Raft core terms, votes, and seeded election timeouts. Reproduce a split vote and verify that at most one node wins each term. |
| 2 | 03 | [Replicate and repair a log](lessons/03-replicate-and-repair-a-log.md) | Add AppendEntries and per-follower progress tracking. Run a partition where a returning peer has a conflicting suffix. Check that matching prefixes stay intact. |
| 2 | 04 | [Decide what is committed](lessons/04-decide-what-is-committed.md) | Walk through Raft Figure 8. Use the vote freshness rule and the current-term commit rule to defend the committed prefix. Apply commands in index order and acknowledge only after commit and application. |
| 3 | 05 | [Save before you reply](lessons/05-save-before-you-reply.md) | Add a simulated disk per peer and crash at the boundaries between save, send, and apply. Show how forgetting a vote can let two candidates win the same term after a restart. |
| 3 | 06 | [Persist Raft state in the Rust log](lessons/06-persist-raft-state-in-the-rust-log.md) | Store a versioned batch per Raft update. A batch can record a term, vote, and logical suffix replacement together. Reopen and replay verified `klog` records, repair a torn final frame, and refuse complete corruption. |
| 4 | 07 | [Run three real processes](lessons/07-run-three-real-processes.md) | Move the same Raft core into a Go runtime with bounded peer calls and one local Rust writer per peer. Send a metadata write through the client API and recover it after a leader restart. Route client reads through the replicated log. |
| 4 | 08 | [Kill a writer during a partition](lessons/08-kill-a-writer-during-a-partition.md) | Use a Unix-socket proxy to control the partition and a test-only barrier to interrupt an append. Capture client acknowledgments, per-peer state, and the repaired log. |
| 5 | 09 | [Fence a worker that outlives its lease](lessons/09-fence-a-worker-that-outlives-its-lease.md) | Apply lease decisions using time carried in the replicated command. Pause a worker past expiry, grant a higher token, and have the resource enforce that token in the same operation as the write. |
| 6 | 10 | [Move fewer keys with consistent hashing](lessons/10-move-fewer-keys-with-consistent-hashing.md) | Compare modulo placement with a ring and virtual nodes over the same fixed key set. Measure balance and movement when adding or removing a cache node, then run a hot-key workload. |

The Storage engines track builds on this module with snapshots, PreVote and CheckQuorum, linearizability checking, TLA+, and transactions across shards. [Consensus in depth](../../3-tracks/storage-engines/02-consensus-in-depth/README.md)

## The gate

The [automated gate](gate/README.md) starts three Linux peers with separate logs and Unix-socket links. Commit a baseline write, isolate the leader from both followers, then pause its Rust writer after part of the next record reaches the file. Use `kill -9` to stop the isolated peer and its writer. Let the connected pair elect a leader and commit a write to a different key. Restart the killed peer while it is still isolated, then heal the partition.

- The connected pair acknowledges its committed write. The isolated peer never acknowledges the interrupted proposal, including after it restarts in isolation.
- Election history has at most one winner per term. Any two peers that commit the same index agree on its term and command. An isolated peer can still consider itself leader of an older term while it lacks a quorum.
- The restarted peer recovers the verified prefix, reports the torn bytes it trimmed, and catches up to the committed state. Both acknowledged writes are still readable through the client API after healing. Each peer's `klog` passes its integrity check. A separate run with a corrupted complete record checks startup refusal and byte preservation.
- A companion run lets the isolated leader finish a local append and checks that the client still receives no success. This run must fail on a deliberately broken build that acknowledges after a local append, before quorum commit. The harness owns the processes it kills and uses temporary files and Unix sockets, so the gate runs without root, containers, or cloud services.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Read a seeded election trace, identify a quorum, and explain why a silent peer is only suspected. |
| Intermediate | Explain how a leader repairs a divergent suffix and which state must reach disk before a peer replies. |
| Senior | Design a failure schedule that distinguishes election safety, state machine safety, and progress. Defend the restart and acknowledgment boundaries using client and disk evidence. |

## Practice

- [Exercise](exercises.md). Build a separate fenced work queue with a durable issuer and protected resource.
- [Self-check](self-check.md). Trace an election and a conflicting suffix from memory.
- [Evidence](evidence/README.md). Read the test and gate captures.

## Next

[08 Shipping safely](../08-shipping-safely/README.md) adds the deployment, security, and operational practices needed to run Switchyard.
