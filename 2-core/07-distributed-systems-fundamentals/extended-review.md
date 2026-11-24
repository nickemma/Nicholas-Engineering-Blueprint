# Core 07 · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: What a node can know

1. Name the failure model and the timing model this module assumes. What would change under Byzantine failures?
2. Why can a failure detector only *suspect*? What happens to false suspicions and detection time as the timeout grows?
3. State FLP precisely. How does Raft live with it?
4. State CAP precisely. Which side does Raft choose during a partition, and what does the minority side do?
5. What is a logical clock? Which part of Raft is one?
6. What makes a simulation deterministic? Name three things that would quietly break determinism in Go.
7. Draw a one-way cut and a partial partition. What does each node believe in each?

### Lesson 02: Elect a leader with a quorum

8. Explain terms. What does a node do when it sees a higher term? A lower one?
9. Prove that a term can't have two leaders. Which line of code does the proof depend on?
10. Why are election timeouts random? What happens if they aren't?
11. How many failures do clusters of 3, 4 and 5 nodes tolerate?
12. Predict: a node grants every vote request. What does the storm test report, and roughly when?

### Lesson 03: Replicate and repair a log

13. What does the consistency check compare, and what property does it guarantee?

### Lesson 04: Decide what is committed

14. When does a follower delete entries? Why are the deleted entries never committed?
15. What are `next` and `match`? What must always be true of them, and why?
16. When is an entry committed? Why does a leader count replicas only for current-term entries?
17. Draw Figure 8. Name the two protections in your code. Predict what the Figure 8 test reports with one removed, then both.
18. Define safety and liveness, with an example of each from Raft.

### Lesson 05: Save before you reply

19. What three things must be saved, and what goes wrong without each?
20. Why save, then send, then apply? Describe the failure the storm test found with the order swapped.
21. Why can more seeds catch a wrong save order that fewer missed?

### Lesson 06: Persist Raft state in the Rust log

22. How does the WAL save a truncated log without rewriting the file?

### Lesson 07: Run three real processes

23. Why does one goroutine own the core?
24. Why must the transport never block?
25. Why does `metad` stop if it can't save?

### Lesson 08: Kill a writer during a partition

26. Predict: in a three-peer cluster, you kill two peers. What does a client see, and why?

### Lesson 09: Fence a worker that outlives its lease

27. What does a lease add to a lock? What does it assume about clocks?
28. Why does the leader stamp the time into lock commands?
29. Tell Kleppmann's pause story, and show where a fencing token stops it.

### Lesson 10: Move fewer keys with consistent hashing

30. Why does `hash mod N` move most keys when N changes? How many does a ring move?
31. What do virtual nodes fix? Give the imbalance numbers for 1 and 100.
32. Why can't hashing fix a hot key? What can?
33. When a cache server died, what happened to its keys, and to everyone else's?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | Why can't a node tell a crashed peer from a slow one? | | |
| 01 | State FLP and CAP precisely, and say what each does *not* say | | |
| 01 | What does a seeded simulator give you that real processes don't? | | |
| 02 | Why can't two candidates win the same term? | | |
| 02 | Why are election timeouts random? | | |
| 02 | Why does a 4-node cluster tolerate no more failures than a 3-node one? | | |
| 03 | What does the consistency check guarantee, and how? | | |
| 04 | Why may a follower delete entries, and why are they never committed ones? | | |
| 04 | Draw Figure 8, and explain each of the two protections against it | | |
| 05 | Which three things must a node save, and what goes wrong if it forgets each? | | |
| 05 | Why must saving come before sending? Use the failing seed | | |
| 06 | Why does one `fsync` per `Ready` make the log fast? | | |
| 07 | Why does one goroutine own the core? | | |
| 07 | What does the runtime do with each `Ready`, and why stop if saving fails? | | |
| 07 | How does a waiting request learn its entry was lost? | | |
| 07 | What happened, tick by tick, when you killed the leader? | | |
| 09 | What does a lease add to a lock, and what does it assume about clocks? | | |
| 09 | Why can't a holder detect its own pause? | | |
| 09 | How do fencing tokens make the resource safe? Why does a renewal keep its token? | | |
| 10 | Why does `hash mod N` move most keys, and a ring about 1/N? | | |
| 10 | What do virtual nodes fix? What can and can't fix a hot key? | | |
| 10 | When a cache server stopped, which keys moved, and why only those? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| The same seed replays exactly; a different seed doesn't | | |
| A broken vote rule is caught, with its seed and tick | | |
| Figure 8 happens only with both protections removed | | |
| Sending before saving fails a storm seed; saving first never does | | |
| A torn WAL record is cut off; damage in the middle is refused | | |
| A `metad` leader killed with `kill -9`; the value survives | | |
| A late lock holder's write refused by fencing | | |
| Adding a node moves about 1/N of keys on the ring, most with mod N | | |
| Losing one cache server: every read still answered | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
