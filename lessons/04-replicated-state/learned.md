# Phase 4: what I learned

Fill this in as you go, with evidence: seeds, test names, traces, TLC output, logs. Keep your filled-in copy in your own repository.

## Explain it

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

## Evidence checklist

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

## Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the guide, and why:
- What is still unclear:
