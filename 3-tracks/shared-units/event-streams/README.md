# Event streams

> Shared unit · Time: 2 weeks at 12–15 hours a week · Builds on [Core 03 Docker and Postgres](../../../2-core/03-docker-and-postgres/README.md) and [Messaging and resilience](../messaging-and-resilience/README.md) · Used by the storage engines track · Status: ready

Build a Switchyard job history and a count of each job's events. Write each event in the same PostgreSQL transaction as the history change. Relay it to Kafka, then build the count in a separate projector. Use a transactional inbox to make the count safe to rebuild or resume after a crash.

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Name the event and its partition key](lessons/01-name-the-event-and-its-key.md) | Validate the versioned record, use a job key for partitioning, and distinguish event identity from log position. |
| 1 | 02 | [Commit the event with the write](lessons/02-commit-the-event-with-the-write.md) | Save history and publication intent in one PostgreSQL transaction. |
| 1 | 03 | [Relay and resend after a crash](lessons/03-relay-and-resend.md) | Publish pending outbox rows, observe partition offsets, and recover an interrupted sent marker. |
| 2 | 04 | [Apply the event, then commit its offset](lessons/04-apply-then-commit-the-offset.md) | Make the inbox claim and count increment atomic, then advance the Kafka group. |
| 2 | 05 | [Rebuild the read model from the log](lessons/05-rebuild-the-read-model.md) | Start a fresh consumer group and projection at the beginning of retained history. |
| 2 | 06 | [Verify the two crash boundaries](lessons/06-verify-the-two-crash-boundaries.md) | Compare the original and rebuilt counts and catch a variant that counts duplicate events. |

The unit reworks the outbox and Kafka steps from [Durable, auditable data](../../../2-core/03-docker-and-postgres/README.md) as a self-contained lab.

## The gate

Run the [gate](gate/README.md) against real PostgreSQL and a disposable Kafka broker. Force the writer to roll back. Crash the relay after Kafka accepts an event and the projector after the inbox transaction commits. The reference must leave two Kafka offsets for a single republished event and count that event once in each projection. The negative control must produce an inflated count.

The lab uses a single relay and a single broker with one replica per partition. Kafka delivery can repeat. The PostgreSQL transaction makes repeated deliveries safe for this particular read model.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Read a Kafka position and explain how it differs from an event ID. |
| Intermediate | Implement a transactional outbox and inbox and trace the recovery on both sides. |
| Senior | Use a run's offsets, publication state, and row counts to identify which crash window a system encountered. Explain the conditions needed to rebuild a real projection. |

## Practice

- [Exercises](exercises.md). Build an inventory read model and prove it handles duplicate events.
- [Self-check](self-check.md). Reason about each commit boundary from memory.
- [Evidence](evidence/README.md). Inspect the crash, rebuild, and negative-control runs.
