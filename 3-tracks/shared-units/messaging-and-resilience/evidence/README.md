# Messaging and resilience · Evidence

The reference run used Go 1.26.6 with the `rabbitmq:4-management` and `postgres:17` Docker images.

- [Gate capture](gate.txt). Contract and circuit breaker checks, a crash and redelivery against RabbitMQ and PostgreSQL, and the premature-acknowledgment negative control.
- [Clean lesson replay](replay.txt). All lesson markers replayed from a new scratch directory with the live gate enabled.
