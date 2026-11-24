# Core 03 · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 02: A schema you can change

1. Why keep constraints in the database when the domain already validates the same rules?
2. What is a migration, and how does the migration tool record which ones have run?
3. Predict: a client sends `' OR '1'='1` as a description, and the code builds SQL by joining strings. What happens? What happens with `$1`?
4. Why is "check whether the key exists, then insert it" a race? What one statement replaces it?
5. Predict: the key store's `Begin` fails because the database is down. What should the middleware answer, and why not just run the request?
6. Two instances started together and one died during migration. Why? What fixed it?

### Lesson 03: One contract for two repositories

7. Why does `Create` read the timestamps back with `RETURNING`? What would a contract test with whole-second times have missed?

### Lesson 04: A connection pool has a limit

8. What's a primary key, an identity column, a `CHECK` constraint and a foreign key? Give one example of each from Switchyard's schema.
9. Why did the domain, HTTP handlers and gRPC server not change when PostgreSQL arrived?
10. Why is a database connection expensive? What does PostgreSQL run for each one?
11. With 400 queries a second taking 5 ms each, how many connections are busy on average? Ten instances share a server limit of 100 connections: what pool size would you give each?
12. Predict: the pool has 2 connections, both busy for 3 seconds, and a request with a 100 ms deadline arrives. What does it get, and when?

### Lesson 05: Complete a job in one transaction

13. What is write skew? Give an example that `REPEATABLE READ` doesn't prevent.
14. Predict: one statement inside the transaction uses the pool instead of the transaction. Which failures does that let through?

### Lesson 06: A retried submission survives a restart

15. What gap remains between the idempotency key and the job, and how would you close it?

### Lesson 08: Run the stack and measure it

16. Why is PID 1 special for signals? What does `--init` change?
17. Why does the Dockerfile copy `go.mod` and `go.sum` before the rest of the code?
18. What should a health check test? What does `condition: service_healthy` wait for?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | What does a contract test give you that two separate test files don't? | | |
| 02 | Why can't a value sent as a parameter change a query's meaning? | | |
| 02 | Why must a failed `Begin` refuse the request? | | |
| 03 | Why does `Create` use `RETURNING` for the timestamps? | | |
| 04 | Why does a database limit its connections? | | |
| 04 | Using Little's law, how many connections does 300 queries a second of 5 ms each need? | | |
| 05 | Why is Switchyard's `Update` safe under `READ COMMITTED`? | | |
| 06 | Why is "check, then insert" a race, and how does `ON CONFLICT DO NOTHING` close it? | | |
| 06 | What went wrong when two instances migrated at once, and how does the advisory lock fix it? | | |
| 08 | What does `condition: service_healthy` wait for that `depends_on` alone doesn't? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A job survives an API restart | | |
| A parameter can't inject SQL; pasted text can | | |
| The same contract passes against memory and PostgreSQL | | |
| An exhausted pool makes callers wait until their deadline | | |
| Two instances share one idempotency key | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
