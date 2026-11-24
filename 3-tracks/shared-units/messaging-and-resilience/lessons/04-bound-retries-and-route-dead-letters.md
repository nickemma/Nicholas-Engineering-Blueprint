# 04 Bound retries and route dead letters

Group failure outcomes by whether another attempt can help. Send an unsupported version or conflicting command identity to the dead-letter queue. Requeue a temporary dependency failure after a bounded pause. RabbitMQ counts repeated rejection of the quorum queue delivery and eventually dead-letters it.

Check the difference between a consumer acknowledgment, rejecting a message without requeueing it, and rejecting it for another attempt. Trace the command queue arguments back to the dead-letter destination. A rejected message can carry valid user data, so keep inspection restricted to the lab's own queues. [RabbitMQ quorum queues](https://www.rabbitmq.com/docs/quorum-queues) · [Negative acknowledgments](https://www.rabbitmq.com/docs/nack)

In the live gate, compare the unsupported schema, identity conflict, and repeated temporary failure. All three end up in the dead-letter queue while the original durable effect count stays at one.
