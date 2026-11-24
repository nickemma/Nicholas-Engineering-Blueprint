# Docker and Postgres evidence

These are captures from a local Linux host. The database experiments use disposable PostgreSQL 17 containers, a dedicated Docker network, and lab credentials.

| Capture | What happened |
|---|---|
| [01-memory](lessons/01-memory.txt) | The Core 01 service accepted a job. A lookup returned 200 before restart and 404 after restart. |
| [01-docker](lessons/01-docker.txt) | A marker in the writable layer survived restart and disappeared on replacement. A marker on the named volume survived replacement. |
| [02-schema](lessons/02-schema.txt) | Both migrations ran on a fresh database and the second upgraded an existing database. PostgreSQL rejected a negative duration and used the partial index for the seeded queue query. |
| [03-contract](lessons/03-contract.txt) | The shared race-enabled contract passed on both the memory and PostgreSQL repositories. |
| [03-stale-write](lessons/03-stale-write.txt) | Disabling the SQL state predicate made the same test fail because both competing writes succeeded. |
| [04-pool-exhaustion](lessons/04-pool-exhaustion.txt) | Holding the only connection caused HTTP 503 after 51 ms. Returning it let the next request succeed with HTTP 201. |
| [04-api-restart](lessons/04-api-restart.txt) | A running Switchyard instance exposed pool metrics and returned the same stored job after restarting the control plane. |
| [05-completion](lessons/05-completion.txt) | A refused effect insert rolled back the completed state. A retry committed both changes. The cancellation race also passed 20 consecutive runs. |
| [05-http-effect](lessons/05-http-effect.txt) | A worker completed a job over gRPC and the HTTP API read one recorded effect. |
| [05-early-commit](lessons/05-early-commit.txt) | Committing before the effect insert made the rollback test catch a completed job with zero effects. |
| [06-submission](lessons/06-submission.txt) | Two concurrent requests produced one job. A failed key write rolled back the job. |
| [06-replay-http](lessons/06-replay-http.txt) | After SIGKILL, the API returned the original 201, Location, and body. It returned 422 when the same key came with a different payload. |
| [07-recovery](lessons/07-recovery.txt) | Recovery requeued the running job, kept the terminal job and its effect, and advanced the sequence. |
| [07-crash](lessons/07-crash.txt) | After SIGKILL, a replacement lease finished the same job and the old token was refused. |
| [08-benchmark](lessons/08-benchmark.txt) | Five measured runs per backend at 40 submissions/s, with all 1,200 measured requests returning 201. |
| [Compose gate](gate/pass.txt) | The full gate passed, including replacing PostgreSQL with the same named volume. |
| [Disabled fence](gate/stale-token.txt) | Skipping the token match in PostgreSQL mode made the gate fail because the old token completed the job. |
| [Full replay](gate/replay.txt) | Rebuilds Switchyard from the Core 01 lessons through the Compose gate. |

The `kload` experiment used one worker, 5 ms jobs, one local Docker host, and the default four-connection database pool. PostgreSQL was higher by 5.53 ms at p50 and 9.98 ms at p99 in this workload. The raw [memory runs](benchmark/memory), [PostgreSQL runs](benchmark/postgres), and [run order](benchmark/order.txt) are included. The first PostgreSQL run's p99 was 26.04 ms and the next four were between 9.86 and 11.18 ms.

Repeat the commands in each lesson to reproduce the corresponding capture.

Set `SWITCHYARD_REPLAY_COMPOSE=1` to run the Compose gate at the end of replay. The gate provisions its own database for integration tests. To include also the intermediate integration tests, set `SWITCHYARD_TEST_DATABASE_URL` to a separate disposable PostgreSQL database reachable from the host. Replay applies the lesson's migrations and writes test jobs there.

~~~bash
SWITCHYARD_REPLAY_COMPOSE=1 python3 scripts/replay_lessons.py 2-core/03-docker-and-postgres
~~~
