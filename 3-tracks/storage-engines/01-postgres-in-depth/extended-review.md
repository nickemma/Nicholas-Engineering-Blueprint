# Extended review

Related modules for this review are [Docker and Postgres](../../../2-core/03-docker-and-postgres/README.md), [Event streams](../../shared-units/event-streams/README.md), [Caching](../../shared-units/caching/README.md), [Audit and integrity](../04-integrity-and-encryption/README.md).

Answer from memory, then check yourself against [the lesson](README.md). Write each "predict" answer before running anything.

## A. PostgreSQL behind a port

1. What's a primary key, an identity column, a `CHECK` constraint and a foreign key? Give one example of each from Switchyard's schema.
2. Why keep constraints in the database when the domain already validates the same rules?
3. What is a migration, and what does goose record in `goose_db_version`?
4. Predict: a client sends `' OR '1'='1` as a description, and the code builds SQL by joining strings. What happens? What happens with `$1`?
5. Why does `Create` read the timestamps back with `RETURNING`? What would a contract test with whole-second times have missed?
6. What does `pgtest.URL` do, and why does each test get its own schema?
7. Why did the domain, HTTP handlers and gRPC server not change when PostgreSQL arrived?

## B. Pools and transactions

8. Why is a database connection expensive? What does PostgreSQL run for each one?
9. With 400 queries a second taking 5 ms each, how many connections are busy on average? Ten instances share `max_connections = 100`: what would you set `DB_MAX_CONNS` to?
10. Predict: the pool has 2 connections, both busy for 3 seconds, and a request with a 100 ms deadline arrives. What does it get, and when?
11. State ACID in one sentence per letter.
12. Draw the lost-update timeline. Which isolation level prevents it, and what does the second transaction see?
13. Give three fixes for a read-modify-write race, and the cost of each.
14. What is write skew? Give an example that `REPEATABLE READ` doesn't prevent.
15. What does SQLSTATE `40001` mean, and what must the caller do?
16. Predict: one statement inside `BeginFunc` uses `s.pool` instead of `tx`. Which failures does that let through?

## C. The outbox and idempotency

17. What is the dual-write problem? Why doesn't swapping the order fix it?
18. How does the transactional outbox close it? Why is it at least once rather than exactly once?
19. What do `FOR UPDATE` and `SKIP LOCKED` each do? What happens with neither?
20. Why can relays running on several instances deliver one job's events out of order?
21. Why is "check whether the key exists, then insert it" a race? What one statement replaces it?
22. Predict: the key store's `Begin` fails because the database is down. What should the middleware answer, and why not just run the request?
23. Two instances started together and one died during migration. Why? What fixed it?
24. What gap remains between the idempotency key and the job, and how would you close it?

## D. Kafka

25. Define topic, partition, offset, key and consumer group.
26. How does Kafka keep one job's events in order? What order does it *not* promise?
27. A topic has 3 partitions and a group has 5 members. How many are busy?
28. What is lag, and what does growing lag tell you?
29. How do you replay a stream into a new read model? Why can't you do that with a RabbitMQ queue?
30. Why does the projector need an inbox when Switchyard's job handlers didn't? Why must the inbox insert be in the same transaction as the count?
31. Why does a failed record stop the consumer instead of being skipped? What's the alternative?
32. What bug made `Close` hang, and what fixed it?

## E. Caching

33. Describe cache-aside reads and writes. Why delete on write instead of updating?
34. Draw the race that can still cache a stale value. What bounds how stale it gets?
35. Why can a finished job be cached for an hour, but a running job only for seconds?
36. What is a stampede? Predict: 100 concurrent misses on one key, with and without singleflight. How many database reads?
37. What does "fail open" mean for a cache? Why does each Redis call need its own short timeout?
38. Why does the cache key contain `v1`?

## F. Background jobs and indexes

39. Why must a background task be idempotent and resumable? Why delete in batches?
40. What does `pg_try_advisory_xact_lock` guarantee? What doesn't it? What happens to the lock if its holder crashes?
41. Why does a panic in a background goroutine need a `recover`? What does `recover` not fix?
42. What makes a job "abandoned"? What goes wrong if `ABANDON_AFTER` is too short?
43. Read this: `Parallel Seq Scan ... Rows Removed by Filter: 333072`. What did the database do?
44. What is a partial index, and why was it 40 kB on an 81 MB table?
45. Why can't `CREATE INDEX CONCURRENTLY` run in a transaction?

## G. Failing well

46. Which errors should open a database breaker? Which must not, and why?
47. Why does the breaker sit under the cache?
48. Liveness vs readiness: which should a database outage fail, and what happens if you choose wrong?
49. Predict: the database is frozen and the breaker threshold is 5. What do requests 1 to 5 and 6 to 10 return, and how long does each take?

## H. The audit log and recovery

50. What makes a log an audit trail rather than just a history?
51. Describe the `klog ingest` protocol. Why must a line never contain a line break?
52. When can an event be written to the audit log twice? How would you find out?
53. What does CRC-32C protect against? What would protect against deliberate tampering?
54. Define RPO and RTO. Give both for nightly `pg_dump` and for WAL archiving with point-in-time recovery.
55. Why is a `pg_dump` consistent even while writes continue?
56. After a restore, why must you move the identity sequences forward? What could go wrong if you don't?
57. Explain what PostgreSQL did after SIGKILL, line by line from its log. What does `invalid record length ... got 0` mean?
58. What do `klog`'s recovery and PostgreSQL's recovery have in common? What does PostgreSQL do that `klog` doesn't?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, query plans, logs. Keep your filled-in copy in your own repository.

### Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | Why does `Create` use `RETURNING` for the timestamps? | | |
| 1 | Why can't a value sent as a parameter change a query's meaning? | | |
| 1 | What does a contract test give you that two separate test files don't? | | |
| 2 | Why does a database limit its connections? | | |
| 2 | Using Little's law, how many connections does 300 queries a second of 5 ms each need? | | |
| 2 | In burst 1, why did the pool of 10 wait almost as often as the pool of 2? | | |
| 3 | What does each letter of ACID promise, and which did the "Break it" violate? | | |
| 3 | Draw the lost-update timeline, and say how each of the three fixes changes it | | |
| 3 | Why is Switchyard's `Update` safe under `READ COMMITTED`? | | |
| 4 | Why can't you fix the dual-write problem by publishing first? | | |
| 4 | Why is the outbox at least once, and why is that acceptable here? | | |
| 4 | What do `FOR UPDATE` and `SKIP LOCKED` each contribute? | | |
| 5 | Why is "check, then insert" a race, and how does `ON CONFLICT DO NOTHING` close it? | | |
| 5 | Why must a failed `Begin` refuse the request? | | |
| 5 | What went wrong when two instances migrated at once, and how does the advisory lock fix it? | | |
| 6 | What does a committed offset record, and what happens when a group member leaves? | | |
| 6 | Why key events by job ID? | | |
| 6 | Why does counting need an inbox when the job handlers didn't? | | |
| 6 | Name two things a log can do that a queue can't | | |
| 7 | Why does a write delete the cached copy instead of updating it? | | |
| 7 | Draw the race that still lets a stale value in, and say what bounds it | | |
| 7 | What is a stampede, and how does singleflight stop it? | | |
| 7 | Why must a cache fail open, and what makes it fail fast? | | |
| 8 | Why must background tasks be idempotent and resumable? | | |
| 8 | What does `pg_try_advisory_xact_lock` guarantee, what doesn't it, and what happens if its holder crashes? | | |
| 8 | Read your two query plans aloud: where did the time go, and why is the partial index small? | | |
| 8 | Why must `ABANDON_AFTER` be longer than a worker's whole retry cycle? | | |
| 9 | Which errors should open a database breaker, and which must not? | | |
| 9 | Why does the breaker sit under the cache? | | |
| 9 | Liveness vs readiness: what goes wrong if a database outage fails liveness? | | |
| 10 | Why does the feed commit only after `klog` confirms, and what does that guarantee? | | |
| 10 | When can an audit line be written twice, and how would you detect it? | | |
| 10 | What does CRC-32C protect against, and what doesn't it? | | |
| 11 | Define RPO and RTO; give each for nightly `pg_dump`s and for WAL archiving | | |
| 11 | Why is a `pg_dump` consistent while the API keeps writing? | | |
| 11 | After the restore, what did the audit log tell you, and why move the identity forward? | | |
| 11 | What does `invalid record length ... got 0` mean in the recovery log? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A job survives an API restart | | |
| A parameter can't inject SQL; pasted text can | | |
| The same contract passes against memory, PostgreSQL and the cache | | |
| An exhausted pool makes callers wait until their deadline | | |
| A lost update happens under `READ COMMITTED`, and each fix prevents it | | |
| A job and its event commit together, or not at all | | |
| Killing the API between commit and send loses no job | | |
| Two instances share one idempotency key | | |
| A projection rebuilt under a new group matches the original | | |
| The cache serves hits, survives Redis being stopped, and recovers | | |
| The reaper fails an orphaned job, with its reason in the history | | |
| The partial index turns a sequential scan into an index scan | | |
| A frozen database opens the breaker; `/ready` fails and `/health` doesn't | | |
| `klog` dies and the feed recovers with nothing lost | | |
| A restored backup, reconciled against the audit log | | |
| PostgreSQL recovers a committed row after SIGKILL | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the guide, and why:
- What is still unclear:
