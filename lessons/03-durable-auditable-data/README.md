# Phase 3: make data durable

**Question:** how do you keep data correct when it must survive crashes, be shared by many requests, processes and instances, and be read far more often than it's written?

**Time:** about 7 weeks. **Prerequisites:** [Phase 2](../02-connected-services/README.md) and the [Rust Bridge](../rust-bridge/README.md); Docker installed.

## Syllabus

| Step | Topic | You'll learn |
|---|---|---|
| 1 | PostgreSQL behind the same port | Tables, rows, keys and constraints; SQL; query parameters and SQL injection; migrations with goose; `embed`; contract tests run against two stores; schema-per-test isolation; timestamp precision |
| 2 | Connection pooling | Why connections are scarce (`max_connections`); acquire, release, max and min size; waiting and deadlines; sizing with Little's law; fail-fast pings; pool metrics |
| 3 | Transactions | ACID; `BEGIN`/`COMMIT`/`ROLLBACK`; unit of work; domain events and a history table; data migrations; isolation levels and snapshots; the lost update reproduced; three fixes (`REPEATABLE READ`, `FOR UPDATE`, atomic updates); SQLSTATE 40001 |
| 4 | The transactional outbox | The dual-write problem; outbox and relay; at-least-once delivery; polling vs `LISTEN/NOTIFY` vs change data capture; `FOR UPDATE SKIP LOCKED`; partial indexes; crash-between-commit-and-send experiment |
| 5 | Idempotency keys in PostgreSQL | Shared state across instances; check-then-act races; `INSERT ... ON CONFLICT DO NOTHING`; extracting a port; a contract for key stores; concurrent migrations and advisory locks |
| 6 | Kafka, an event stream | Topics, partitions, offsets, keys and ordering; consumer groups, cooperative rebalancing, lag and replay; queue vs log; read models and event sourcing; the inbox pattern; upserts |
| 7 | Redis, cache-aside | Cache-aside reads and writes; delete-on-write; the stale-set race and TTLs; negative caching; stampedes and singleflight; failing open through a breaker; versioned keys; the decorator pattern |
| 8 | Background jobs | Schedules with jitter; idempotent, resumable, batched tasks; panics in goroutines; advisory locks as small distributed locks; an abandoned-job reaper; B-tree and partial indexes; `EXPLAIN ANALYZE`; `CREATE INDEX CONCURRENTLY`; `VACUUM` |
| 9 | A breaker around the database | What counts as a failure; domain errors vs adapter errors; `503` and `Retry-After`; graceful degradation; liveness vs readiness |
| 10 | The audit log, in Rust | Append-only and tamper-evident records; child processes and pipes; acknowledge before progress; detecting duplicates; what checksums do and don't protect; helper-process tests |
| 11 | Backup, restore and crash recovery | RPO and RTO; logical vs physical backups; point-in-time recovery; the write-ahead log, `fsync` and checkpoints; reconciling a restore against the audit log; moving identities past published IDs |

## What you'll be able to do

- Put a service's state in PostgreSQL behind an interface, with migrations, constraints and contract tests.
- Size and observe a connection pool, and explain what happens when it runs out.
- Group writes into transactions, choose an isolation level, and prove an anomaly exists before fixing it.
- Send messages reliably from a database-backed service with a transactional outbox.
- Share idempotency keys across instances without races.
- Stream events through Kafka, build and rebuild a read model, and deduplicate with an inbox.
- Cache reads safely, protect the database from stampedes, and keep working when the cache is down.
- Run maintenance safely across many instances, and use query plans to make it fast.
- Fail fast when the database is in trouble, and tell a load balancer the truth.
- Keep a tamper-evident audit trail in a separate program, and restore from a backup with a plan.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md), typing every piece of code yourself, starting from your Phase 2 code.
2. Do the experiments for real:
   - kill the API between commit and send;
   - replay a projection;
   - pull Redis out from under the cache;
   - freeze the database;
   - restore a backup and reconcile it.
3. Answer [learned.md](learned.md).
4. Build the exercise project, **[ledger](exercises.md)**, a money-transfer service, on your own. The exercise page shows exactly what finished looks like.
5. Take the [self-test](../../notes/learned/03-durable-auditable-data.md).

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where | Evidence |
|---|---|---|
| SQL, indexes, query plans (row 15) | Steps 1, 8 | Migrations; the before-and-after `EXPLAIN ANALYZE` |
| Transactions, isolation, connection pools (row 16) | Steps 2, 3 | The pool-exhaustion test; the lost-update learning tests |
| Files, `fsync`, crash consistency (row 17) | Steps 10, 11 | `klog ingest`; PostgreSQL's WAL recovery after SIGKILL |
| Caching (row 18) | Step 7 | Hit, miss and skip counts; the stampede test |
| Backup and restore (row 19) | Step 11 | The restore drill and its reconciliation |
| Messaging and event-driven design (row 12) | Steps 4, 6 | The outbox crash experiment; replaying a projection |
| Serialization and schema evolution (row 13) | Steps 1, 3, 6 | Versioned migrations, a data migration, a new message type |
| Testing (row 5) | Steps 1, 5, 7 | Contract tests passed by three repositories and two key stores |
| API security, injection (row 30) | Step 1 | The SQL injection experiment |

## Patterns introduced

These link to the [patterns ledger](../../JOURNEY.md#6-patterns-ledger):
- repository (paying off: three implementations, one port);
- contract tests;
- unit of work;
- aggregate and domain events;
- transactional outbox;
- inbox (idempotent consumer);
- event sourcing and read models (projections);
- cache-aside;
- singleflight (request coalescing);
- decorator (cache and breaker as repositories);
- competing background workers with `SKIP LOCKED`;
- advisory locks for singleton tasks;
- interface segregation (`AbandonedFinder`);
- liveness and readiness probes.

## Next

One PostgreSQL server now keeps everything safe, as long as that one server survives. If its disk dies, you restore from the last backup and lose everything since. If it gets too busy, there's no second one to share the load. [Phase 4](../04-replicated-state/README.md) makes copies, keeps them agreeing, and splits data that's too big for one machine.
