# Phase 3: what I learned

Fill this in as you go, with evidence: commands and their output, test names, query plans, logs. Keep your filled-in copy in your own repository.

## Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | Why does `Create` use `RETURNING` for the timestamps? | | |
| 1 | Why can't a value sent as a parameter change a query's meaning? | | |
| 1 | What does a contract test give you that two separate test files don't? | | |
| 2 | Why does a database limit its connections? | | |
| 2 | Using Little's law, how many connections does 300 queries a second of 5 ms each need? | | |
| 2 | In burst 1, why did the pool of 10 wait almost as often as the pool of 2? | | |
| 3 | What does each letter of ACID promise, and which did the "Break it" violate? | | |
| 3 | Draw the lost-update timeline, and say how each of the three fixes changes it | | |
| 3 | Why is Runway's `Update` safe under `READ COMMITTED`? | | |
| 4 | Why can't you fix the dual-write problem by publishing first? | | |
| 4 | Why is the outbox at least once, and why is that acceptable here? | | |
| 4 | What do `FOR UPDATE` and `SKIP LOCKED` each contribute? | | |
| 5 | Why is "check, then insert" a race, and how does `ON CONFLICT DO NOTHING` close it? | | |
| 5 | Why must a failed `Begin` refuse the request? | | |
| 5 | What went wrong when two instances migrated at once, and how does the advisory lock fix it? | | |
| 6 | What does a committed offset record, and what happens when a group member leaves? | | |
| 6 | Why key events by job ID? | | |
| 6 | Why does counting need an inbox when the job handlers didn't? | | |
| 6 | Name two things a log can do that a queue can't | | |
| 7 | Why does a write delete the cached copy instead of updating it? | | |
| 7 | Draw the race that still lets a stale value in, and say what bounds it | | |
| 7 | What is a stampede, and how does singleflight stop it? | | |
| 7 | Why must a cache fail open, and what makes it fail fast? | | |
| 8 | Why must background tasks be idempotent and resumable? | | |
| 8 | What does `pg_try_advisory_xact_lock` guarantee, what doesn't it, and what happens if its holder crashes? | | |
| 8 | Read your two query plans aloud: where did the time go, and why is the partial index small? | | |
| 8 | Why must `ABANDON_AFTER` be longer than a worker's whole retry cycle? | | |
| 9 | Which errors should open a database breaker, and which must not? | | |
| 9 | Why does the breaker sit under the cache? | | |
| 9 | Liveness vs readiness: what goes wrong if a database outage fails liveness? | | |
| 10 | Why does the feed commit only after `klog` confirms, and what does that guarantee? | | |
| 10 | When can an audit line be written twice, and how would you detect it? | | |
| 10 | What does CRC-32C protect against, and what doesn't it? | | |
| 11 | Define RPO and RTO; give each for nightly `pg_dump`s and for WAL archiving | | |
| 11 | Why is a `pg_dump` consistent while the API keeps writing? | | |
| 11 | After the restore, what did the audit log tell you, and why move the identity forward? | | |
| 11 | What does `invalid record length ... got 0` mean in the recovery log? | | |

## Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A job survives an API restart | | |
| A parameter can't inject SQL; pasted text can | | |
| The same contract passes against memory, PostgreSQL and the cache | | |
| An exhausted pool makes callers wait until their deadline | | |
| A lost update happens under `READ COMMITTED`, and each fix prevents it | | |
| A job and its event commit together, or not at all | | |
| Killing the API between commit and send loses no job | | |
| Two instances share one idempotency key | | |
| A projection rebuilt under a new group matches the original | | |
| The cache serves hits, survives Redis being stopped, and recovers | | |
| The reaper fails an orphaned job, with its reason in the history | | |
| The partial index turns a sequential scan into an index scan | | |
| A frozen database opens the breaker; `/ready` fails and `/health` doesn't | | |
| `klog` dies and the feed recovers with nothing lost | | |
| A restored backup, reconciled against the audit log | | |
| PostgreSQL recovers a committed row after SIGKILL | | |

## Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the guide, and why:
- What is still unclear:
