# 05 Run the cache gate

> Caching · Week 1

## The problem

Thirty-two successful responses alone say nothing about the number of database reads they caused. Compare the reference and the same test with request sharing removed.

## The mental model

~~~text
same concurrent cold-key test
    reference: share the fill         →  1 origin read
    variant:   fill once per request  → 32 origin reads
~~~

## Check it

~~~bash
SWITCHYARD_CACHING_LIVE=1 bash "$blueprint/3-tracks/shared-units/caching/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/shared-units/caching/gate/run.sh" "$PWD" -->

The gate checks warm reads, invalidation, expiration, the cold burst, and fallback while Redis is paused. Then it removes singleflight in a disposable copy and requires the exact origin-read failure. [Recorded runs](../evidence/README.md)

In the reference run, the fallback read and committed write took 511 ms during a two-second Redis pause. Treat this as a measurement from the lab. The time varies with the host and database load.

## If it goes wrong

| Symptom | Check |
|---|---|
| Two sequential reads both hit PostgreSQL | Check the Redis fill warning and key TTL. |
| A healthy read after a write returns the previous revision | Confirm the database wrote first and the cache delete used the same key. |
| The live burst makes multiple database reads | Check per-key sharing and the second lookup inside the group. |
| The fallback finishes only after Redis resumes | Confirm the client respects the cache context deadline and retries are disabled. |
