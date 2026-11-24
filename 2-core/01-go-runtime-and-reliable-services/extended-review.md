# Core 01 · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 05: The domain, written test-first

1. What is an entity, and what is a value object? Classify `Job`, `Description`, `ID` and `State`.
2. Draw the job state machine. Which transitions are legal?
3. Predict: what does `Job{State: StateFailed}.CanTransitionTo(StateRunning)` return, and why, without any special code for failed jobs?
4. Why does `New` take `now time.Time`? What test would be impossible otherwise?
5. What is the difference between `errors.Is` and `errors.As`? When do you need `As`?
6. What does `fmt.Errorf("%w: %w", a, b)` let a caller do?

### Lesson 06: A repository, and your first data race

7. Why is `Repository` declared in `jobs` and not in `memstore`? What breaks if you move it?
8. What is a port, and what is an adapter? Name one of each in this code.
9. What is a goroutine? How is it different from a process?
10. Define a data race. Why can't you trust a test that passes without `-race`?
11. What does `RWMutex` allow that `Mutex` doesn't?
12. Why does `Get` return a copy of the job? What could go wrong if the map held pointers?
13. Predict: you delete the lock in `Create` and run the test **without** `-race`. Does it pass? Then with `-race`?
14. What do `sync.WaitGroup`, a buffered channel and `close` each do in `TestConcurrentCreateIDsAreUnique`?

### Lesson 07: A race a mutex can't fix

15. Explain functional options. Write the signature of an option that sets a field called `maxRuns`.
16. Explain the check-then-act race in `Run` with a sequence diagram.
17. Why doesn't the race detector catch the check-then-act race?
18. How does compare-and-swap fix it? What does the second caller get?
19. Why does the concurrency test need `slowGetRepository`? What does that teach about real races?

### Lesson 08: The HTTP API

20. Why does `httpapi` define its own `JobService` interface instead of taking `*jobs.Service`?
21. Why does `jobResponse` exist when `jobs.Job` already has the same fields?
22. What do `GET /jobs/{id}` and `r.PathValue("id")` do? What does the router return for `DELETE /jobs/1`, and which header does it add?
23. List the five checks `decodeJSON` makes, and the status code each one produces.
24. Predict: `curl -X POST .../jobs -d '{"description":"x"}'` with no `-H`. Which status, and why?
25. Predict: `{"description":"x"}{"description":"y"}`. Which status, and which line catches it?
26. When is 409 the right status, and when is 400?
27. Why does an unexpected error return `"internal error"` instead of the real message?

### Lesson 09: Wiring and configuration

28. Name the four layers of the service and the package for each. Which may import which?
29. What is the composition root, and where is it? Why does nothing else call `memstore.New()`?
30. Why does `run` take `getenv`, `stdout`, `ctx` and `ready` as parameters?

### Lesson 10: Deadlines and cancellation

31. What does `context.WithTimeout(parent, 2*time.Second)` return, and when is it cancelled?
32. Trace a client hang-up from the TCP connection to `Simulate`. What gets recorded on the job?
33. Predict: `REQUEST_TIMEOUT=1s`, and a job with `duration_ms: 3000`. Status, state, failure reason and roughly how long it takes?
34. Predict the same request if `Simulate` used `time.Sleep` instead of `select`.
35. Why does the final `Update` use `context.WithoutCancel(ctx)`? What state would the job be stuck in without it?
36. What happens if you forget to call the `cancel` function `WithTimeout` gives you?

### Lesson 11: Logs, metrics and panic recovery

37. What makes a log "structured"? Give three fields this service logs and two it must never log.
38. Counter vs histogram: which is which in this service, and what question does each answer?
39. What is label cardinality? Why use `GET /jobs/{id}` and not `/jobs/17` as a label?
40. Name the four golden signals and where each one comes from in this service.
41. Explain why `withTimeout` must be outside the logging middleware.
42. What does `withRecover` protect against? What does it **not** protect against?

### Lesson 12: Signals and graceful shutdown

43. SIGINT vs SIGTERM vs SIGKILL: who sends each, and which can the program catch?
44. List what `server.Shutdown` does, in order. How is `Close` different?
45. Predict what the in-flight client sees if `Shutdown` is replaced by `Close`.
46. Why is the shutdown context derived from `context.Background()` and not from `ctx`?
47. Why must `SHUTDOWN_GRACE` be shorter than Kubernetes' termination grace period?
48. What are file descriptors 0, 1 and 2? What appears for the listening socket in `/proc/PID/fd`?

### Lesson 13: Worker pools and backpressure

49. What's the difference between synchronous and asynchronous work, from the caller's point of view?
50. State Little's law. With 2 workers and 500 ms jobs, what's the maximum throughput? If 10 jobs a second arrive, how quickly does the queue grow?
51. Why is an unbounded queue a bug, not a feature?
52. Predict: one worker, a queue of 2, and five 1-second jobs sent at once. What are the five status codes, and why?
53. When several `select` cases are ready, what does Go do? What bug did that cause, and how was it fixed?
54. Why did lesson 13's shutdown need two contexts? What does each one mean?
55. What's a gauge, and why is queue depth one?

### Lesson 14: Timeouts, retries and idempotency

56. A client's `POST /jobs` times out. Why can't it simply retry without a key?
57. Predict the response to: the same key and same body twice; the same key and a different body; the same key while the first request is still running.
58. Why aren't 5xx responses remembered?
59. Why does a replay still say `queued` after the job completed?
60. List the three sources of duplicates and the defence against each.
61. Transient or permanent: a timeout, a 400, a 503, an unreadable message, a context deadline. Why?
62. With base 100 ms and max 1 s, what's the ceiling before retries 1 to 5? What's the actual wait with full jitter?
63. Why does jitter matter when a thousand clients fail together?
64. Why do retries happen *inside* the job deadline?

### Lesson 15: gRPC and Protocol Buffers

65. Why can a protobuf field be renamed but not renumbered?
66. Map `InvalidArgument`, `NotFound` and `Unavailable` to HTTP statuses.
67. How does a client's deadline reach a gRPC server?

### The whole module

68. A job's state says `running` and has for an hour. List three possible causes in this codebase, and which test would catch each.
69. Rebuild lessons 05–12 from the contract table in under four hours, test-first. Which parts did you have to look up?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 05 | Why do the domain functions take `now` as a parameter instead of calling `time.Now()`? | | |
| 05 | What does making `Description` its own type buy, compared with a plain `string`? | | |
| 05 | Why are the allowed transitions a map instead of `if` statements? | | |
| 06 | Why does `jobs` define `Repository`, not `memstore`? Which way does the dependency point? | | |
| 06 | Why store jobs by value instead of by pointer? | | |
| 06 | Read your race report: which line, which goroutines, read or write? | | |
| 07 | Draw the check-then-act race in `Run`. Why doesn't the mutex prevent it? | | |
| 07 | Why does `go test -race` pass when the compare-and-swap is removed? | | |
| 07 | What would happen without `context.WithoutCancel` in the final `Update`? | | |
| 08 | Why does `httpapi` define its own `JobService` interface? | | |
| 08 | Give one request that returns each of 400, 404, 405, 409, 413 and 415, and say why | | |
| 09 | What is the composition root? What does `ReadHeaderTimeout` defend against? | | |
| 10 | Trace a client disconnect from the socket to `Simulate` | | |
| 10 | 504 vs a client timeout: what does the server see in each case, and what does it record? | | |
| 11 | Why log and label by route pattern instead of path? | | |
| 11 | Name the golden signals and which metric gives each one | | |
| 11 | Why did moving `withTimeout` inside the logger turn every route into `unmatched`? | | |
| 12 | SIGINT, SIGTERM, SIGKILL: which can a program handle? | | |
| 12 | Why is the shutdown context built from `context.Background()`? | | |
| 12 | What does graceful shutdown **not** protect against? | | |
| 13 | Use Little's law: with 4 workers, 1 s jobs and 10 arrivals a second, how fast does the queue grow, and when is a 100-slot queue full? | | |
| 13 | Why 503 and not 429? Why refuse instead of waiting? | | |
| 13 | What did `-count=20` reveal about `select`? | | |
| 14 | Why must claiming a key and checking it happen under one lock? | | |
| 14 | Name the three sources of duplicates and the defence against each | | |
| 14 | Why jitter? Why stop retrying at the deadline? | | |
| 15 | Why are protobuf field numbers permanent? | | |
| 15 | Map three gRPC codes to the HTTP statuses this API uses | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
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
| A full queue returns 503 and records the job as failed | | |
| A retried `POST /jobs` with one key creates one job | | |
| Retries rescue most jobs at `FAIL_RATE=0.5` | | |
| gRPC and HTTP serve the same job | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
