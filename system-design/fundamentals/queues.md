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

## In an interview

Say queue or log and why, the delivery guarantee and how duplicates are handled, the bound and what happens when it's hit, and where failed messages go.

## Where you built it

- [Phase 2](../../lessons/02-connected-services/README.md):
  - a bounded worker pool with Little's law;
  - RabbitMQ;
  - at-least-once delivery with idempotency;
  - retries with jitter, and dead letters.
- [Phase 3](../../lessons/03-durable-auditable-data/README.md): the transactional outbox, and Kafka next to RabbitMQ.
- [Phase 7](../../lessons/07-utility-evaluation/TEACHING.md#step-9-using-the-predictions): priority lanes, against head-of-line blocking.
