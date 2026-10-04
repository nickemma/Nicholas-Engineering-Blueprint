# Phase 2: connect sites and workers

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: a type-along guide with the code inline, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This page previews the concepts, tools, readings, and exit evidence. Follow the full [self-study teaching guide](TEACHING.md) and record your work in [learned.md](learned.md).

The complete read-at-the-right-time list is embedded at the end of [TEACHING.md](TEACHING.md). You can study the guide without looking up chapters in another document.

## Question and build

What changes when the API sends work to a different process across a network boundary?

Add a background worker and bounded queue to the jobs API. Begin with a Go channel to make queue behavior visible, then add RabbitMQ for one concrete work-queue exercise. Compare NATS JetStream and Kafka without building all three. Connect services first with HTTP and then with gRPC/Protocol Buffers where schema and service boundaries justify it.

## Teach in this order

1. **Separate responsibilities.** Draw API, queue, and worker as separate roles. Explain which process owns each piece of state and how a job moves between them.
2. **Send one request between processes.** Introduce client/server, address, port, request, response, and serialization. Observe one exchange with curl and then with packet tools.
3. **Learn the network path.** Explain sockets and TCP handshake/teardown before asking the learner to inspect packets. Contrast TCP and UDP; add DNS when services stop using fixed local addresses.
4. **Make worker behavior explicit.** Compare at-most-once and at-least-once delivery. Kill a worker while it handles work; observe a lost or duplicated job.
5. **Make retries safe.** Add exponential backoff with jitter and an idempotency key. Explain how a repeated request maps to one effective result.
6. **Control overload and trust.** Bound the queue, return a clear overload response such as 429, and authenticate service-to-service requests. Explain backpressure and the new trust boundary.
7. **Evolve the message.** Add a versioned message schema and then gRPC/Protocol Buffers. Demonstrate how a change remains readable by the other service.

## Foundations closed

- Networking: sockets, TCP behavior, UDP, ports, DNS, and packet inspection.
- Distributed-systems basics: RPC, message queues, delivery guarantees, retries, idempotency, backpressure.
- Service boundaries, schema evolution, and initial service authentication.
- Research practice begins: state one failure question and preserve a reproducible trace.

This phase does not teach consensus, durable job state, or exactly-once delivery as a transport guarantee. “Exactly once in effect” means the application makes retries idempotent.

## Reading placement

Read Kurose & Ross socket/transport sections and CSAPP Chapter 11 before the worker uses network sockets. Read reliable data transfer/TCP after observing a lost connection. Use *Understanding Distributed Systems* on links, discovery, APIs, and resiliency beside the queue/retry work. Read DDIA encoding/evolution and message-broker sections when adding gRPC/queues; MapReduce when re-execution after worker failure is concrete. Add backpressure and protocol readings at those build steps.

## Exit evidence and career signal

Kill and restart the worker mid-job. Show a retry, a duplicate delivery, and one effective completion; explain which component made the retry safe. Capture a packet or request trace.

This establishes distributed-systems fundamentals around communication and delivery, not consensus or durable storage.
