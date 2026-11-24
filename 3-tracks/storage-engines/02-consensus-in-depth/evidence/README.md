# Consensus in depth · Evidence

The reference used Go 1.26.6, Rust 1.94.1, Porcupine 1.3.1, the pinned TLA+ 1.8.0 release artifact, and PostgreSQL 17.11. The Raft runs used local Unix sockets and the Rust writer from Core 07. The TLC transcripts show the verdict and trace from each run.

| Fixture | Observation |
|---|---|
| Seeded snapshot run | Peer 2 lagged behind the compacted prefix and installed index 9. |
| WAL replacement | The repeated-write fixture dropped from 13,140 to 1,311 bytes before a new append. Reopening preserved term 3, vote 2, and three suffix entries after the append. |
| Seeded election | The original leader advanced from term 1 to term 6 with safeguards disabled. With PreVote enabled, the healthy majority committed in term 1. CheckQuorum stepped down the isolated leader within two windows. |
| Live client history | Porcupine accepted seven observations and rejected the completed stale read in the control. |
| Election model | TLC examined 4,687 distinct states and exhausted the queue. The double-vote variant elected two leaders in term 1. |
| Handoff | The source fenced epoch 1. After activation, only epoch 2 on the destination could write the range. The original and retried CAS results matched. |
| Prepared transfer | Before a decision the lock probe failed with 55P03. Recovery aborted and left balances (100, 50). After a durable commit and one participant commit, recovery finished at (80, 70). |
| Saga | The debit was visible before completion. After the destination failed, applying the same compensation twice restored the same balances as applying it once. |

- [Live gate](gate.txt) and [clean lesson replay](replay.txt)
- [Captured client history](history.json) and [stale-read control](stale.json)
- [TLC reference](tlc.txt) and [double-vote counterexample](tlc-double-vote.txt)

The file-size observation applies to a repeated-value fixture. The client history uses one key. The model checks election safety within the configured term bound. The PostgreSQL lab uses one durable decision table and runs one coordinator at a time.
