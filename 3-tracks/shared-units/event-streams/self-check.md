# Event streams · Self-check

1. Which value identifies a business event? Which values identify one Kafka record? Give an example where two records refer to the same event.
2. Why is the outbox insert inside the job transaction? What remains if that transaction rolls back?
3. Why can a relay publish a record twice even with an idempotent producer? What does the retry do to its key and offset?
4. What happens if the projector commits its Kafka offset before its PostgreSQL transaction? What does it do when the reverse order causes a reread?
5. What does a new group change about offsets? Why does the rebuild need its own inbox too?
6. How can retention limit a rebuild? What record order does key partitioning give you, and when could two different jobs share it?

## From memory

Draw Kafka and the two PostgreSQL transactions. Mark the points where the writer can roll back, the relay can republish, and the projector can reread. Predict the pending rows, offsets, and count at each point, then compare your predictions with a live gate run.

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
