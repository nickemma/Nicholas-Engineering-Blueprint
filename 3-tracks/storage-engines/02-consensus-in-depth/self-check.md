# Consensus in depth · Self-check

Answer before looking at code. Use the captured histories and the election counterexample after you have drawn your own.

1. A snapshot ends at index 8 in term 2. What sits at slice offsets 0 and 1? What can a follower retain if it has index 8 in term 3?
2. Trace a crash just after the snapshot frame is durable, then trace a crash just after renaming the replacement WAL. Which path does startup open? Where do the current term and vote come from in each case?
3. The leader A can reach B; B can reach C; A and C cannot reach each other. Draw the messages that cause term churn without PreVote. Which response changes when PreVote is enabled?
4. What does CheckQuorum count? Why might the old leader survive the first window after isolation?
5. A CAS succeeds, its answer disappears, and another write changes the value. Which result does the retry return? Which part of a snapshot or a range image preserves that answer?
6. Place a pending write and two completed reads on a timeline. Show a history that can use the pending write to explain the reads and one that stays illegal even if you include it.
7. In TLC’s counterexample, which peer overlaps the two majorities? Why does the model keep an election history after a leader steps down?
8. At what update does the source stop serving a range? What can a restarted mover safely repeat after the destination has already applied a newer write?
9. Draw the lock and balance timelines when the coordinator stops after prepare and when it stops after the first participant commits. Explain what an outside reader can observe before recovery.
10. Where do you record the ID of a compensation so the refund and the idempotency check share a commit?

Check your answers with the [lessons and gate](README.md) and compare your timelines with the [reference evidence](evidence/README.md).

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
