# Phase 3: make local records durable and auditable

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: a type-along guide with the code inline, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

Phase 3 builds a PostgreSQL-backed jobs service and a separate Rust append-only log experiment. The database remains the service's authoritative state; the Rust log is a deliberately small way to observe file formats, checksums, synchronization, recovery, and compaction. It is not a production database.

## Learning sequence

| Step | What you learn and build | Evidence |
|---|---|---|
| 1. Model data | Tables, rows, columns, primary/foreign keys, constraints, SQL types, safe parameterized queries. | Schema can reject invalid state; hostile-looking input stays data. |
| 2. Make changes atomic | Transactions, commit, rollback, isolation, state transition plus outbox intent. | Failure between writes leaves neither half committed. |
| 3. Measure lookup | Indexes, selectivity, query plans, buffers and observed latency. | Before/after EXPLAIN evidence explains whether an index helps this query. |
| 4. Encode records | Rust ownership, bytes, version, length, sequence and CRC32C. | Round-trip tests and rejected malformed records. |
| 5. Cross the durability boundary | Process buffers, OS page cache, write, sync_data/fsync, PostgreSQL WAL. | Explain what a successful write/commit claims and what a controlled crash can test. |
| 6. Recover and compact | Incomplete tail, complete-record corruption, ordered replay, snapshot/compaction. | Restart recovers complete records and never silently skips a corrupt complete record. |
| 7. Back up and restore | Logical database backup, separate restore target, row/count comparison. | Restore evidence from an isolated test database. |

## Tools, concepts, and readings

Core tools are PostgreSQL, psql in the local database container, pgx for Go, goose for schema migrations, Rust/Cargo, CRC32C for accidental-corruption detection, and Linux `strace` for observing file writes and synchronization requests. Docker Compose runs only a local synthetic-data database. Query timing and plans use PostgreSQL's `EXPLAIN (ANALYZE, BUFFERS)` rather than a separate benchmark framework.

The chapter cues and questions are embedded in [TEACHING.md](TEACHING.md) at the transaction, file, recovery, compaction, and backup steps.

## Foundation gaps closed

SQL and relational modeling; parameterized queries; transaction boundaries and isolation; indexes and query plans; file descriptors, page cache, synchronization, WAL, and crash consistency; binary parsing and Rust errors; backup/restore; integrity versus tamper resistance.

## Exit evidence

Recreate the schema from migrations, create and transition a job, prove the outbox intent shares the state transaction, measure a query before and after an index decision, recover a valid log after a partial tail, reject a corrupt complete record, and restore a database backup to a second database. Explain what each result does and does not guarantee.

The full walk-through and questions are in [TEACHING.md](TEACHING.md) and [learned.md](learned.md).
