# Phase 1: what I learned

Fill this in as you finish each step of [TEACHING.md](TEACHING.md), then again from memory after the rebuild. Every answer needs evidence: a command and its output, a test name, or a link. Keep your filled-in copy in your own `runway` repository.

## Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | Why do the domain functions take `now` as a parameter instead of calling `time.Now()`? | | |
| 1 | What does making `Description` its own type buy, compared with a plain `string`? | | |
| 1 | Why are the allowed transitions a map instead of `if` statements? | | |
| 2 | Why does `jobs` define `Repository`, not `memstore`? Which way does the dependency point? | | |
| 2 | Why store jobs by value instead of by pointer? | | |
| 2 | Read your race report: which line, which goroutines, read or write? | | |
| 3 | Draw the check-then-act race in `Run`. Why doesn't the mutex prevent it? | | |
| 3 | Why does `go test -race` pass when the compare-and-swap is removed? | | |
| 3 | What would happen without `context.WithoutCancel` in the final `Update`? | | |
| 4 | Why does `httpapi` define its own `JobService` interface? | | |
| 4 | Give one request that returns each of 400, 404, 405, 409, 413 and 415, and say why | | |
| 5 | What is the composition root? What does `ReadHeaderTimeout` defend against? | | |
| 6 | Trace a client disconnect from the socket to `Simulate` | | |
| 6 | 504 vs a client timeout: what does the server see in each case, and what does it record? | | |
| 7 | Why log and label by route pattern instead of path? | | |
| 7 | Name the golden signals and which metric gives each one | | |
| 7 | Why did moving `withTimeout` inside the logger turn every route into `unmatched`? | | |
| 8 | SIGINT, SIGTERM, SIGKILL: which can a program handle? | | |
| 8 | Why is the shutdown context built from `context.Background()`? | | |
| 8 | What does graceful shutdown **not** protect against? | | |

## Evidence checklist

| Claim | Command or test | Result |
|---|---|---|
| Create, get and run work end to end | | |
| Every row of the contract table has a test | | |
| A data race was caught by `-race`, then fixed | | |
| The lost-update test fails without compare-and-swap and passes with it | | |
| A slow run returns 504 and the job is stored as `failed` | | |
| A client disconnect leaves the job `failed` with reason `cancelled` | | |
| `/metrics` shows counts by route and code | | |
| Graceful shutdown let an in-flight request finish | | |
| Restarting the process loses every job (and I can explain why) | | |

## Rebuild from memory

- What I rebuilt without help:
- What I had to look up, and where:
- How my design differs from the guide, and why:
- What is still unclear:
