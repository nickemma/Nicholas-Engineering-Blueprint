# Consensus in depth · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: Give clients a replicated key-value store

1. Define linearizability. How is it different from serializability?
2. Predict: a leader answers reads from its own copy during a partition. What can a client see?

### Lesson 02: Compact a log and install a snapshot

3. What does a snapshot contain? When does InstallSnapshot keep the follower's later entries?
4. Explain the `next`/`match` bug the simulator found, and why the fix needed a regression test.

### Lesson 03: Recover across the snapshot and log boundary

5. List the steps of replacing a file atomically. What does each one protect against?

### Lesson 04: Keep an election from disrupting a healthy majority

6. Describe the disruptive returner. What term did it come back with, and what did it cost?
7. Describe the partial partition that keeps deposing leaders.
8. How does PreVote work? Why must a peer refuse if it heard from a leader recently?
9. Why did only the idle test catch the missing leader check?
10. What does CheckQuorum do, and what does it protect clients from?

### Lesson 05: Check client histories for linearizability

11. How does Porcupine check a history? Why does partitioning by key make it fast?

### Lesson 06: Model election safety with TLA+

12. What are `Init`, `Next`, and an invariant? What does `'` mean?
13. What does TLC prove, and what doesn't it?
14. Read the counterexample for a double vote, step by step.
15. Why is TLC's counterexample the shortest possible?

### Lesson 08: Recover a transaction across two shards

16. Walk through two-phase commit. Where exactly does the change commit?
17. Why does 2PC block? What does presumed abort decide on recovery?
18. Why is `max_prepared_transactions` off by default?
19. What is a saga? What does a compensation do that a rollback doesn't?
20. 2PC or saga: choose for (a) moving money between two shards of one database, (b) booking a flight and a hotel with two companies. Explain.

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 02 | What does a snapshot replace, and who makes it? | | |
| 02 | When does a follower keep entries after a snapshot, and when must it drop them? | | |
| 02 | Explain the `next`/`match` bug, and why it needed a regression test | | |
| 03 | Why does replacing a file atomically need a rename and a directory `fsync`? | | |
| 04 | What does PreVote prevent, and why does it need the leader check? | | |
| 04 | What does CheckQuorum add? | | |
| 04 | Trace one round of disruption in the partial partition without PreVote | | |
| 05 | Define linearizability, including the part about real time | | |
| 05 | How do sessions make a retried `append` happen once, and why are they in the snapshot? | | |
| 06 | What does TLC check that the storm tests don't, and the other way round? | | |
| 06 | Why does the model need the `elected` history variable? | | |
| 06 | What did the model leave out, and why is that acceptable? | | |
| 08 | Walk through 2PC; what may a participant do after preparing? | | |
| 08 | Why does 2PC block, and what does presumed abort decide? | | |
| 08 | When would you choose a saga, and what do you give up? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A lagging follower catches up from a snapshot | | |
| PreVote: zero elections during a partial partition | | |
| Porcupine passes for the store, and catches local reads and missing sessions | | |
| TLC's counterexample for a double vote, read as a story | | |
| A crashed 2PC coordinator leaves locks held until recovery | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
