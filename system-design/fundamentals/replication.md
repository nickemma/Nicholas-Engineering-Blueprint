# Replication

Replication keeps copies of the same data on several machines. That buys three things: survival when a machine dies, more read capacity, and copies closer to users. It costs coordination on every write.

## The options

| Model | How writes work | Good | Bad |
|---|---|---|---|
| **Single leader** (PostgreSQL streaming, MySQL) | All writes go to the leader, which ships them to followers | Simple; no write conflicts | The leader is a bottleneck; failover is hard to get right |
| **Leader with consensus** (Raft: etcd, CockroachDB ranges) | A write commits once a majority stores it; a new leader is elected safely | No lost committed writes; automatic failover | A majority must be reachable; latency is a majority round trip |
| **Multi-leader** | Several leaders accept writes and sync with each other | Writes in every region | Conflicts must be resolved (last-writer-wins loses data; CRDTs merge) |
| **Leaderless** (Dynamo-style: Cassandra) | Write to W replicas, read from R; with W + R > N, reads overlap writes | Available, no failover | Conflicts, read repair; overlapping quorums still aren't linearizable on their own |

**Synchronous or asynchronous?** A synchronous replica must confirm before the write succeeds: no loss, but slower, and blocked if the replica is down. An asynchronous one may lag, and loses the latest writes if the leader dies.

## Numbers to know

- A majority of 3 tolerates 1 failure; of 5, 2. Even numbers add cost without adding tolerance.
- Write latency is at least one round trip to the slowest member of the fastest majority. Across regions, that's tens of milliseconds per write.

## How it fails

- **Replication lag:** a user writes, then reads from a follower and doesn't see their own write. Read your own writes from the leader, or wait for the follower to catch up.
- **Split brain:** two nodes both think they're the leader. Use consensus, and **fencing tokens** for anything they write outside the cluster.
- **Failover that loses data:** promoting an async follower drops whatever it hadn't received.
- **Partial partitions:** A reaches B and C, but B and C can't reach each other. Leaders can flap (Phase 4, step 6).

## In an interview

Say which model, synchronous or not, what a reader can see (link to [Consistency models](consistency.md)), how failover works, and what's lost when it happens.

## Where you built it

- [Phase 4](../../lessons/04-replicated-state/README.md):
  - your own Raft, with leader election, log replication, persistence and snapshots;
  - PreVote and CheckQuorum against partial partitions;
  - linearizability checked with Porcupine;
  - a TLA+ model.
- [Phase 3](../../lessons/03-durable-auditable-data/README.md): backup and restore.
- [KESTREL](../../capstones/01-kestrel.md) studies what happens when connectivity is partial and intermittent.
