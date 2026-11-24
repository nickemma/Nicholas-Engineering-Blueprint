# 03 Docker and Postgres

> The core · Time: 3 weeks at 12–15 hours a week · Builds on: [Core 01](../01-go-runtime-and-reliable-services/README.md) and [Core 02](../02-python-runtime-and-honest-measurement/README.md) · Status: ready

## What you'll learn

How Docker gives a process its own filesystem and network, and where data lives when the container goes away. How PostgreSQL enforces constraints, chooses when to use an index, and commits related changes together. How to keep database waits within a deadline and prove what survives a crash.

## What you'll build

Continue Switchyard from [Core 01's reconciliation loop](../01-go-runtime-and-reliable-services/lessons/16-the-reconciliation-loop.md). Keep the memory repository and add a PostgreSQL adapter behind the same `jobs.Repository` port. By the end, Compose runs the Go control plane, worker processes, and PostgreSQL on a shared network, with database files in a named volume. Use Core 02's `kload` to compare job submissions across the two backends.

## Lessons

| # | Lesson | What you'll build and check | Time |
|---|---|---|---|
| 01 | [What disappears on restart](lessons/01-what-disappears-on-restart.md) | Submit a job to Core 01, restart the control plane, and look for the job again. Run PostgreSQL in a container, connect with `psql`, and compare the writable container layer with a named volume by replacing the container. | ~4 h |
| 02 | [A schema you can change](lessons/02-a-schema-you-can-change.md) | Write and apply versioned migrations to an empty database and to one with existing jobs. Use constraints to enforce valid rows and parameterized queries to prevent SQL injection. Add an index for the pending-job lookup and inspect the plan on a seeded table. | ~5 h |
| 03 | [One contract for two repositories](lessons/03-one-contract-for-two-repositories.md) | Run shared create, read, and conditional-update tests against memory and PostgreSQL. Implement the existing expected-state compare-and-swap with a conditional update, and check the losing writer's result against real Postgres. | ~5 h |
| 04 | [A connection pool has a limit](lessons/04-a-connection-pool-has-a-limit.md) | Add a bounded pool and acquire deadlines. Hold every connection, observe a request time out, release the connections, and verify the next request succeeds. Use pool metrics and a load run to explain the size you choose. | ~4 h |
| 05 | [Complete a job in one transaction](lessons/05-complete-a-job-in-one-transaction.md) | Record completion and its database effect together. Force an error between the writes and check that both roll back. Use a unique constraint to enforce one recorded effect per job, and test completion racing with cancellation. | ~5 h |
| 06 | [A retried submission survives a restart](lessons/06-a-retried-submission-survives-a-restart.md) | Store the idempotency key, request fingerprint, and original result with the job in one transaction. Race submissions using the same key, restart the API, then verify that the original request gets the same result and a different payload gets a conflict. | ~5 h |
| 07 | [Pick up unfinished jobs after a crash](lessons/07-pick-up-unfinished-jobs-after-a-crash.md) | Recover queued and interrupted jobs from PostgreSQL with one active control plane. Keep the outstanding-work limit and make old lease tokens invalid after recovery. Kill the control plane with a job running and watch a worker pick it up again. | ~6 h |
| 08 | [Run the stack and measure it](lessons/08-run-the-stack-and-measure-it.md) | Build the Switchyard image and wire up the control plane, workers, and Postgres with Compose. Recreate the database container with its volume attached. Compare job submissions under the same offered load with `kload`, accounting for send lag, errors, and variation across runs. | ~4 h |

This module adapts Phase 3’s repository, pooling, transactions, and idempotency lessons and Phase 5’s Compose lesson to Switchyard. Restart recovery and the matched `kload` comparison are new.

## Restart behavior

- A committed submission can be found by job ID after an API crash. A retry within the idempotency retention window returns the original result. A crash before commit leaves neither a job nor a claimed key.
- A single control plane recovers queued jobs and requeues interrupted jobs when it restarts. The replacement lease has a token that a worker holding the old lease cannot use to complete the job. Terminal jobs stay terminal.
- A worker may execute an interrupted job again. The completion transaction guarantees one **recorded database effect** for a completed job. Any side effect outside PostgreSQL needs its own retry contract.
- Recreating the Postgres container with the same named volume preserves committed data. The learner exercises recovery from a process crash and container replacement. Backup and restore are covered in [Postgres in depth](../../3-tracks/storage-engines/01-postgres-in-depth/README.md).

## The gate

The [gate](gate/README.md) starts an isolated stack and checks:

1. Both repositories pass the same contract. A stale update is refused and leaves the stored job unchanged.
2. With every connection held, a job request fails visibly within its configured deadline. Jobs can be read again after the pool is released.
3. A forced failure between the completion and effect writes leaves neither change committed. A successful completion records one effect.
4. After the control plane is killed and restarted, a repeated submission returns the same job, an interrupted job can finish under a replacement lease, and a stale completion is refused.
5. After replacing the Postgres container with its original volume, committed jobs, recorded effects, and idempotency results are still present.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Run the stack with Compose, apply a migration, and add a parameterized query covered by a repository contract test. |
| Intermediate | Diagnose pool exhaustion, reason about transaction boundaries, and make a retried submission return the same result across restarts. |
| Senior | Explain the crash windows in submission, leasing, and completion, and demonstrate which invariants survive each failure. |

## Practice

- **[Exercise](exercises.md).** Build a small reservation service with Compose and PostgreSQL. Concurrent attempts to reserve the last seat yield one winner. Retrying the winner's request after restart returns the original reservation.
- **[Self-check](self-check.md).** Explain a failed pool acquisition, a rolled-back completion, and a recovered lease using evidence from your runs. From memory, design a transaction and a restart test for a duplicate submission.

## Next

[04 Rust foundations](../04-rust-foundations/README.md) starts Switchyard's data plane with `klog`, a crash-safe log.

[Evidence from the lesson runs](evidence/README.md) is available for reproduction.
