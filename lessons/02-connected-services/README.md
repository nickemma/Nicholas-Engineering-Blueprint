# Phase 2: connect services

**Question:** what changes when work crosses a process boundary, and how do you keep it correct when messages are lost, duplicated, delayed or poisoned?

**Time:** about 4 weeks. **Prerequisites:** [Phase 1](../01-reliable-service/README.md) and the [Python Bridge](../python-bridge/README.md); Docker installed.

## Syllabus

| Step | Topic | You'll learn |
|---|---|---|
| 1 | Accept now, run later | Sync vs async, producer/consumer, worker pools, bounded queues, backpressure (503 + `Retry-After`), Little's law, Go's random `select`, two-context shutdown, gauges |
| 2 | Messages and a bus | Commands vs events, event-driven architecture, bounded contexts, envelopes, at-least/at-most/exactly-once, the tolerant reader, dead letters, competing consumers, idempotent receivers |
| 3 | RabbitMQ and two processes | AMQP connections and channels, durable quorum queues, persistent messages, publisher confirms, ack/nack, prefetch, delivery limits, dead-letter exchanges, integration tests, crash-only design, killing a worker mid-job |
| 4 | Idempotency end to end | Idempotency keys (replay, 409, 422), fingerprints with SHA-256, background jobs, the three sources of duplicates and their defences |
| 5 | Retries, versioning, breakers | Transient vs permanent failures, backoff with full jitter, retry budgets, message versioning and upcasting, reader-first deploys, chaos injection, circuit breakers, heartbeats |
| 6 | gRPC | Protocol Buffers, field numbers and compatibility, code generation, status codes, deadlines on calls, bufconn tests, reflection |
| 7 | Look at the wire (run locally) | Sockets, ephemeral ports, the TCP handshake, keep-alive, multiplexing, `ss` and `tcpdump`, testing a hypothesis with packets |

## What you'll be able to do

- Split accepting work from doing it, and push back under overload with numbers to justify the limits.
- Design messages as versioned contracts, and connect services only through them.
- Run a real broker and explain exactly what makes a message durable and when it's delivered again.
- Make a system correct "in effect" despite at-least-once delivery, with three named defences.
- Retry safely, fail fast with a circuit breaker, and quarantine poison messages.
- Offer the same use cases over HTTP/JSON and gRPC/protobuf, and choose between them.
- Read TCP traffic and connect it to everything above.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md), typing every piece of code yourself, starting from your Phase 1 code.
2. Do the experiments for real: kill a worker mid-job, poison a queue, freeze the broker.
3. Answer [learned.md](learned.md).
4. Build the exercise project, **[hookshot](exercises.md)**, a webhook delivery service, on your own. The exercise page shows exactly what finished looks like.
5. Take the [self-test](../../notes/learned/02-connected-services.md).

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where | Evidence |
|---|---|---|
| Messaging and event-driven design (row 12) | Steps 2–5 | The kill-a-worker experiment; dead-letter and breaker runs |
| Serialization and schema evolution (row 13) | Steps 2, 5, 6 | `RunJob` v1→v2 upcasting tests; the protobuf field-number break |
| Sockets, TCP, ports (row 11) | Step 7 | Your `ss` and `tcpdump` captures |
| Testing (row 5) | Step 3 | Integration tests against a real broker that found two wrong assumptions |
| Authentication, first boundary (row 26) | Step 3 | Broker credentials in configuration (properly secured in Phase 6) |

## Patterns introduced

These link to the [patterns ledger](../../JOURNEY.md#6-patterns-ledger):
- worker pool;
- work queue;
- bulkhead and backpressure;
- event-driven architecture (commands vs events);
- event envelope and schema versioning;
- tolerant reader;
- bounded context (strategic DDD);
- idempotency key;
- idempotent receiver;
- retry with backoff and jitter;
- dead-letter queue;
- circuit breaker;
- factory;
- crash-only design.

## Next

The broker's queues now survive restarts, but the API's job records still live in memory, and the dual-write gap between "store the job" and "publish the command" is still open. The [Rust Bridge](../rust-bridge/README.md) teaches bytes, memory and files. [Phase 3](../03-durable-auditable-data/README.md) then makes the records durable and closes the gap with a transactional outbox.
