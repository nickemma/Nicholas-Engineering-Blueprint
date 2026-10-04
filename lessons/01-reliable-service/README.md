# Phase 1: make one service reliable

**Question:** what happens when requests overlap, stall, contain bad input, or arrive while the process is stopping?

**Time:** about 4 weeks. **Prerequisites:** [Phase 0](../00-request-service/README.md), including its exercise.

## Syllabus

| Step | Topic | You'll learn |
|---|---|---|
| 1 | The domain, test-first | State machines, entities and value objects, sentinel errors and wrapping, methods and receivers, TDD as the default |
| 2 | A repository and a data race | Interfaces, ports and adapters, goroutines, shared memory, data races, mutexes, the race detector, channels, `WaitGroup` |
| 3 | The service and a race a mutex can't fix | Use cases, dependency injection, functional options, `select`, check-then-act races, compare-and-swap, `context.WithoutCancel` |
| 4 | The HTTP API | Method-aware routes, strict JSON decoding, 201/400/404/405/409/413/415, consumer-defined interfaces, error mapping |
| 5 | The composition root | Wiring in `main`, configuration from the environment, server timeouts, failing fast |
| 6 | Deadlines and cancellation | `context.WithTimeout`, the context tree, middleware, 504 vs client timeouts |
| 7 | Logs, metrics and recovery | Structured logs, what not to log, Prometheus counters and histograms, label cardinality, golden signals, middleware order |
| 8 | Signals and graceful shutdown | SIGINT, SIGTERM and SIGKILL; `Shutdown` vs `Close`; grace periods; file descriptors and `/proc` |

## What you'll be able to do

- Structure a Go service in layers and explain which package may depend on which.
- Use interfaces as ports, inject dependencies through constructors, and wire them in one composition root.
- Model rules as a state machine with entities and value objects.
- Cause, detect and fix a data race; explain why a mutex doesn't fix check-then-act races, and fix one with compare-and-swap.
- Reject hostile input precisely.
- Propagate deadlines and cancellation, and keep the record honest when work is cancelled.
- Emit structured logs and metrics with sensible labels.
- Shut down gracefully, and say what that does and doesn't protect.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md) in order, typing every piece of code yourself.
2. Answer [learned.md](learned.md) as you go.
3. Rebuild the service from memory in your own `kestrel` repository.
4. Build the exercise project, **[shortlinks](exercises.md)**, a URL shortener, on your own. The exercise page shows exactly what the finished service does.
5. Take the [self-test](../../notes/learned/01-reliable-service.md).

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where in the lesson | Evidence you'll have |
|---|---|---|
| Code organisation and design patterns (row 6) | Steps 1–5 and shortlinks | Two layered services |
| Processes, signals, file descriptors (row 7) | Step 8 | SIGTERM shutdown log; a `/proc/PID/fd` listing |
| Concurrency, locks, races (row 8) | Steps 2–3 and shortlinks | A race report, then a clean run; lost-update and alias-race tests |
| Testing and TDD (row 5) | Every step | Tests written first; deliberate failures |
| API security habits (row 28) | Step 4 | 400/413/415 table tests |
| Observability, first steps (row 23) | Step 7 | `/metrics` output and JSON logs |

## Patterns introduced

These link to the [patterns ledger](../../JOURNEY.md#6-patterns-ledger): layered architecture; ports and adapters; repository; dependency injection with a composition root; functional options; entity, value object and state machine (tactical DDD); optimistic concurrency (compare-and-swap); middleware and decorator; timeouts and deadline propagation; graceful shutdown.

## Next

Every job still lives inside one process, and running one ties up the caller's request until it finishes. The [Python Bridge](../python-bridge/README.md) first teaches you to *measure* this service. [Phase 2](../02-connected-services/README.md) then moves the work to separate workers behind a queue.
