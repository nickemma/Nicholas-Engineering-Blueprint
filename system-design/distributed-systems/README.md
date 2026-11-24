# Distributed systems

For distributed-systems, storage and SRE roles. These designs are mostly the things the others are built on, and [Core 07](../../2-core/07-distributed-systems-fundamentals/README.md) and [Consensus in depth](../../3-tracks/storage-engines/02-consensus-in-depth/README.md) built most of their cores.

**Worked design:** [a distributed key-value store](key-value-store.md). Do it yourself first, then compare.

**How to use the prompts:**
1. Set a 45-minute timer and design with the [template](../_template.md).
2. Open **the crux** only if you haven't named one by minute 10.
3. Open **what a strong answer covers** only after the timer, then score yourself with the [scorecard](../scorecard.md).

## 1. A distributed lock service

Locks for thousands of services, to elect leaders and to guard jobs that must run once. 10,000 lock operations a second; a holder that crashes must lose its lock within 10 seconds; correctness over availability.

<details><summary>The crux</summary>A lock in a distributed system is a lease that can expire while its holder still thinks it holds it (a long GC pause, a network delay). Safety needs fencing tokens checked by whatever the lock protects, not just the lock itself.</details>

<details><summary>What a strong answer covers</summary>

- Built on consensus (a Raft group of 3 or 5), not on a single Redis.
- Leases with TTLs, renewed by heartbeats; sessions so one dead client releases all its locks.
- **Fencing tokens:** a number that increases with each grant, which the protected resource checks.
- Watches, so waiters are notified, not polling.
- Why it's not for high-throughput data: every operation is a consensus write.
- Failure: a holder pauses past its lease, so a second holder starts, and the token stops the first one's late write.
</details>

**Built in:** [Core 07, lesson 09](../../2-core/07-distributed-systems-fundamentals/lessons/09-fence-a-worker-that-outlives-its-lease.md).

## 2. A Kafka-style log

A durable, partitioned, replicated log: 1 GB/s in, many consumer groups out, 7 days of retention, ordering per partition, no acknowledged message lost if one broker dies.

<details><summary>The crux</summary>Sequential disk I/O and replication: each partition is an append-only log on disk, replicated to followers, and "committed" must mean "on enough replicas". Plus how a partition's leadership moves without losing or reordering messages.</details>

<details><summary>What a strong answer covers</summary>

- Estimates: partitions needed for 1 GB/s (per-partition throughput is tens of MB/s), disk for 7 days × 3 replicas (~1.8 PB).
- Segments, an index from offset to position, the page cache, zero-copy sends.
- Leader per partition; in-sync replicas; `acks=all` with a minimum in-sync count.
- Controller metadata in a consensus group (KRaft); leader election only from in-sync replicas.
- Consumer groups: partition assignment, committed offsets, rebalancing.
- Producer idempotence (sequence numbers per producer) against duplicates on retry.
- Failure: a follower falls behind, so it's dropped from the in-sync set.
</details>

**Built in:** [Event streams, lesson 03](../../3-tracks/shared-units/event-streams/lessons/03-relay-and-resend.md), [Core 04](../../2-core/04-rust-foundations/README.md)'s append-only log, [Core 07](../../2-core/07-distributed-systems-fundamentals/README.md)'s Raft log.

## 3. A distributed job scheduler

Run millions of jobs a day: one-off, delayed and recurring (cron), each exactly once, retried on failure, across a fleet of workers. Jobs scheduled for the same second must start within 2 seconds of it.

<details><summary>The crux</summary>Finding due jobs efficiently without one scanner being a bottleneck or a single point of failure, and handing each due job to exactly one worker even when workers crash mid-run.</details>

<details><summary>What a strong answer covers</summary>

- Jobs partitioned by ID; each partition's due-time index (a sorted set, or a table with an index on `run_at`).
- One leader per partition finds due jobs (a lease), or workers claim them with `SELECT ... FOR UPDATE SKIP LOCKED`.
- **Visibility timeouts:** a claimed job reappears if its worker doesn't finish or heartbeat.
- At-least-once execution plus idempotent jobs = effectively once.
- Recurring jobs: compute the next run when the current one is scheduled, not with a global cron loop.
- Fairness between tenants; a dead-letter state after N failures.
- Failure: a thundering herd at midnight, so add jitter.
</details>

**Built in:** [Postgres in depth, lesson 04](../../3-tracks/storage-engines/01-postgres-in-depth/lessons/04-claim-and-recover-background-jobs.md) (`SKIP LOCKED`), [Messaging and resilience](../../3-tracks/shared-units/messaging-and-resilience/README.md) (retries, dead letters), Switchyard itself.

## 4. A unique ID generator

IDs for every object in a large system: 100,000 a second, unique across 1,000 machines, roughly sortable by time, 64 bits, no central bottleneck.

<details><summary>The crux</summary>Uniqueness without coordination per ID, and what happens when a machine's clock goes backwards.</details>

<details><summary>What a strong answer covers</summary>

- A Snowflake-style layout: 41 bits of milliseconds since an epoch, 10 bits of machine ID, 12 bits of sequence. Do the arithmetic: 69 years, 1,024 machines, 4,096 IDs per millisecond per machine.
- Machine IDs assigned once, from a coordination service (a lease, so two machines never share one).
- A clock that moves backwards: refuse to issue until it catches up, or use the last timestamp.
- The alternatives: UUIDv4 (random, 128 bits, not sortable), UUIDv7 (time-ordered, 128 bits), database sequences (central), ranges leased in blocks.
- Why sortable IDs help B-tree indexes (inserts land at the end).
</details>

**Built in:** [Core 07](../../2-core/07-distributed-systems-fundamentals/README.md) (leases, clocks), the [classic URL shortener](../classic/url-shortener.md).

## 5. A distributed cache

A shared cache for many services: 1 million reads a second, 50,000 writes a second, 2 TB of data, p99 under 2 ms, a node failure must not cause a stampede on the databases behind it.

<details><summary>The crux</summary>Partitioning that survives nodes coming and going without moving everything, and what happens to the databases when a node, and its share of the hits, disappears.</details>

<details><summary>What a strong answer covers</summary>

- Consistent hashing with virtual nodes; clients route directly (no proxy hop) or through a thin proxy.
- Memory per node and node count from 2 TB.
- Replicas for hot keys or for availability; or none, and accept misses.
- Eviction (LRU or LFU), TTLs.
- **Stampede protection:** request coalescing, early refresh with jitter, and a warm-up for new nodes.
- Failure: a node dies, so its keys miss. Can the databases take that load? If not, replicate.
- Invalidation from writes; key versioning.
</details>

**Built in:** [Caching, lesson 02](../../3-tracks/shared-units/caching/lessons/02-add-cache-aside.md), [Core 07, lesson 10](../../2-core/07-distributed-systems-fundamentals/lessons/10-move-fewer-keys-with-consistent-hashing.md), [DSA guides 06 and 19](../../dsa/19-design/README.md).

## 6. A distributed rate limiter

Per-customer limits for an API served by 200 gateway instances in 3 regions: 500,000 requests a second, limits per second and per day, decisions in under 1 ms of added latency.

<details><summary>The crux</summary>Sharing a counter across 200 instances without a network round trip per request, and deciding how exact the limit must be.</details>

<details><summary>What a strong answer covers</summary>

- The algorithm: a token bucket, or a sliding window counter.
- **The trade-off:**
  - a central store (Redis, with an atomic script) is exact, but adds a round trip;
  - local buckets with a share of the limit, synced periodically, are fast but approximate.
- Per region, or global? Global daily quotas can sync slowly; per-second limits must be local.
- Failure of the store: fail open to local limits, or closed.
- Responses: `429` with `Retry-After`, and limit headers.
- Hot customers: shard their counters.
</details>

**Built in:** [Tenancy and abuse control, lessons 05–06](../../3-tracks/shared-units/tenancy-and-abuse-control/lessons/05-authorize-routes-and-budget-each-tenant.md), [DSA guide 19](../../dsa/19-design/README.md).
