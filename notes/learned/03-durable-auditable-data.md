# Phase 3 self-test

Answer from memory, then check yourself against [the lesson](../../lessons/03-durable-auditable-data/TEACHING.md). Write each "predict" answer before running anything.

## A. PostgreSQL behind a port

1. What's a primary key, an identity column, a `CHECK` constraint and a foreign key? Give one example of each from Runway's schema.
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
30. Why does the projector need an inbox when Runway's job handlers didn't? Why must the inbox insert be in the same transaction as the count?
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
