# Postgres in depth · Evidence

The reference used Go 1.26.6, PostgreSQL 17.11, and the `postgres:17` image. Each run created its own container and test schema.

| Check | Observed result |
|---|---|
| Same-row updates | Stale Read Committed writes left 1. Atomic updates left 2. Repeatable Read refused the stale write with 40001. |
| Cross-row invariant | Repeatable Read left 0 active operators. Serializable and a fresh retry kept 1. |
| Ordered ready-job listing | Sequential scan changed to index-only scan. Shared buffer accesses dropped from 910 to 17 and the ordered 16 IDs stayed the same. |
| Background job queue | The second worker skipped the held row. A reaped lease got a new attempt token and a stale or repeated completion added no effect. |
| Locking negative control | Removing `SKIP LOCKED` yielded SQLSTATE 55P03 at the second claim. |
| Recovery | SIGKILL preserved the acknowledged row. The logical dump restored the snapshot. PITR restored the pre-delete marker and excluded the later write. |

- [Plan before indexing](plan-before.json) · [Plan after indexing](plan-after.json)
- [Live gate and recovery timings](gate.txt) · [Clean lesson replay](replay.txt)

The plans count cache hits and physical reads together as shared buffer accesses. The recovery timings cover the named steps in one local run.
