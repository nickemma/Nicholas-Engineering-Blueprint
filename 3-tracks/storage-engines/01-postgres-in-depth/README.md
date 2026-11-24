# 01 Postgres in depth

> Storage engines track · Time 3 weeks at 12–15 hours a week · Builds on [Core 03 Docker and Postgres](../../../2-core/03-docker-and-postgres/README.md) · Status ready

Build a small set of PostgreSQL experiments around two workers sharing a job table. Reproduce transaction anomalies, compare query plans on the same rows, and let workers claim separate jobs without waiting on each other's row locks. Then predict what data survives a crash, a logical restore, and a recovery to a named point in the WAL.

Start with [Before you start](lessons/00-before-you-start.md). The live gate provisions a disposable PostgreSQL 17 container.

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|
| 1 | 01 | [Reproduce isolation anomalies](lessons/01-reproduce-isolation-anomalies.md) | Schedule lost updates and write skew, then check atomic updates and a Serializable retry. |
| 1 | 02 | [Read the plan before adding an index](lessons/02-read-the-plan-before-adding-an-index.md) | Compare actual plan nodes, shared buffer accesses, and ordered result IDs. |
| 1 | 03 | [Compare B-tree and LSM paths](lessons/03-compare-btree-and-lsm-paths.md) | Trace page-order and sorted-run reads, including version resolution and compaction. |
| 2 | 04 | [Claim and recover background jobs](lessons/04-claim-and-recover-background-jobs.md) | Claim with `SKIP LOCKED`, reclaim expired leases in batches, and fence completion. |
| 2 | 05 | [Crash the server and restore a dump](lessons/05-crash-the-server-and-restore-a-dump.md) | Kill the server during an open transaction and restore a selected-table snapshot in a fresh database. |
| 3 | 06 | [Recover to a named point](lessons/06-recover-to-a-named-point.md) | Use a physical base backup and archived WAL to recover the pre-delete row. |
| 3 | 07 | [Run the isolation and recovery gate](lessons/07-run-the-isolation-and-recovery-gate.md) | Rebuild the experiments and prove the queue test catches a blocking claimant. |

This module adapts the transaction, background-job, and recovery work from [Durable, auditable data](../../../2-core/03-docker-and-postgres/README.md).

## The gate

The [gate](gate/README.md) exercises real PostgreSQL transactions and verifies results before and after indexing. It checks two independent worker claims, a reclaimed lease, and rejection of a stale completion. In a separate database, removing `SKIP LOCKED` must cause the second claimant to time out. The recovery drills check exact row sets for restart, logical restore, and point-in-time recovery.

The plan measurements describe one selective query over a fixed fixture. The backup and WAL copies share a lab host. Recovery time samples illustrate the procedure under those conditions.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Read a query plan and reproduce a stale read followed by a lost update. |
| Intermediate | Choose an isolation level or atomic statement, then show two workers make progress under a held lock. |
| Senior | Predict what survives each recovery path and use evidence from the source, backup, and target to explain the outcome. |

## Practice

- [Exercises](exercises.md). Protect a reservation system and recover a known version.
- [Self-check](self-check.md). Draw the schedules and recovery timeline from memory.
- [Evidence](evidence/README.md). Inspect the captured plans, negative control, and recovery results.

Continue to [Consensus in depth](../02-consensus-in-depth/README.md).
