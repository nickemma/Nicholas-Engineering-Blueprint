# Phase 1 self-test

Answer from memory, then check yourself against [the lesson](../../lessons/01-reliable-service/TEACHING.md) and the [snapshots](../../lessons/01-reliable-service/steps). Write each "predict" answer before running anything.

## A. Layers and design

1. Name the four layers of the service and the package for each. Which may import which?
2. Why is `Repository` declared in `jobs` and not in `memstore`? What breaks if you move it?
3. What is a port, and what is an adapter? Name one of each in this code.
4. What is the composition root, and where is it? Why does nothing else call `memstore.New()`?
5. Explain functional options. Write the signature of an option that sets a field called `maxRuns`.
6. Why does `httpapi` define its own `JobService` interface instead of taking `*jobs.Service`?
7. What is an entity, and what is a value object? Classify `Job`, `Description`, `ID` and `State`.
8. Why does `jobResponse` exist when `jobs.Job` already has the same fields?

## B. The domain

9. Draw the job state machine. Which transitions are legal?
10. Predict: what does `Job{State: StateFailed}.CanTransitionTo(StateRunning)` return, and why, without any special code for failed jobs?
11. Why does `New` take `now time.Time`? What test would be impossible otherwise?
12. What is the difference between `errors.Is` and `errors.As`? When do you need `As`?
13. What does `fmt.Errorf("%w: %w", a, b)` let a caller do?

## C. Concurrency

14. What is a goroutine? How is it different from a process?
15. Define a data race. Why can't you trust a test that passes without `-race`?
16. What does `RWMutex` allow that `Mutex` doesn't?
17. Why does `Get` return a copy of the job? What could go wrong if the map held pointers?
18. Predict: you delete the lock in `Create` and run the test **without** `-race`. Does it pass? Then with `-race`?
19. Explain the check-then-act race in `Run` with a sequence diagram.
20. Why doesn't the race detector catch the check-then-act race?
21. How does compare-and-swap fix it? What does the second caller get?
22. Why does the concurrency test need `slowGetRepository`? What does that teach about real races?
23. What do `sync.WaitGroup`, a buffered channel and `close` each do in `TestConcurrentCreateIDsAreUnique`?

## D. HTTP and input

24. What do `GET /jobs/{id}` and `r.PathValue("id")` do? What does the router return for `DELETE /jobs/1`, and which header does it add?
25. List the five checks `decodeJSON` makes, and the status code each one produces.
26. Predict: `curl -X POST .../jobs -d '{"description":"x"}'` with no `-H`. Which status, and why?
27. Predict: `{"description":"x"}{"description":"y"}`. Which status, and which line catches it?
28. When is 409 the right status, and when is 400?
29. Why does an unexpected error return `"internal error"` instead of the real message?

## E. Deadlines and cancellation

30. What does `context.WithTimeout(parent, 2*time.Second)` return, and when is it cancelled?
31. Trace a client hang-up from the TCP connection to `Simulate`. What gets recorded on the job?
32. Predict: `REQUEST_TIMEOUT=1s`, and a job with `duration_ms: 3000`. Status, state, failure reason and roughly how long it takes?
33. Predict the same request if `Simulate` used `time.Sleep` instead of `select`.
34. Why does the final `Update` use `context.WithoutCancel(ctx)`? What state would the job be stuck in without it?
35. What happens if you forget to call the `cancel` function `WithTimeout` gives you?

## F. Observability

36. What makes a log "structured"? Give three fields this service logs and two it must never log.
37. Counter vs histogram: which is which in this service, and what question does each answer?
38. What is label cardinality? Why use `GET /jobs/{id}` and not `/jobs/17` as a label?
39. Name the four golden signals and where each one comes from in this service.
40. Explain why `withTimeout` must be outside the logging middleware.
41. What does `withRecover` protect against? What does it **not** protect against?

## G. Process lifecycle

42. SIGINT vs SIGTERM vs SIGKILL: who sends each, and which can the program catch?
43. List what `server.Shutdown` does, in order. How is `Close` different?
44. Predict what the in-flight client sees if `Shutdown` is replaced by `Close`.
45. Why is the shutdown context derived from `context.Background()` and not from `ctx`?
46. Why must `SHUTDOWN_GRACE` be shorter than Kubernetes' termination grace period?
47. What are file descriptors 0, 1 and 2? What appears for the listening socket in `/proc/PID/fd`?
48. Why does `run` take `getenv`, `stdout`, `ctx` and `ready` as parameters?

## H. Explain it whole

49. A job's state says `running` and has for an hour. List three possible causes in this codebase, and which test would catch each.
50. Rebuild Phase 1 from the contract table in under four hours, test-first. Which parts did you have to look up?
