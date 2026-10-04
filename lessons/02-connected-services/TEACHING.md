# Phase 2: Connect sites and workers

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: full code in `steps/`, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This is a self-study lesson. It takes the single-process service from Phase 1 and splits its work across an API process, a message broker, and a worker process. You will see what a network boundary changes before relying on a broker to hide it.

## The goal

Submit a job to an API, place a small versioned message on a queue, let a separate worker process it, and observe the result. Stop the worker at carefully chosen points. Explain why messages can be delivered again and how an idempotent operation makes that safe.

This phase teaches message delivery and networking basics. It does not teach consensus or promise exactly-once transport.

## Before you start

Complete Phase 1. You should have the jobs API contract, tests, basic context use, and an explanation of volatile process memory. You need Go, Bash, curl, Docker Engine with the Docker Compose plugin, and permission to capture local loopback packets if you choose the packet-inspection exercise.

~~~bash
go version
docker --version
docker compose version
curl --version
~~~

Each command checks one installed tool. If Docker Compose is missing, stop and install it before running the broker. Use only local synthetic messages.

Create a clean practice folder in this phase directory. Rebuild the Phase 1 service behavior from its API contract, then keep that service and this exercise separate from the reference lesson:

~~~bash
cd lessons/02-connected-services
mkdir -p practice
cd practice
go mod init kestrel-phase2
~~~

Use this file layout so each boundary has a clear home:

~~~text
compose.yaml
cmd/api/main.go
cmd/worker/main.go
internal/jobs/message.go
internal/jobs/idempotency.go
internal/queue/rabbitmq.go
internal/httpapi/handlers.go
internal/httpapi/handlers_test.go
~~~

cmd/api and cmd/worker are separate executable programs. internal contains code shared inside this Go module. Add the official AMQP client with go get github.com/rabbitmq/amqp091-go, then run go mod tidy and go test ./... after each working stage.

## 1. Name each process and the message path

Draw these as separate boxes before coding:

~~~text
curl → API process → broker queue → worker process → API result route
                       message
~~~

A process is one running program with its own memory. A queue is a place one process can leave a message for another. A message broker is a server process that accepts, stores, and delivers messages according to its configuration. The API's in-memory map and the worker's memory are different; one cannot directly read the other's variables.

Write down these questions and answer them from your diagram: which process creates the job ID? Which component holds a message while no worker is connected? Which component decides whether to retry? Which component can know a job is complete?

## 2. Observe a bounded queue before using a broker

In a small Go experiment, create a channel with capacity two. A channel is a typed communication path between goroutines. Send two values without a receiver; they fit. Attempt a third send in a goroutine and observe that it waits until space becomes available. Add one receiver and observe the waiting send continue.

Use a timeout in the experiment so a mistake cannot hang your terminal indefinitely. Explain the difference between a channel (an in-process Go value) and a broker (a separate process reachable through a network protocol).

Expected result: a queue with a fixed capacity stops accepting more work when full. This is backpressure: the producer is made to slow down or report overload instead of allowing unbounded memory growth.

## 3. Run one local broker

Create compose.yaml with this RabbitMQ service:

~~~yaml
name: kestrel-phase2
services:
  rabbitmq:
    image: rabbitmq:4-management
    environment:
      RABBITMQ_DEFAULT_USER: kestrel
      RABBITMQ_DEFAULT_PASS: learning-only
    ports:
      - "127.0.0.1:5672:5672"
      - "127.0.0.1:15672:15672"
    volumes:
      - rabbit-data:/var/lib/rabbitmq
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 5s
      timeout: 5s
      retries: 12

volumes:
  rabbit-data:
~~~

The first port is AMQP for Go; the second is the management page. Binding to 127.0.0.1 means only this computer can connect. The local password is for this disposable exercise only.

Start and inspect it:

~~~bash
docker compose up -d
docker compose ps
docker compose logs --tail=30 rabbitmq
~~~

The first command starts the container in the background. The second lists its state. The third shows its most recent startup logs. Expect the service to become healthy and the log to report that RabbitMQ is ready. If it restarts repeatedly, inspect the first error in the logs rather than repeatedly restarting it.

Open the local management page at http://127.0.0.1:15672 and sign in with the local credentials you configured. Create one queue named jobs. Stop RabbitMQ and note what disappears and what remains in the named volume. Remove only this lesson's container and volume when cleaning up; a volume deletion removes its stored local data.

## 4. Send one versioned message

Define the message before writing the publisher:

~~~json
{
  "version": 1,
  "job_id": 1,
  "operation": "process-demo",
  "idempotency_key": "job-1-process-demo",
  "attempt": 1
}
~~~

JSON is a text representation that both programs can parse. The version tells a reader which shape to expect. The job ID connects the message to the API's job. The idempotency key lets repeated deliveries refer to the same logical operation.

Implement Message in internal/jobs/message.go with these fields. `attempt` starts at one and increases only when the worker schedules a retry. Reject an unsupported major version and reject messages missing job_id or idempotency_key.

Implement these queue functions in internal/queue/rabbitmq.go:

- Open(connectionURL) returns a connection and channel or a descriptive error.
- DeclareJobsQueue(channel) declares jobs with durable=true, autoDelete=false, exclusive=false, and no-wait=false.
- DeclareRetryQueue(channel) declares durable queue jobs.retry with dead-letter exchange "" (the default exchange) and dead-letter routing key jobs. DeclareDeadQueue(channel) declares durable queue jobs.dead.
- Open also enables publisher confirms with channel.Confirm(false); register a confirmation channel with NotifyPublish and return it with the connection/channel.
- PublishJob(ctx, channel, message) encodes JSON, sets delivery mode to persistent, publishes to the default exchange with routing key jobs, and waits for the matching publisher confirmation before reporting success.
- PublishRetry(ctx, channel, message, delay) publishes persistently to jobs.retry with a per-message expiration in milliseconds and waits for publisher confirmation.
- ConsumeJobs(channel) sets prefetch to one, consumes with autoAck=false, and returns deliveries.

Both API and worker declare the three queues with the same settings. Do not set auto-ack: the broker could consider a message handled before work finishes. A durable queue plus a persistent message plus a publisher confirm is the broker-side evidence needed before the API reports that publication succeeded.

Publish one job, observe it appear in the queue, start the worker, and observe it leave the ready-message count. The worker should call the API completion route and acknowledge only after the API confirms the result. Record the message before and after delivery.

Use this API contract: POST /jobs returns 202 Accepted with id and state=queued; GET /jobs/{id} returns 200 and current state; POST /internal/jobs/{id}/complete returns 200 for a completed or already completed job. The internal route accepts a worker token from the Authorization header. The API creates its in-memory job before publishing. If publishing fails, mark the job failed and return 503; do not claim it was queued.

The worker algorithm is fixed: decode and validate one delivery; call the internal completion route with the idempotency key; acknowledge only after a 200 response. On a retryable 5xx, if attempt is below five, choose a delay of `min(2^(attempt-1) seconds, 30 seconds) + uniform random jitter from 0 to 500 milliseconds`, increment attempt, publish to jobs.retry, wait for publisher confirmation, and only then acknowledge the current delivery. The retry queue returns the message to jobs after its expiration. On the fifth delivery attempt, publish to jobs.dead with a reason category, wait for confirmation, and then acknowledge the original. Malformed or unsupported-major-version messages go directly to jobs.dead without requeue. Log only the message ID and reason category, not payload data. This bounds repeated failures without an immediate requeue loop.

## 5. Learn why duplicate delivery is normal

Add a test mode to the worker that pauses after the API has completed the job but before it acknowledges the message. Start the worker, publish one job, wait for the pause, and stop that worker. Start a replacement worker.

Expected result: RabbitMQ redelivers the unacknowledged message. The API sees the same job ID again. Make the completion operation idempotent: completing an already completed job returns the same effective result without performing a second side effect. The replacement worker then acknowledges the message.

Add tests named TestMessageVersion, TestCompletionIsIdempotent, TestWorkerAcknowledgesOnlyAfterSuccess, TestWorkerRetriesTransientFailure, TestRetryStopsAfterFiveAttempts, and TestPublishWaitsForConfirm. Use a fake HTTP handler and fake publisher confirmations for deterministic worker tests; retain one local integration run showing real broker redelivery.

This is at-least-once delivery: a message can be delivered one or more times until it is acknowledged. TCP delivery alone does not prove the receiving application finished its work. “Exactly once in effect” is an application property made from durable identity, duplicate detection, and idempotent effects; a broker label cannot make an arbitrary side effect happen exactly once.

Also test a failure before the API call. The job should remain queued and the broker should offer the message again. Keep retryable errors separate from permanently invalid messages. Inspect jobs.dead after forcing five failures; do not discard a message silently.

## 6. Observe the network path

Start the worker and API, then inspect local sockets:

~~~bash
ss -ltn
~~~

The command lists listening TCP sockets. Look for the API and RabbitMQ ports. Explain that a port is a number used by the operating system to direct network traffic to the correct listening socket; it is not a separate network.

If tcpdump is installed and you have permission, capture only local traffic for the API port:

~~~bash
sudo tcpdump -i lo -nn -c 12 port 8080
~~~

The loopback interface carries traffic between programs on the same machine. -i selects that interface, -nn avoids name lookups, -c stops after twelve packets, and the final expression filters by port. Send one curl request while it runs. You should see packets, not a readable Go function call: the kernel carries network bytes, then the server parses HTTP and calls a handler.

Read the socket and transport selections in the Phase 2 reading route after observing the exchange. Focus on what a port, TCP connection, and acknowledgment represent; do not infer that TCP confirmation means a job completed.

## 7. Bound overload and establish a service boundary

Configure a queue capacity or broker prefetch limit. Set the worker's prefetch to one while learning: one unacknowledged delivery at a time is easy to observe. Send more jobs than a deliberately slow worker can process. The ready queue should grow only to the configured bound; the API should reject excess submissions with 429 or a clearly documented asynchronous-acceptance response.

For local development, require a service token between the worker and API, loaded from an environment variable and compared in constant time. Bind the service to loopback and use a throwaway token. Explain that this is a teaching control, not a production identity system. Phase 6 will add purpose and policy checks; Phase 8 will review TLS and secrets.

## 8. Evolve the message contract

Add a second optional field under a versioned envelope. Make a compatibility test that loads a version 1 message after version 2 has been introduced. Unknown optional fields may be ignored; an unknown major version must be rejected or quarantined with a visible error. Never silently reinterpret a field.

Then read the short gRPC/Protocol Buffers section and implement a tiny local request/response only if you can explain the current HTTP exchange. Protocol Buffers describe typed messages; gRPC supplies a remote procedure call framework. They do not remove network failure, retries, timeouts, or the need to evolve a schema safely.

## Compare brokers without building three systems

RabbitMQ is the course's work-queue implementation. Read the NATS JetStream overview and Apache Kafka introduction and write a one-page comparison: what is retained, how a consumer acknowledges progress, how replay works, what failure behavior you would need, and which workload each model fits. JetStream adds durable streams and replay to NATS; Kafka is an event-streaming platform; RabbitMQ's queue acknowledgements fit the worker exercise. Keep the working build on one broker.

## Evidence gate

Save the API and worker request trace, one normal completion, one worker-stop/redelivery run, the idempotency test, a bounded-overload result, and a message-version compatibility test. State the delivery guarantee in one sentence and identify which component gives each part of the behavior.

Complete [learned.md](learned.md). Then close the lesson and implementation and rebuild the API-to-worker behavior in Kestrel from your own message contract, process diagram, and failure notes. Look up protocol documentation when needed; do not copy code. Compare only after recording your behavior and explaining why a duplicate cannot cause a second effective completion.

## Read beside the build

Read one item after the matching behavior appears. You do not need to finish a textbook before continuing.

| When | Read | Carry this question into the reading |
|---|---|---|
| Before the first socket exchange | Kurose & Ross, 8th ed., §2.7 and §§3.1–3.3; CSAPP, Chapter 11 | Which process owns each socket, and how does a byte reach the other endpoint? |
| After observing a disconnect | Kurose & Ross, §§3.4–3.5; *Understanding Distributed Systems*, Part I sections on reliable links and discovery | What can the sender know after a timeout, and why can retrying duplicate work? |
| Before implementing the broker-backed worker | van Steen & Tanenbaum, 4th ed., §§3.4, 4.2–4.3; SRE, Chapters 21–22 | Which delivery behavior follows from a queue and acknowledgement, and what happens under overload? |
| After the worker crash exercise | Dean and Ghemawat, “MapReduce” (2004), §3.3 | Why can a system safely re-execute a task only when its side effects are controlled? |
| While versioning the message | DDIA, Chapter 4; DDIA, Chapter 11's first section on message brokers | Which old and new readers can decode the same message? |
| Before adding backpressure and service identity | *Understanding Distributed Systems*, Part IV sections on failure causes and upstream resiliency; SRE, Chapters 21–22; Anderson's *Security Engineering*, Chapter 4 | What condition triggers a 429, and which service identity is trusted at this boundary? |

Official references: [RabbitMQ acknowledgements](https://www.rabbitmq.com/docs/confirms), [NATS JetStream](https://docs.nats.io/reference/2.12/jetstream), [Apache Kafka introduction](https://kafka.apache.org/documentation.html), and [Go AMQP client](https://github.com/rabbitmq/amqp091-go).
