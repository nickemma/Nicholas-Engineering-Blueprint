# Integrity and encryption · Self-check

Write an answer before reopening the lessons.

1. Encode two tenant IDs where one is a prefix of the other. Why do their user keys remain distinct?
2. Compute the exclusive upper endpoint of a tenant prefix that ends in `ff ff`. Which keys share the prefix?
3. What happens if a caller uses the wrong tenant handle? Which layer is responsible for creating the handle from verified authorization?
4. Name the envelope fields and the bytes supplied as associated data. Which bytes remain visible on disk?
5. Explain how an old pinned version can still require the old key after a rotation and compaction.
6. Which response authorizes the Kafka consumer to advance its offset? What does the broker replay if the feed stops just after that response?
7. Explain why event ID and stream partition position are distinct.
8. What is bound by a signed checkpoint? What additional claim does an inclusion proof show?
9. If a larger checkpoint is validly signed, how does the witness establish that it extends the prefix already witnessed?
10. Which facts can an independent reader establish if it has an older witness receipt and cannot get the current head?

Use the [lessons](README.md) and [reference evidence](evidence/README.md) to check your reasoning.
