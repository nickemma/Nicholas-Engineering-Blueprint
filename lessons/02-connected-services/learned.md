# Phase 2 learning record

Complete this after the guided build. Attach traces, test names, or command output instead of relying on a definition alone.

## Process and network path

1. Draw the API, RabbitMQ, and worker as separate processes. Where does each job state live?
2. Explain the path from curl through the API, broker, worker, completion request, and response.
3. What does a listening port tell you? What could you see in the packet capture, and what could you not see?
4. How is a Go channel different from a broker queue?

## Delivery and reliability

5. What exact event caused RabbitMQ to redeliver the message?
6. What is at-least-once delivery? Why can the worker receive duplicates?
7. What does your idempotency check use as the identity of an operation?
8. What does the broker acknowledgment prove? What does it not prove?
9. How did you bound work when the consumer was slow?
10. How does the API treat a transient error differently from a malformed message?

## Message and security boundaries

11. What purpose does the message version serve? What should the worker do with a major version it does not understand?
12. Which identity check did you add between worker and API? Why is the local shared token not a production identity solution?
13. Compare RabbitMQ, NATS JetStream, and Kafka for the workload in this phase. Name one reason not to deploy each alternative here.

## Evidence and transfer to Kestrel

| Claim | Evidence | Result |
|---|---|---|
| A job reaches a separate worker | process list and request trace | |
| An unacknowledged message returns after worker failure | redelivery log or queue view | |
| A duplicate causes one effective completion | test name and API result | |
| Overload is bounded | queue/prefetch setting and observed result | |
| A compatible message version is read | compatibility test | |

- What did I rebuild in Kestrel without opening lesson code?
- Which behavior did I test before adding retries?
- What needed a documentation lookup, and what could I explain without it?
- What changes if the broker is unavailable?
- What is still volatile until Phase 3?
- What remains unclear?
