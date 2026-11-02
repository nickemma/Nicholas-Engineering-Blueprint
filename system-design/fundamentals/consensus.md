# Consensus

Consensus is how a group of machines agrees on one value, or one ordered log of values, even when some crash and messages are delayed. It's the core of every strongly consistent replicated system: leader election, configuration, locks, metadata.

## The options

| | Raft | Multi-Paxos | Viewstamped Replication |
|---|---|---|---|
| Designed for | Understandability | Generality | The first practical version (1988) |
| Leader | Strong leader; the log flows from it | Usually a stable leader in practice | A primary per view |
| Used by | etcd, Consul, CockroachDB, TiKV | Chubby, Spanner | |

They're equivalent in power. **In practice you use a library or service** (etcd, ZooKeeper, a Raft library), rarely your own.

## What consensus gives you

- A **replicated log** applied in the same order on every node, so every node's state machine ends in the same state.
- **Safety always:** no two nodes commit different entries at the same index, whatever the timing.
- **Liveness only when a majority is up and can talk:** it may stall, but never lie.

## Numbers to know

- 3 nodes tolerate 1 failure; 5 tolerate 2. Most systems use 3 or 5. More nodes means slower writes.
- A commit costs one round trip from the leader to a majority, plus a durable write (`fsync`) on each.
- Election timeouts are ~10× the heartbeat interval (often 150–300 ms against 10–50 ms), so a dead leader is replaced within a second or so.

## How it fails

- **Losing the majority:** the system stops accepting writes. That's correct, but it's an outage.
- **Partial partitions:** a node that can reach some peers but not the leader keeps starting elections. PreVote and CheckQuorum fix it.
- **Slow disks:** `fsync` latency is commit latency.
- **Using it for everything:** consensus is for small, critical metadata. Bulk data goes elsewhere, and the consensus log just points at it (see [capstone 6](../../capstones/06-checkpoint-store.md)).
- **FLP:** no deterministic algorithm can guarantee agreement in a fully asynchronous system with even one crash. Real systems use timeouts, and accept that liveness depends on them.

## In an interview

Don't design consensus; **use** it, and say for what: *"leader election and the partition map live in etcd; the data path doesn't touch it."* Know the majority rule and the cost per write. Know what happens when the majority is lost.

## Where you built it

[Phase 4](../../lessons/04-replicated-state/README.md), steps 1–9:
- your own Raft on a deterministic simulated network: elections, log replication, persistence and snapshots;
- PreVote and CheckQuorum;
- linearizability checks;
- a TLA+ model of elections.
