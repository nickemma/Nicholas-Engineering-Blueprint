# Design: a distributed key-value store

**Track:** distributed-systems · **Built in:** [Phase 4](../../lessons/04-replicated-state/README.md) (Raft, linearizability checks, consistent hashing, leases) · **Time:** 45 minutes

This is a worked reference. Do the design yourself first, with a timer, then read this and note what you missed.

## 0. The crux

Two things together:
- **partition** 10 TB across many machines, and keep **each key linearizable**;
- survive a whole zone failing, and **move data while serving it**.

Concretely: how keys map to partitions, how each partition is replicated with consensus, how reads stay fast without giving up linearizability, and how partitions split and move. The API is trivial; spend the time on these.

## 1. Requirements

**Functional**

1. `Get(key)`, `Put(key, value)`, `Delete(key)`.
2. `CompareAndSet(key, expected, new)` for safe updates.
3. Range scans over a key prefix (nice to have).

**Non-functional**

| Property | Target |
|---|---|
| Data | 10 TB now, doubling yearly; keys ≤ 1 KB, values average 1 KB, at most 1 MB |
| Throughput | 100,000 operations a second at peak, 80% reads |
| Latency | p99 < 10 ms inside one region |
| Consistency | Linearizable per key |
| Durability | No acknowledged write lost if one node, or one zone, fails |
| Availability | Keeps serving with one of three zones down |

**Out of scope:** multi-key transactions (mention them), multi-region.

## 2. Estimates

- **Raw data with three copies:** 10 TB × 3 = 30 TB.
- **Nodes:** at 2 TB usable each and 60% full (room to rebalance and grow), 30 ÷ 1.2 = 25 nodes. Plan **24–30 nodes**, a third in each zone.
- **Load per node:** 100,000 ops/s ÷ 24 ≈ 4,000/s. That's easy; storage drives the node count, not throughput.
- **Partitions:**
  - With 512 MB ranges, 10 TB ÷ 512 MB ≈ 20,000 ranges.
  - × 3 replicas = 60,000 replicas, about **2,500 per node**.
  - That's 2,500 Raft groups per node, so per-group heartbeats must be batched or paused when idle.

## 3. API

`Get`, `Put`, `Delete`, `CompareAndSet`, `Scan(prefix, limit)`, over gRPC. Clients learn routing from the store, not configuration.

## 4. Core entities

- **Range:** a contiguous span of keys `[start, end)`, its replicas, and its current leaseholder.
- **The range directory:** a mapping from key spans to ranges, itself stored in the system.

## 5. High-level design

~~~mermaid
flowchart LR
    Client --> GW[Client library / router]
    GW -->|which range?| META[(Range directory: its own Raft group)]
    GW --> L1[Leaseholder of range 17]
    L1 --- F1[Replica, zone b]
    L1 --- F2[Replica, zone c]
    PD[Placement driver] -->|split / move| L1
    PD --> META
~~~

**A write:**
1. The client library finds the key's range from a cached copy of the directory.
2. It sends the write to that range's leader.
3. The leader appends it to the range's Raft log, commits once a majority of the three replicas (one per zone) has it on disk, applies it, and replies.

**A read** goes to the **leaseholder**, which can answer from local state (6.2).

## 6. Deep dives

### 6.1 Partitioning: ranges, not a hash ring (the crux, part 1)

| Option | Good | Bad |
|---|---|---|
| Consistent hashing | Even spread; small moves | No range scans; hot keys stay hot |
| **Range partitioning with automatic splits** | Range scans; split a hot or large range in two | Sequential keys hit the last range; needs a directory |

**Chosen: ranges, split automatically** at 512 MB or when a range's load is far above average.
- The directory is small (20,000 entries, each ~100 bytes ≈ 2 MB), so every client caches it.
- A misrouted request gets "not mine, try range 18" and refreshes the cache.
- **The sequential-key problem** (timestamps, auto-increment IDs) is handled at the schema level: prefix keys with a hash bucket. Say this, because interviewers check.

### 6.2 Replication and reads (the crux, part 2)

- **Each range is a Raft group of three**, one replica per zone. Losing a zone leaves two of three: still a majority, still writable.
- **Write latency:** one cross-zone round trip (0.5–2 ms) plus an `fsync` (~0.1–1 ms on NVMe). That's well under 10 ms.
- **Reads without a quorum round trip.** A plain Raft leader can't be sure it's still the leader without asking a majority. Two options:
  - **ReadIndex:** confirm leadership with one heartbeat round per read batch.
  - **Leader leases:** the leader holds a time-bound lease, and no new leader can take over until it expires. Reads are local, and correct only if clock drift is bounded.

  **Chosen: leases**, with a conservative bound and a fallback to ReadIndex when the clock is suspect.
- **2,500 Raft groups per node** cost heartbeats. Batch them per node pair, and let idle ranges go quiet: no heartbeats until the next write.

### 6.3 Moving data

The placement driver watches disk use and load, and moves replicas to even them out. **A move:**
1. Add a new replica as a **learner** (it receives the log but doesn't vote).
2. Catch it up with a snapshot plus the log.
3. Promote it to a voter.
4. Remove the old replica.

Each change is one configuration change through Raft, so the group is never left without a majority. Throttle moves so they don't starve live traffic.

### 6.4 Failure detection and repair

A dead node's ranges keep working on the other two replicas. After a **timeout of several minutes** (so a reboot doesn't trigger thousands of moves), the placement driver adds replacements elsewhere in the same zone.

## 7. Trade-offs

| Decision | Chose | Instead of | Because | Revisit when |
|---|---|---|---|---|
| Partitioning | Ranges with splits | Consistent hashing | Scans; splitting hot spots | Scans aren't needed and the directory becomes a burden |
| Replication | Raft per range | Leaderless quorums (Dynamo) | Linearizability and CAS | Availability during partitions matters more than consistency |
| Reads | Leader leases | ReadIndex on every read | One round trip saved per read | Clocks can't be trusted |
| Replicas | 3, one per zone | 5 | Tolerates one zone; cheaper writes | Two simultaneous failures must be survived |

## 8. Failure modes

| Failure | Effect | Detection | Mitigation |
|---|---|---|---|
| A node dies | Its leaderships move in an election timeout (~1 s); a brief latency spike | Raft leader changes; node heartbeats | Re-replicate after a timeout |
| A zone dies | Every range keeps a majority | Zone-level alerts | Replicas are spread per zone by construction |
| A network partition isolates a leader | The isolated leader can't commit; its lease expires; the majority side elects | Leader changes | CheckQuorum; PreVote |
| A hot key | One range overloaded | Per-range load | Split by load; cache in clients; for a single key, there's no split: rate-limit it or redesign |
| Clock jump on a leaseholder | Stale reads if leases are trusted wrongly | Clock-offset monitoring | Conservative lease bounds; refuse leases when offset is high |
| Disk slow | Commit latency rises for every range on the node | `fsync` latency metric | Move leaderships away from the node |

## 9. With more time

- **Multi-key transactions:** two-phase commit across ranges, with a transaction record in one of them (Phase 4, step 12).
- **Multi-region**, with per-region leaseholders for local reads.
- **Change-data-capture streams.**
- **TTLs.**

## 10. Where you've built this

[Phase 4](../../lessons/04-replicated-state/README.md):
- your own Raft: elections, replication, persistence, snapshots, PreVote and CheckQuorum;
- a replicated key-value store, checked for linearizability with Porcupine;
- leases and fencing tokens;
- consistent hashing;
- transactions across shards.

## 11. What an interviewer will push on

- "Why can't the leader just answer reads from its own state?"
- "What exactly happens in the first second after a leader dies?"
- "How do you move a range without a moment when two groups think they own it?"
- "Your keys are timestamps. What breaks?"
