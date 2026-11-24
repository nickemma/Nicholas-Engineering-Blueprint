# Caching gate

From the Blueprint checkout, rebuild the lessons in a fresh directory and run the live gate.

~~~bash
SWITCHYARD_CACHING_LIVE=1 python3 scripts/replay_lessons.py 3-tracks/shared-units/caching
~~~

From the completed learner directory, run the same checks against your build.

~~~bash
SWITCHYARD_CACHING_LIVE=1 bash "$blueprint/3-tracks/shared-units/caching/gate/run.sh" "$PWD"
~~~

The gate starts disposable `redis:8` and `postgres:17` Docker containers on loopback, then removes the containers and their anonymous volumes. Leaving out `SWITCHYARD_CACHING_LIVE=1` runs formatting, vet, and the race-enabled deterministic tests.

Look for five outcomes.

1. A cold read and a warm read make one PostgreSQL read in total. The committed write deletes the copy, and the next read gets the new revision.
2. The cached copy has a positive TTL, expires, and reloads from PostgreSQL. A nonexistent job stays uncached.
3. Thirty-two concurrent readers of an empty key share one database read. Cancelling one waiter leaves the shared fill available to the others.
4. With Redis paused for two seconds, the fallback read and database write finish within the gate's 1.5-second ceiling. Cache failures are logged.
5. Disabling singleflight in a scratch copy of the code makes the deterministic burst fail with exactly 32 origin reads.

See the [recorded results](../evidence/README.md).

## Inspect a job manually

Point `CACHE_DATABASE_URL` and `CACHE_REDIS_URL` at a disposable PostgreSQL database and Redis instance. From the learner directory, build the CLI and run:

~~~bash
go build -o cache-jobs ./cmd/jobs
./cache-jobs init
./cache-jobs set demo queued
./cache-jobs get demo
./cache-jobs get demo
./cache-jobs set demo running
./cache-jobs get demo
~~~

To inspect the cached copy between commands, run `redis-cli -u "$CACHE_REDIS_URL" PTTL switchyard:job:v1:demo`. A positive value reports milliseconds to expiry. After the write, check the key before the next read fills it. The CLI starts a fresh process for each command. Use the Go test for concurrent readers within a process.
