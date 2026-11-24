# 01 Go runtime and reliable services

> The core · Time: 7 weeks at 12–15 hours a week · Builds on: [Foundations 03](../../1-foundations/03-go-from-zero/README.md) and [04](../../1-foundations/04-python-and-the-internet-from-zero/README.md), or the [test-out](../../1-foundations/test-out/README.md) · Status: ready

## What you'll learn

How Go runs your code (the scheduler, goroutine stacks, escape analysis, the garbage collector), and how to build a service that stays correct when requests overlap, stall, fail, repeat, or arrive while it's stopping. Every lesson names the failure first, causes it on purpose, then fixes it and proves the fix with a test.

## What you'll build

**Switchyard's control plane, version 1:** a Go jobs service. Clients submit jobs over HTTP and gRPC; a domain enforces each job's rules; a bounded pool of workers runs them; deadlines, retries and idempotency keys keep it honest; it logs, counts and shuts down cleanly. At the end, workers run as separate processes, and a **reconciliation loop** keeps the world matching what was asked for, however many workers die.

## Lessons

| # | Lesson | What it teaches | Time |
|---|---|---|---|
| 01 | [How Go runs your code](lessons/01-how-go-runs-your-code.md) | The G-M-P scheduler and preemption, seen with `GODEBUG=schedtrace`; goroutine stacks that grow; escape analysis (`-gcflags=-m`): stack vs heap; the garbage collector, `GOGC` and `GOMEMLIMIT`, seen with `gctrace`; `runtime/trace`. Drills, measured | ~6 h |
| 02 | [HTTP/1.1 by hand](lessons/02-http-1-1-by-hand.md) | Starting from Foundations 04's echo server: parse a request line, headers and a `Content-Length` body from a `net.Conn`, write a response, keep the connection alive for the next request; then the same with `net/http`, and what it does for you (and the limits you must set) | ~5 h |
| 03 | [An HTTP service with a contract](lessons/03-an-http-service-with-a-contract.md) | `switchyard` starts: `net/http`, a JSON response contract, a router with method-aware routes, a greeting endpoint with input validation, health | ~5 h |
| 04 | [Tests at three levels, and CI](lessons/04-tests-at-three-levels-and-ci.md) | Handler tests with `httptest`, a routing table test, a test over a real connection; what each level proves; TDD; your own repository and a GitHub Actions workflow | ~5 h |
| 05 | [The domain, written test-first](lessons/05-the-domain-written-test-first.md) | The job state machine as data; entities and value objects; sentinel and wrapped errors; table-driven TDD | ~5 h |
| 06 | [A repository, and your first data race](lessons/06-a-repository-and-your-first-data-race.md) | Interfaces as ports; an in-memory repository; a race caught by `-race`; a mutex; why copies on the way out matter | ~5 h |
| 07 | [A race a mutex can't fix](lessons/07-a-race-a-mutex-cant-fix.md) | Use cases and dependency injection; check-then-act races; compare-and-swap with a version | ~5 h |
| 08 | [The HTTP API](lessons/08-the-http-api.md) | Strict JSON decoding; 201, 400, 404, 405, 409, 413, 415; mapping domain errors to status codes | ~5 h |
| 09 | [Wiring and configuration](lessons/09-wiring-and-configuration.md) | The composition root; configuration from the environment; server timeouts; failing fast; functional options | ~4 h |
| 10 | [Deadlines and cancellation](lessons/10-deadlines-and-cancellation.md) | `context`, the context tree, middleware; 504 vs a client timeout; keeping the record honest when work is cancelled | ~5 h |
| 11 | [Logs, metrics and panic recovery](lessons/11-logs-metrics-and-panic-recovery.md) | Structured logs and what not to log; Prometheus counters and histograms; label cardinality; middleware order | ~5 h |
| 12 | [Signals and graceful shutdown](lessons/12-signals-and-graceful-shutdown.md) | SIGINT, SIGTERM, SIGKILL; `Shutdown` vs `Close`; a grace period; what it does and doesn't protect | ~4 h |
| 13 | [Worker pools and backpressure](lessons/13-worker-pools-and-backpressure.md) | Accept now, run later; a bounded queue; 503 when it's full; Little's law, measured with a load generator of your own; stopping workers cleanly | ~6 h |
| 14 | [Timeouts, retries and idempotency](lessons/14-timeouts-retries-and-idempotency.md) | Retries with backoff and jitter; idempotency keys for `POST`, with an expiry sweep; why a retried job mustn't run its effect twice: an effect ledger, and failures injected on purpose | ~6 h |
| 15 | [gRPC and Protocol Buffers](lessons/15-grpc-and-protocol-buffers.md) | A `.proto` contract; generated code; a gRPC server next to HTTP; a client; deadlines over gRPC | ~5 h |
| 16 | [The reconciliation loop](lessons/16-the-reconciliation-loop.md) | Desired vs actual state; workers as separate processes that report in over gRPC; leases and heartbeats; fencing tokens; cancelling a running job; a loop that notices a dead worker and hands its jobs on; the pattern behind Kubernetes controllers | ~7 h |

**Absorbs** the old Phase 0 steps 3–7, Phase 1 steps 1–8, and Phase 2 steps 1, 4 and 6 and step 5's retries, all without RabbitMQ. Lessons 01, 02 and 16 are new.

**Not here any more:** RabbitMQ, message versioning, dead letters and the circuit breaker (the *Messaging and resilience* unit); looking at the wire with `ss` and `tcpdump` (core 06).

## The gate

`gate/run.sh` builds your control plane and worker with `-race`, starts the control plane and four workers, and then:

1. Sends **10,000 state changes** from 32 clients at once: jobs created, created again with the same idempotency key (a client that didn't hear the answer), and cancelled.
2. **Kills workers with SIGKILL** every second or two while that's happening, starting a new one each time, and pauses one with SIGSTOP for longer than its lease.
3. Waits, then checks that the state **converged**: every job reached a final state, none was lost, a repeated request returned the same job, a cancelled job never completed, and every completed job had its effect exactly once (`GET /effects/{id}`).
4. Checks that the race detector reported nothing, that the goroutine count (`go_goroutines`) came back to its baseline, and that SIGTERM stops the control plane and every worker within the grace period.
5. `gofmt`, `go vet` and `go test -race` are clean.

The [gate's page](gate/README.md) shows a pass and each kind of fail.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Build an HTTP service with tests at three levels, and find a data race with `-race` |
| Intermediate | Explain why a mutex doesn't fix check-then-act, propagate deadlines, and make a `POST` safe to retry |
| Senior | Design a reconciliation loop that converges when workers die, and say what the scheduler and the GC cost your service |

## Practice

- [Exercises](exercises.md): `tempconv`, a temperature-conversion service (after lesson 04), and `shortlinks`, a URL shortener that must never give an alias out twice or lose a visit (after lesson 12).
- [Self-check](self-check.md): explain-it questions per lesson, then a test from memory.

## Next

[02 Python runtime and honest measurement](../02-python-runtime-and-honest-measurement/README.md): a load generator that measures this service without lying.

---

<sub>The raw runs behind this module's outputs and its gate are in [evidence/](evidence/README.md). You don't need them to follow the lessons.</sub>
