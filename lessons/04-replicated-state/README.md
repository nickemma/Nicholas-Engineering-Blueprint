# Phase 4: replicate and scale out

**Question:** what can several machines agree on when messages are lost and delayed, machines crash, and the network splits, sometimes only partly? And how do you spread data over machines when one is no longer enough?

**Time:** about 10 weeks. **Prerequisites:** [Phase 3](../03-durable-auditable-data/README.md); Java 11 or newer for TLA+.

## Syllabus

| Step | Topic | You'll learn |
|---|---|---|
| 1 | A simulated network | Failure models (crash-recovery, omission, Byzantine); timing models; clocks and logical clocks; failure detectors and false suspicion; FLP and CAP stated precisely; deterministic simulation testing; one-way and partial partitions |
| 2 | Raft: leader election | State machine replication; terms as logical clocks; votes and quorums; randomised timeouts; election safety; a pure state-machine core with `Tick`, `Step` and `Ready`; checking invariants after every step |
| 3 | Raft: log replication | AppendEntries and the consistency check; Log Matching; conflicts and truncation; `next` and `match`; commitment; the up-to-date rule and Leader Completeness; Figure 8 and its two protections; safety vs liveness; directed scenario tests |
| 4 | Persistence | What must be saved and when; save, send, apply; a write-ahead log with one `fsync` per batch; torn writes; amnesia; why rare crash points need many seeds |
| 5 | Snapshots and compaction | Snapshots; InstallSnapshot and the "same history" rule; an offset log; atomic file replacement with a directory `fsync`; crash between two files; a bug the simulator found, and regression tests |
| 6 | Partial partitions | Disruptive returners; partial partitions in real outages; PreVote and CheckQuorum; why two checks guarding one door need separate tests; the open research problem |
| 7 | A linearizable store | Deterministic state machines; client sessions and exactly-once retries; reads through the log, ReadIndex and leases; linearizability; Porcupine; a stale read found and visualised |
| 8 | Running it for real | The runtime loop; one goroutine owning the core; waiting for proposals by index and term; a transport that never blocks; 421 redirects; a three-process cluster and `kill -9` |
| 9 | TLA+ | State machines in maths; TLC and exhaustive checking; invariants and history variables; abstraction; reading a counterexample; what a model proves and doesn't |
| 10 | Leases and fencing | Leases and renewal; time inside a replicated state machine; process pauses; fencing tokens checked at the resource |
| 11 | Consistent hashing | Partitioning; `hash mod N` vs a ring; virtual nodes; rendezvous hashing; hot keys and key splitting; rebalancing; a cache ring over three Redis servers that survives losing one |
| 12 | Transactions across shards | Two-phase commit, its decision record, blocking and presumed abort; PostgreSQL's prepared transactions; sagas and compensation; atomicity vs isolation |

## What you'll be able to do

- Test distributed code deterministically, and turn a failing run into a seed you can replay.
- Explain and implement Raft (election, replication, persistence, snapshots, PreVote and CheckQuorum), and say which rule protects which property.
- Prove a replicated service linearizable with a checker, and show the mistakes that break it.
- Run a Raft cluster as real processes, kill members, and explain what the logs show.
- Model a protocol in TLA+ and read a model checker's counterexample.
- Use leases and fencing tokens correctly, and explain why a lock alone can't protect a resource.
- Partition data with consistent hashing, measure the result, and deal with hot keys.
- Choose between two-phase commit and a saga, knowing what each costs.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md), typing every piece of code yourself, starting from your Phase 3 code.
2. Do every "Break it". Most of them are a seed that fails, or a counterexample that TLC or Porcupine prints, and each one is worth reading closely.
3. Answer [learned.md](learned.md).
4. Build the exercise project, **[chainkv](exercises.md)**, a key-value store replicated with *chain replication*, a different protocol, on your own. The exercise page shows exactly what finished looks like.
5. Take the [self-test](../../notes/learned/04-replicated-state.md).

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where | Evidence |
|---|---|---|
| Failure models, clocks, consensus (row 20) | Steps 1–9 | Storm tests across thousands of seeds; Figure 8; the `metad` kill experiment |
| Sharding, consistent hashing, leases (row 21) | Steps 10–11 | Key-movement and balance measurements; the fencing tests |
| Formal methods, TLA+ (row 22) | Step 9 | TLC's check, and its counterexample for a broken vote rule |
| Files, `fsync`, crash consistency (row 17) | Steps 4–5 | The WAL's torn-write and crash-between-files tests |
| Testing (row 5) | Every step | Deterministic simulation, directed scenarios, regression tests, Porcupine |
| Concurrency and races (row 8) | Steps 8, 11 | One goroutine owning the core; a race caught in a test |
| Transactions (row 16) | Step 12 | 2PC's blocking and a saga's visible middle, measured |

## Patterns introduced

These link to the [patterns ledger](../../JOURNEY.md#6-patterns-ledger):
- replicated state machine;
- leader election with terms;
- write-ahead log;
- snapshot and log compaction;
- deterministic simulation testing;
- sessions for exactly-once;
- leases and fencing tokens;
- consistent hashing with virtual nodes;
- two-phase commit;
- saga with compensation;
- functional core, imperative shell (the pure Raft core and its runtime).

## Next

Runway can now survive the loss of machines, and spread across several. It still runs on your laptop, started by hand. [Phase 5](../05-constrained-operations/README.md) puts it in containers, on Kubernetes and AWS, behind load balancers, with the observability and runbooks to operate it.
