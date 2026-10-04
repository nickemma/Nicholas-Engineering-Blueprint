# Phase 3 learning record

Complete this after [TEACHING.md](TEACHING.md). Answer from your experiment, in your own words. If you cannot support an answer with an output, test, or measurement, return to the matching step and produce that evidence.

## Data and transactions

1. What does the jobs table store? What does the outbox table store?
2. What does the primary key guarantee? What does the CHECK constraint reject? What does the foreign key connect?
3. What is a transaction? Show your BEGIN/ROLLBACK and BEGIN/COMMIT results.
4. Why were the job update and outbox insert in the same transaction?
5. How does Postgres distinguish SQL structure from a parameter value? Show the SQL-looking input test.
6. What isolation behavior did you observe or reason about? What would happen if two requests attempt the same state transition?

## Indexes and durable storage

7. What plan did Postgres choose before your index decision? What changed in the measured result? Which write/storage cost did you consider?
8. What is the page cache? Where does write_all place bytes? What does sync_data request?
9. What does PostgreSQL's WAL do before updated table pages are written?
10. What did killing the API process while a transaction was open prove? What did it not prove?
11. What is the difference between a torn final record and a corrupt complete record? How did the reader handle each?
12. What does CRC32C detect? Why is it not tamper protection?
13. What invariant did your compaction test check across a crash?
14. How did you verify the backup restore rather than merely checking that pg_restore exited?

## Evidence

| Claim | Evidence | Result |
|---|---|---|
| Invalid state cannot enter the table | rejected INSERT output | |
| Job and outbox event commit together | transaction failure test and row query | |
| SQL-looking input is stored as data | test and table query | |
| Index choice is measurement-based | before/after EXPLAIN output | |
| Log detects corruption and truncation | test names and results | |
| Restart recovers valid data | API and Rust recovery output | |
| Backup restores into separate database | row comparison | |

## Kestrel transfer

Close this lesson and its sample implementation. Recreate the storage behavior in your Kestrel checkout from your own requirements, notes, and test plan.

- What schema and transition did I design without looking at code?
- How does the transaction prevent a missing outbox event?
- What behavior proves persistence across an API restart?
- What did I test in the Rust parser before appending records?
- What are the four failure layers between a program's value and stable storage?
- What did I have to look up, and what can I now explain without memorizing?
- What differs from the teaching build, and which evidence supports the difference?
- What is still uncertain?
