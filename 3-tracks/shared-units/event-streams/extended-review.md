# Event streams · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: Name the event and its partition key

1. What is lag, and what does growing lag tell you?
2. Why does a failed record stop the consumer instead of being skipped? What's the alternative?

### Lesson 02: Commit the event with the write

3. What is the dual-write problem? Why doesn't swapping the order fix it?
4. How does the transactional outbox close it? Why is it at least once rather than exactly once?
5. Why can relays running on several instances deliver one job's events out of order?

### Lesson 03: Relay and resend after a crash

6. Define topic, partition, offset, key and consumer group.
7. How does Kafka keep one job's events in order? What order does it *not* promise?

### Lesson 04: Apply the event, then commit its offset

8. Why can't a worker reliably remember "I already did this"? What does the inbox pattern do?
9. A topic has 3 partitions and a group has 5 members. How many are busy?

### Lesson 05: Rebuild the read model from the log

10. How do you replay a stream into a new read model? Why can't you do that with a RabbitMQ queue?
11. Why does the projector need an inbox when Switchyard's job handlers didn't? Why must the inbox insert be in the same transaction as the count?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | Why key events by job ID? | | |
| 01 | Why does counting need an inbox when the job handlers didn't? | | |
| 01 | Name two things a log can do that a queue can't | | |
| 02 | Why can't you fix the dual-write problem by publishing first? | | |
| 02 | Why is the outbox at least once, and why is that acceptable here? | | |
| 04 | What does a committed offset record, and what happens when a group member leaves? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A job and its event commit together, or not at all | | |
| Killing the API between commit and send loses no job | | |
| A projection rebuilt under a new group matches the original | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
