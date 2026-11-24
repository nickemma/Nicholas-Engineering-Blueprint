# Caching

> Shared unit · Time: 1 week at 12–15 hours a week · Builds on [Core 03 Docker and Postgres](../../../2-core/03-docker-and-postgres/README.md) · Used by the storage engines track · Status: ready

Build a cache-aside read path for Switchyard job status. Keep the authoritative status and revision in PostgreSQL, store short-lived Redis copies, and delete them after a committed write. Use Go singleflight to share loads of the same missing key in one process. Measure database reads and verify that Redis failure leaves the database path available.

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| # | Lesson | What you'll build and check |
|---|---|---|
| 01 | [Keep job status in PostgreSQL](lessons/01-keep-job-status-in-postgresql.md) | Save and load a job with an increasing revision. |
| 02 | [Add cache-aside reads and invalidation](lessons/02-add-cache-aside.md) | Cache versioned copies with a TTL, reload misses, and delete the copy after a database write. |
| 03 | [Collapse concurrent misses with singleflight](lessons/03-collapse-concurrent-misses.md) | Measure a cold-key burst and give each waiting request its own cancellation. |
| 04 | [Measure expiry and Redis failure](lessons/04-measure-expiry-and-redis-failure.md) | Inspect a Redis key's TTL, pause Redis, and verify that PostgreSQL still handles reads and writes. |
| 05 | [Run the cache gate](lessons/05-run-the-cache-gate.md) | Catch a deliberately broken build that stops sharing the cold-key load. |

This unit adapts the Redis step from [Durable, auditable data](../../../2-core/03-docker-and-postgres/README.md) into a standalone lab.

## The gate

The [gate](gate/README.md) runs with Redis and PostgreSQL. One cold read and one warm read make one database read in total. A healthy write invalidation and Redis expiry each cause a reload. A cold burst of 32 readers makes one PostgreSQL read in one process. Reads and committed writes still work during a Redis pause. The negative control repeats the deterministic burst without singleflight and must make 32 origin reads.

The lab tolerates short-lived stale copies. It can serve one after a failed invalidation or a fill that raced with a write. Each inserted copy expires, and replicas share their in-flight loads only within their own processes.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Trace a hit, a miss, and a write that invalidates a copy. |
| Intermediate | Prove that a concurrent burst uses one origin read and explain how individual cancellation works. |
| Senior | Use read counts, revisions, and deadlines to explain the availability and staleness trade-offs of the cache under failure. |

## Practice

- [Exercises](exercises.md). Build and verify an inventory cache with a measurable load.
- [Self-check](self-check.md). Explain the failure paths and draw the stale-fill race.
- [Evidence](evidence/README.md). Inspect the live and negative-control results.
