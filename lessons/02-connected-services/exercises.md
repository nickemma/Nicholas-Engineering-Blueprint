# Phase 2 exercise: hookshot, a webhook delivery service

Build this **on your own**, in a new repository, after the [checkpoint](TEACHING.md#checkpoint). It's a different system, but it needs every Phase 2 idea:
- separate processes connected by a broker;
- at-least-once delivery;
- idempotency on both sides;
- retries with jitter;
- a circuit breaker per destination;
- dead letters;
- backpressure.

There's no solution in this repository. This page shows exactly what the finished system does.

## What you're building

Services often need to tell *other companies' servers* that something happened: "payment received", "order shipped". They do it with **webhooks**: an HTTP `POST` to a URL the receiver registered. Delivering webhooks reliably is hard. Receivers are slow, down, or flaky; the same event must not be applied twice; and one broken receiver must not slow down everyone else's deliveries.

`hookshot` has two processes:

- **`hookshot-api`** stores subscriptions and accepts events. For each event, it publishes one `DeliverWebhook` command per matching subscription to RabbitMQ.
- **`hookshot-worker`** consumes those commands and POSTs each event to its subscriber's URL, retrying failures, protecting struggling receivers with a breaker, and reporting outcomes back as events.

## The finished result

### HTTP contract (hookshot-api)

| Request | Success | Errors |
|---|---|---|
| `POST /subscriptions` `{"url":"https://...","event_types":["order.shipped"]}` | `201`, with the subscription including a generated `id` and `secret` | `400` invalid URL or empty `event_types` |
| `GET /subscriptions/{id}` | `200` | `404` |
| `POST /events` `{"type":"order.shipped","data":{...}}`, with optional `Idempotency-Key` | `202`, `{"id":"evt_...","deliveries":N}`, where N is the number of matching subscriptions | `400`; `422` key reused with a different body; `503` + `Retry-After` when the broker refuses or the dispatch breaker is open |
| `GET /events/{id}/deliveries` | `200`, a list of `{"subscription_id","state","attempts","last_status","last_error"}` | `404` |

Delivery states move `pending → delivering → delivered`, or `→ failed` after the last attempt.

### What a delivery looks like to the receiver

~~~text
POST /hooks HTTP/1.1
Content-Type: application/json
Webhook-Id: dlv_8KQ2...          (the same value on every retry of this delivery)
Webhook-Attempt: 2
Webhook-Signature: sha256=5d41402abc4b2a76b9719d911017c592...

{"id":"evt_...","type":"order.shipped","data":{"order":1042}}
~~~

- `Webhook-Id` is the **idempotency key for the receiver**: it's identical on every retry, so a receiver can drop duplicates.
- `Webhook-Signature` is the HMAC-SHA256 of the body using the subscription's `secret`, so the receiver can check the request really came from hookshot (look up `crypto/hmac`).

### Rules

- Any 2xx response means delivered. A 4xx other than 408 or 429 is **permanent**: don't retry. Timeouts, connection errors, 408, 429 and 5xx are **transient**.
- Retry transient failures with exponential backoff and **full jitter**: base 1 s, cap 1 min, at most 6 attempts, all inside a 10-minute delivery deadline. A `Retry-After` header on a 429 or 503 is honoured if it's shorter than the cap.
- Each attempt has a 5-second HTTP timeout.
- **One circuit breaker per receiver host.** After 5 failures in a row the breaker opens for 30 s, and deliveries to that host wait (they're requeued with a delay) rather than hammering it. Other hosts are unaffected.
- A command that can't be decoded goes straight to the dead-letter queue.
- `POST /events` with the same `Idempotency-Key` and body creates the deliveries **once** and replays the original `202`.
- Messages are versioned envelopes. `DeliverWebhook` is version 1; document how you'd add a field.
- Both processes shut down gracefully on SIGTERM. A worker killed mid-delivery leaves the command unacknowledged, so it's redelivered and the receiver sees the **same** `Webhook-Id` again.

### Structure

~~~text
cmd/hookshot-api/      HTTP API: subscriptions, events, delivery status
cmd/hookshot-worker/   consumers that deliver webhooks
cmd/receiver/          a test receiver: logs requests and can be told to fail
internal/subscriptions/ domain: Subscription, matching, validation
internal/delivery/      domain: Delivery state machine, transient vs permanent
internal/messages/      envelopes and versioned message types
internal/rabbit/        RabbitMQ adapter (reuse your Phase 2 design)
internal/retry/         backoff with full jitter
internal/breaker/       a breaker per host
internal/signing/       HMAC signatures
~~~

## Sample session

Start RabbitMQ, the API, two workers, and a test receiver that fails its first two requests:

~~~text
$ receiver --listen 127.0.0.1:9999 --fail-first 2 &
$ curl -s -X POST localhost:8080/subscriptions -H 'Content-Type: application/json' \
    -d '{"url":"http://127.0.0.1:9999/hooks","event_types":["order.shipped"]}'
{"id":"sub_1","url":"http://127.0.0.1:9999/hooks","event_types":["order.shipped"],"secret":"whsec_..."}

$ curl -s -X POST localhost:8080/events -H 'Content-Type: application/json' -H 'Idempotency-Key: ship-1042' \
    -d '{"type":"order.shipped","data":{"order":1042}}'
{"id":"evt_1","deliveries":1}

$ curl -s -X POST localhost:8080/events -H 'Content-Type: application/json' -H 'Idempotency-Key: ship-1042' \
    -d '{"type":"order.shipped","data":{"order":1042}}'
{"id":"evt_1","deliveries":1}            (replayed; Idempotent-Replayed: true)

$ sleep 5; curl -s localhost:8080/events/evt_1/deliveries
[{"subscription_id":"sub_1","state":"delivered","attempts":3,"last_status":200,"last_error":""}]
~~~

The receiver's log shows three requests with the **same** `Webhook-Id` and `Webhook-Attempt` 1, 2, 3. The first two got 500; the third got 200.

Then stop the receiver entirely and send ten events. The worker's log shows the breaker for `127.0.0.1:9999` opening after 5 failures. While it's open, no requests reach that host, and deliveries to any other subscribed receiver carry on at full speed.

The IDs, secrets and timings will differ; the states, attempt counts and status codes must match.

## Acceptance checks

You're done when all of these are true:

1. Every row of the HTTP contract has a test.
2. Unit tests cover the delivery state machine, transient-vs-permanent classification (a table over status codes), backoff ceilings (deterministic, with an injected random source) and the per-host breaker (with a fake clock).
3. A signing test: a receiver can verify `Webhook-Signature` with the secret, and a changed body fails verification.
4. Integration tests against real RabbitMQ (skipped without `RUNWAY_AMQP_URL`) show redelivery after a consumer stops, and dead-lettering of an unreadable command.
5. **The kill test:** kill a worker with SIGKILL mid-delivery to a slow receiver. The receiver sees the same `Webhook-Id` twice, and the delivery ends `delivered`, once.
6. **The isolation test:** with one receiver down and another healthy, the healthy receiver's p95 delivery latency is within 20% of its latency when both are healthy. Measure it with your Python tools.
7. The idempotent `POST /events` test: two identical requests with one key create one set of deliveries.
8. `go vet`, `go test -race ./...` and CI are green.

## Stretch goals

- A **delayed retry** using a RabbitMQ queue with a per-message TTL that dead-letters back into the main queue, instead of sleeping in the worker.
- Rate-limit deliveries per receiver (token bucket), so a burst of events doesn't overwhelm a small receiver.
- A `POST /deliveries/{id}/retry` endpoint that replays a failed delivery from the dead-letter queue.

## Hints

- Classify errors first, as a pure function with a table test. Everything else depends on getting that right.
- The breaker map needs its own mutex. Think about when a host's breaker is created.
- In-memory delivery state is acceptable for this exercise; Phase 3 shows how to make it durable. Say so in your README, along with what's lost on restart.
- Revisit step 4's table of "three defences", and fill it in for hookshot before you write any code.
