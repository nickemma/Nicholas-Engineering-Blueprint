# Extended review

Related modules for this review are [Distributed-systems fundamentals](../../../2-core/07-distributed-systems-fundamentals/README.md).

Answer from memory, then check yourself against [the lesson](README.md). Write each "predict" answer before running anything.

## A. Failure, time and simulation

1. Name the failure model and the timing model this phase assumes. What would change under Byzantine failures?
2. Why can a failure detector only *suspect*? What happens to false suspicions and detection time as the timeout grows?
3. State FLP precisely. How does Raft live with it?
4. State CAP precisely. Which side does Raft choose during a partition, and what does the minority side do?
5. What is a logical clock? Which part of Raft is one?
6. What makes a simulation deterministic? Name three things that would quietly break determinism in Go.
7. Draw a one-way cut and a partial partition. What does each node believe in each?

## B. Elections

8. Explain terms. What does a node do when it sees a higher term? A lower one?
9. Prove that a term can't have two leaders. Which line of code does the proof depend on?
10. Why are election timeouts random? What happens if they aren't?
11. How many failures do clusters of 3, 4 and 5 nodes tolerate?
12. Predict: a node grants every vote request. What does the storm test report, and roughly when?

## C. Replication and safety

13. What does the consistency check compare, and what property does it guarantee?
14. When does a follower delete entries? Why are the deleted entries never committed?
15. What are `next` and `match`? What must always be true of them, and why?
16. When is an entry committed? Why does a leader count replicas only for current-term entries?
17. Draw Figure 8. Name the two protections in your code. Predict what the Figure 8 test reports with one removed, then both.
18. Define safety and liveness, with an example of each from Raft.

## D. Persistence and snapshots

19. What three things must be saved, and what goes wrong without each?
20. Why save, then send, then apply? Describe the failure the storm test found with the order swapped.
21. Why do 1,000 seeds catch the wrong order when 200 didn't?
22. How does the WAL save a truncated log without rewriting the file?
23. What does a snapshot contain? When does InstallSnapshot keep the follower's later entries?
24. List the steps of replacing a file atomically. What does each one protect against?
25. Explain the `next`/`match` bug the simulator found, and why the fix needed a regression test.

## E. Partial partitions

26. Describe the disruptive returner. What term did it come back with, and what did it cost?
27. Describe the partial partition that keeps deposing leaders.
28. How does PreVote work? Why must a peer refuse if it heard from a leader recently?
29. Why did only the idle test catch the missing leader check?
30. What does CheckQuorum do, and what does it protect clients from?

## F. Linearizability

31. Define linearizability. How is it different from serializability?
32. Predict: a leader answers reads from its own copy during a partition. What can a client see?
33. What are ReadIndex and lease reads, and what does each assume?
34. How do sessions make retries exactly-once? What happens without them, and how did Porcupine show it?
35. How does Porcupine check a history? Why does partitioning by key make it fast?

## G. Running it

36. Why does one goroutine own the core?
37. Why must the transport never block?
38. What does 421 mean here, and what should a client do with it?
39. Predict: in a three-member `metad`, you kill two members. What does a client see, and why?
40. Why does `metad` stop if it can't save?

## H. TLA+

41. What are `Init`, `Next`, and an invariant? What does `'` mean?
42. What does TLC prove, and what doesn't it?
43. Read the counterexample for a double vote, step by step.
44. Why is TLC's counterexample the shortest possible?

## I. Leases, fencing and partitioning

45. What does a lease add to a lock? What does it assume about clocks?
46. Why does the leader stamp the time into lock commands?
47. Tell Kleppmann's pause story, and show where a fencing token stops it.
48. Why does `hash mod N` move most keys when N changes? How many does a ring move?
49. What do virtual nodes fix? Give the imbalance numbers for 1 and 100.
50. Why can't hashing fix a hot key? What can?
51. When a cache server died, what happened to its keys, and to everyone else's?

## J. Transactions across shards

52. Walk through two-phase commit. Where exactly does the change commit?
53. Why does 2PC block? What does presumed abort decide on recovery?
54. Why is `max_prepared_transactions` off by default?
55. What is a saga? What does a compensation do that a rollback doesn't?
56. 2PC or saga: choose for (a) moving money between two shards of one database, (b) booking a flight and a hotel with two companies. Explain.

## Evidence worksheet

Fill this in as you go, with evidence: seeds, test names, traces, TLC output, logs. Keep your filled-in copy in your own repository.

### Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | Why can't a node tell a crashed peer from a slow one? | | |
| 1 | State FLP and CAP precisely, and say what each does *not* say | | |
| 1 | What does a seeded simulator give you that real processes don't? | | |
| 2 | Why can't two candidates win the same term? | | |
| 2 | Why are election timeouts random? | | |
| 2 | Why does a 4-node cluster tolerate no more failures than a 3-node one? | | |
| 3 | What does the consistency check guarantee, and how? | | |
| 3 | Why may a follower delete entries, and why are they never committed ones? | | |
| 3 | Draw Figure 8, and explain each of the two protections against it | | |
| 4 | Which three things must a node save, and what goes wrong if it forgets each? | | |
| 4 | Why must saving come before sending? Use the failing seed | | |
| 4 | Why does one `fsync` per `Ready` make the log fast? | | |
| 5 | What does a snapshot replace, and who makes it? | | |
| 5 | When does a follower keep entries after a snapshot, and when must it drop them? | | |
| 5 | Why does replacing a file atomically need a rename and a directory `fsync`? | | |
| 5 | Explain the `next`/`match` bug, and why it needed a regression test | | |
| 6 | What does PreVote prevent, and why does it need the leader check? | | |
| 6 | What does CheckQuorum add? | | |
| 6 | Trace one round of disruption in the partial partition without PreVote | | |
| 7 | Define linearizability, including the part about real time | | |
| 7 | Why must reads go through the log, or use ReadIndex or a lease? | | |
| 7 | How do sessions make a retried `append` happen once, and why are they in the snapshot? | | |
| 8 | Why does one goroutine own the core? | | |
| 8 | What does the runtime do with each `Ready`, and why stop if saving fails? | | |
| 8 | How does a waiting request learn its entry was lost? | | |
| 8 | What happened, tick by tick, when you killed the leader? | | |
| 9 | What does TLC check that the storm tests don't, and the other way round? | | |
| 9 | Why does the model need the `elected` history variable? | | |
| 9 | What did the model leave out, and why is that acceptable? | | |
| 10 | What does a lease add to a lock, and what does it assume about clocks? | | |
| 10 | Why can't a holder detect its own pause? | | |
| 10 | How do fencing tokens make the resource safe? Why does a renewal keep its token? | | |
| 11 | Why does `hash mod N` move most keys, and a ring about 1/N? | | |
| 11 | What do virtual nodes fix? What can and can't fix a hot key? | | |
| 11 | When a cache server stopped, which keys moved, and why only those? | | |
| 12 | Walk through 2PC; what may a participant do after preparing? | | |
| 12 | Why does 2PC block, and what does presumed abort decide? | | |
| 12 | When would you choose a saga, and what do you give up? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| The same seed replays exactly; a different seed doesn't | | |
| A broken vote rule is caught, with its seed and tick | | |
| Figure 8 happens only with both protections removed | | |
| Sending before saving fails a storm seed; saving first never does | | |
| A torn WAL record is cut off; damage in the middle is refused | | |
| A lagging follower catches up from a snapshot | | |
| PreVote: zero elections during a partial partition | | |
| Porcupine passes for the store, and catches local reads and missing sessions | | |
| A `metad` leader killed with `kill -9`; the value survives | | |
| TLC's counterexample for a double vote, read as a story | | |
| A late lock holder's write refused by fencing | | |
| Adding a node moves about 1/N of keys on the ring, most with mod N | | |
| Losing one cache server: every read still answered | | |
| A crashed 2PC coordinator leaves locks held until recovery | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the guide, and why:
- What is still unclear:
