# Queues and logs

A queue lets a producer hand work to a consumer without waiting for it. That absorbs bursts, lets each side scale and fail on its own, and turns "do it now" into "do it soon, reliably".

## Queue or log?

| | **Queue** (RabbitMQ, SQS) | **Log** (Kafka, Kinesis, Pulsar) |
|---|---|---|
| A message after it's processed | Deleted | Kept for a retention period |
| Many consumers | Compete for messages | Each group reads everything, at its own offset |
| Ordering | Mostly per queue, weakened by retries | Strict per partition |
| Replay | No | Yes: rewind the offset |
| Good for | Commands, tasks, work distribution | Events, pipelines, rebuilding state, many readers |

## Publish/subscribe and work queues

In a work queue, competing workers share the work for one subscriber. In pub/sub, independent subscribers each receive their own logical copy. A job-completed event can feed a dashboard and an audit projector with independent progress, and each subscriber can have several workers sharing its deliveries. Choose an ordering key, retention and replay behavior, and describe how a slow subscriber catches up. [Event streams lab](../../3-tracks/shared-units/event-streams/README.md)

## Delivery guarantees

- **At most once:** acknowledge before processing. A crash loses the message.
- **At least once:** acknowledge after processing. A crash causes a redelivery, so **duplicates happen**, and consumers must be idempotent ([Idempotency](idempotency.md)).
- **Exactly once** end to end isn't a delivery property. It's at-least-once delivery plus idempotent or transactional processing.

## Numbers to know

- **Little's law:** items in the system = arrival rate × time in the system. At 100 jobs a second taking 2 s each, 200 are in flight, so size workers and limits for that.
- A broker adds a few milliseconds of latency. Fine for work, not for a synchronous user request path.

## How it fails

- **Unbounded queues** hide overload until memory runs out. Bound them, and reject or shed when full (backpressure).
- **Poison messages** fail forever and block the queue. After N attempts, move them to a **dead-letter queue**.
- **The dual write:** "save to the database, then publish" loses the event if the process dies in between. Use the **transactional outbox**.
- **Consumer lag** grows quietly. Alert on queue depth or lag, not just errors.
- **Head-of-line blocking:** one slow message type delays everything behind it. Separate queues or lanes.

## Retries, backlog and circuit breakers

Retry transient failures with bounded attempts, a deadline and jitter. Use a stable idempotency key if the first attempt may have changed state. Track queue age as well as depth and bound the backlog. With 1,200 queued jobs, 80 completions/s, and continuing arrivals of 50 jobs/s, expect about 40 seconds to drain under steady rates. If arrivals equal or exceed completions, the backlog will persist or grow.

A circuit breaker limits repeated calls to a dependency that is failing. After the threshold, fail fast. After a cooldown, admit limited probes and use their results to decide whether to resume. Pair it with timeouts and a retry budget so an open dependency breaker does not create an unbounded queue elsewhere. [Retry and dead-letter lab](../../3-tracks/shared-units/messaging-and-resilience/lessons/04-bound-retries-and-route-dead-letters.md) · [Circuit breaker lab](../../3-tracks/shared-units/messaging-and-resilience/lessons/05-stop-calling-a-failing-dependency.md)

## In an interview

Say queue or log and why, the delivery guarantee and how duplicates are handled, the bound and what happens when it's hit, and where failed messages go.

## Where you built it

- [Core 01](../../2-core/01-go-runtime-and-reliable-services/lessons/13-worker-pools-and-backpressure.md): a bounded queue, checked with Little's law.
- [Messaging and resilience](../../3-tracks/shared-units/messaging-and-resilience/README.md):
  - RabbitMQ;
  - at-least-once delivery with idempotency;
  - retries with jitter, and dead letters.
- [Event streams](../../3-tracks/shared-units/event-streams/README.md): the transactional outbox, and Kafka next to RabbitMQ.
- [ML for infrastructure, lesson 07](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/lessons/07-test-scheduling-utility-and-input-drift.md): ordering ready jobs by predicted size, against FIFO's head-of-line blocking.
