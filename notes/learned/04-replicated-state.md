# Phase 4 self-test

Answer from memory, then check yourself against [the lesson](../../lessons/04-replicated-state/TEACHING.md). Write each "predict" answer before running anything.

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
