# Postgres in depth · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: Reproduce isolation anomalies

1. State ACID in one sentence per letter.
2. Draw the lost-update timeline. Which isolation level prevents it, and what does the second transaction see?
3. Give three fixes for a read-modify-write race, and the cost of each.
4. What does SQLSTATE `40001` mean, and what must the caller do?

### Lesson 02: Read the plan before adding an index

5. Read a plan line like `Seq Scan ... Rows Removed by Filter: 333072`. What did the database do?
6. What is a partial index, and why can it be tiny on a large table?
7. Why can't `CREATE INDEX CONCURRENTLY` run in a transaction?

### Lesson 04: Claim and recover background jobs

8. What do `FOR UPDATE` and `SKIP LOCKED` each do? What happens with neither?
9. Why must a background task be idempotent and resumable?
10. What makes a claimed job abandoned? What goes wrong if the recovery timeout is too short?

### Lesson 05: Crash the server and restore a dump

11. Define RPO and RTO. Give both for nightly `pg_dump` and for WAL archiving with point-in-time recovery.
12. Why is a `pg_dump` consistent even while writes continue?
13. Explain what PostgreSQL did after SIGKILL, line by line from its log. What does `invalid record length ... got 0` mean?
14. What do `klog`'s recovery and PostgreSQL's recovery have in common? What does PostgreSQL do that `klog` doesn't?

### Lesson 06: Recover to a named point

15. After a restore, why must you move the identity sequences forward? What could go wrong if you don't?

### Lesson 07: Run the isolation and recovery gate

16. Why does a panic in a background goroutine need a `recover`? What does `recover` not fix?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | What does each letter of ACID promise, and which did the "Break it" violate? | | |
| 01 | Draw the lost-update timeline, and say how each of the three fixes changes it | | |
| 02 | Read your two query plans aloud: where did the time go, and why is the partial index small? | | |
| 04 | What do `FOR UPDATE` and `SKIP LOCKED` each contribute? | | |
| 04 | Why must background tasks be idempotent and resumable? | | |
| 04 | Why must the recovery timeout be longer than a worker's whole retry cycle? | | |
| 05 | Define RPO and RTO; give each for nightly `pg_dump`s and for WAL archiving | | |
| 05 | Why is a `pg_dump` consistent while the API keeps writing? | | |
| 05 | After the restore, what did the audit log tell you, and why move the identity forward? | | |
| 05 | What does `invalid record length ... got 0` mean in the recovery log? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A lost update happens under `READ COMMITTED`, and each fix prevents it | | |
| The reaper fails an orphaned job, with its reason in the history | | |
| The partial index turns a sequential scan into an index scan | | |
| PostgreSQL recovers a committed row after SIGKILL | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
