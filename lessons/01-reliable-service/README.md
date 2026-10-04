# Phase 1: make one service reliable

**Question:** what happens when requests overlap, stall, contain bad input, or arrive while the process is stopping?

**You build:** a jobs API (`POST /jobs`, `GET /jobs/{id}`, `POST /jobs/{id}/run`). It's layered as domain → service → repository → HTTP, built test-first, and has strict input handling, compare-and-swap updates, request deadlines, structured logs, Prometheus metrics and graceful shutdown.

**Time:** about 4 weeks. **Prerequisites:** [Phase 0](../00-request-service/README.md).

| File | Use it for |
|---|---|
| [TEACHING.md](TEACHING.md) | The lesson. Follow it in order |
| [steps/](steps) | Eight runnable snapshots. `08-graceful-shutdown` is the finished service |
| [exercises.md](exercises.md) | Test-driven exercises for after the checkpoint |
| [learned.md](learned.md) | Your answer sheet |

## What you'll be able to do

- Structure a Go service in layers and explain which package may depend on which.
- Use interfaces as ports, inject dependencies through constructors, and wire them in one composition root.
- Model rules as a state machine with entities and value objects.
- Explain goroutines and shared memory; cause, detect and fix a data race.
- Explain why a mutex doesn't fix check-then-act races, and fix one with compare-and-swap.
- Reject hostile input precisely: content type, size, unknown fields, trailing data.
- Propagate deadlines and cancellation with `context`, and keep the record honest when work is cancelled.
- Emit structured logs and Prometheus metrics with sensible labels; recover from panics.
- Handle SIGTERM with a graceful shutdown, and say what that does and doesn't protect.

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where in the lesson | Evidence you'll have |
|---|---|---|
| Code organisation and design patterns (row 6) | Steps 1–5 | The layered service; the `slowGetRepository` test |
| Processes, signals, file descriptors (row 7) | Step 8 | SIGTERM shutdown log; `/proc/PID/fd` listing |
| Concurrency, locks, races (row 8) | Steps 2–3 | A race report, then a clean run; the lost-update test |
| Testing and TDD (row 5) | Every step | Tests written first; deliberate failures |
| API security habits (row 28) | Step 4 | 400/413/415 table tests |
| Observability, first steps (row 23) | Step 7 | `/metrics` output and JSON logs |

## Patterns introduced

These link to the [patterns ledger](../../JOURNEY.md#6-patterns-ledger):

- **Layered architecture** and **ports and adapters**: `jobs` defines `Repository`; `memstore` implements it.
- **Repository**: `jobs.Repository`.
- **Dependency injection** with a **composition root**: `NewService(repo, ...)`, wired in `cmd/api/main.go`.
- **Functional options**: `WithClock`, `WithWork`, `WithLogger`, `WithMetrics`, `WithRequestTimeout`.
- **Entity, value object, state machine** (tactical DDD): `Job`, `Description`, `allowed`.
- **Optimistic concurrency** (compare-and-swap): `Update(ctx, job, expected)`.
- **Middleware / decorator**: `withTimeout`, `withRequestLog`, `withRecover`, `slowGetRepository`.
- **Timeouts and deadline propagation**, and **graceful shutdown**.

## Run the finished service

~~~bash
cd lessons/01-reliable-service/steps/08-graceful-shutdown
go test -race ./...
go run ./cmd/api
~~~

In a second terminal:

~~~bash
curl -i -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"hello","duration_ms":200}'
~~~

## Next

Every job still lives inside one process, and running one ties up the caller's request until it finishes. The [Python Bridge](../python-bridge/README.md) first teaches you to *measure* this service under load. [Phase 2](../02-connected-services/README.md) then moves the work to a separate worker behind a queue.
