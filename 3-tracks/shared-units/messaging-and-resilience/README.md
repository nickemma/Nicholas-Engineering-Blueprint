# Messaging and resilience

> Shared unit · Time: 2 weeks at 12–15 hours a week · Builds on [Core 01 Go runtime and reliable services](../../../2-core/01-go-runtime-and-reliable-services/README.md) and [Core 03 Docker and Postgres](../../../2-core/03-docker-and-postgres/README.md) · Used by the cloud and network track · Status: ready

Build a RabbitMQ producer and a separate worker that records a Switchyard job in PostgreSQL and publishes a completion event. Evolve the command schema while preserving the identity of its effect. Then kill the worker between commit and acknowledgment, replace it, and follow the redelivery through the broker and database.

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Commands, events, and versions](lessons/01-commands-events-and-versions.md) | Decode two versions of a command into one internal representation. |
| 1 | 02 | [Publish through RabbitMQ](lessons/02-publish-through-rabbitmq.md) | Declare durable queues and confirm that the broker accepted a routed message. |
| 1 | 03 | [Commit before acknowledging](lessons/03-commit-before-acknowledging.md) | Use a PostgreSQL transaction and a stable identity to make the job effect idempotent. |
| 2 | 04 | [Bound retries and route dead letters](lessons/04-bound-retries-and-route-dead-letters.md) | Send permanent failures to a dead-letter queue and let the broker count repeated temporary failures. |
| 2 | 05 | [Stop calling a failing dependency](lessons/05-stop-calling-a-failing-dependency.md) | Verify independent circuit breakers for the database and event publisher with a controlled clock. |
| 2 | 06 | [Run the crash and redelivery gate](lessons/06-run-the-crash-and-redelivery-gate.md) | Restart a worker after a real process exit and catch a build that acknowledges too early. |

## The gate

Run the [live lab](gate/README.md) with a disposable RabbitMQ node and PostgreSQL database. The replacement worker must receive the same command, leave one durable job effect, and publish its completion. The broker must dead-letter incompatible and conflicting commands and exhaust the retry budget for a repeated dependency failure. The negative control must lose the redelivery when it acknowledges before committing.

The single-node lab exercises worker failure and duplicate delivery. PostgreSQL and RabbitMQ commit independently, so consumers can still see multiple copies of a completion event. The [Event streams unit](../event-streams/README.md) covers the transactional outbox and inbox.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Send a command, inspect its completion, and explain what each acknowledgment records. |
| Intermediate | Preserve one durable effect across duplicate deliveries and classify failures for retry or dead-lettering. |
| Senior | Use crash evidence to explain which boundaries allow duplicate commands or events and which failure modes a circuit breaker can mitigate. |

## Practice

- [Exercises](exercises.md). Inspect command and event identities and diagnose a failed delivery.
- [Self-check](self-check.md). Explain the boundaries of the acknowledgments, retries, and circuit breakers.
- [Evidence](evidence/README.md). Inspect the gate and clean replay captures.
