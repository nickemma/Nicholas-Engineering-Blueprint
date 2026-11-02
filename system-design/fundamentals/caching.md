# Caching

A cache keeps the answers to recent or popular questions somewhere faster than the source of truth. It's the single biggest lever for read-heavy systems, and the most common source of "why is this data wrong?".

## The options

| Choice | Options | Trade-off |
|---|---|---|
| **Pattern** | **Cache-aside** (the app reads the cache, and on a miss reads the database and fills the cache); **read-through**; **write-through** (write both); **write-behind** (write the cache, flush later) | Cache-aside is simple, and a cache outage only slows things. Write-behind is fast, but can lose writes |
| **Where** | In the process (fastest, but per instance and lost on restart), a shared cache (Redis, Memcached), a CDN at the edge | In-process caches disagree with each other; shared caches add a network hop |
| **Invalidation** | A TTL; delete on write; versioned keys; events from the database | TTLs bound staleness, but can't remove it. Deleting on write races with concurrent reads |
| **Eviction** | LRU, LFU, TTL-only | LRU suits recency; LFU suits stable popularity (DSA guides 06 and 19) |

## Numbers to know

- A shared cache hit costs a network round trip, about 0.2–1 ms. A database query is more, usually 1–10 ms or worse.
- **Hit rate is everything.** At 90%, the database sees 10% of reads; at 99%, 1%. That's a 10× difference from nine points.

## How it fails

- **Stampede:** a popular key expires, and a thousand requests miss at once and all hit the database. The fix is to let one request recompute while the others wait (singleflight), or to refresh early with jitter.
- **Stale data:** the write and the invalidation race. A reader fills the cache with old data just after the writer deletes it.
- **Hot keys:** one key's traffic overwhelms one cache node. Replicate it, or cache it in-process.
- **Cache as a dependency:** if the database can't take the full load, losing the cache is an outage. Know whether yours is an optimisation or load-bearing.
- **Caching across tenants:** a key without the tenant's ID serves one customer's data to another.

## In an interview

State the pattern, what's cached, the TTL and how invalidation works, the expected hit rate, and what a user sees when it's stale. Then name the stampede, and how you prevent it.

## Where you built it

- [Phase 3, step 7](../../lessons/03-durable-auditable-data/TEACHING.md#step-7-redis-cache-aside): cache-aside with Redis, stampede protection (singleflight), and failing open, so a Redis outage only slows things down. [Step 9](../../lessons/03-durable-auditable-data/TEACHING.md#step-9-a-circuit-breaker-around-the-database) puts a breaker on the database, under the cache.
- [Phase 4, step 11](../../lessons/04-replicated-state/TEACHING.md#step-11-consistent-hashing-and-a-cache-spread-over-several-servers): the cache spread over several servers.
- [Phase 6](../../lessons/06-safe-shared-queries/README.md): the cache key gained the tenant. A test now proves it's there, after a review found it missing.
