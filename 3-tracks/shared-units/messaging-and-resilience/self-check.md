# Messaging and resilience · Self-check

1. What is authoritative for the job effect after the worker dies? What does a publisher confirm establish, and what does the consumer acknowledgment establish?
2. Which command fields must agree when a version-2 delivery reuses a version-1 command ID? What happens when they disagree?
3. What should a replacement worker do after a crash between commit and the publisher confirm? What extra outcome is possible if the crash comes after the confirm?
4. Why does the worker requeue a temporary database failure and send a permanently unsupported schema to the dead-letter queue immediately?
5. What request does each circuit breaker protect? What happens when its cooldown expires and the first request still fails?
6. Why does the negative control leave one row in PostgreSQL even though it fails the gate?

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
