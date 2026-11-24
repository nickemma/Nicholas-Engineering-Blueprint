# Postgres in depth · Self-check

1. How can Read Committed lose an application update even when the database locks each individual write?
2. Why can two Repeatable Read transactions update different rows and violate an invariant? What work must be retried when Serializable returns 40001?
3. Which plan values tell you that the index saved work? What does an index-only scan report when it still has to check heap visibility?
4. How would a B-tree and an LSM engine each find the first 16 ordered results? What background work does each layout require?
5. What happens to the second claimant when the first holds the oldest row lock? Why does completion need a current attempt token?
6. Which row survived SIGKILL and why? How does that differ from restoring a logical dump?
7. Which data and settings are needed to recover to a named point? How do you prove the recovered cluster has the intended state?
8. What does the lab's measured restore duration include? What else belongs in a real recovery-time measurement?

## From memory

Draw both transaction schedules and a timeline containing a logical dump, a physical base backup, a named recovery point, and later writes. Predict the resulting rows for each test, then verify them against the live gate.

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
