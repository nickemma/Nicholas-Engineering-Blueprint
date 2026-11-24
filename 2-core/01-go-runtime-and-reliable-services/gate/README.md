# Gate: Go runtime and reliable services

## What it checks

Your folder is `~/blueprint/switchyard`, the Go module you built from lesson 03 onwards, with the control plane in `cmd/switchyard` and the worker in `cmd/worker` (lesson 16).

The gate builds both with `-race`. It starts the control plane with `LEASE_TTL=1s`, `SHUTDOWN_GRACE=5s` and `QUEUE_CAPACITY=20000`, on ports 18080 (HTTP) and 19090 (gRPC), and starts four workers. Then:

1. `gofmt -l .` lists nothing, and `go vet` and `go test -race` are clean.
2. 32 clients send **10,000 state changes** at once: new jobs of up to 20 ms each, every one with an `Idempotency-Key`; about a quarter of them sent again with the same key (a client that never heard the answer); and cancels of the client's own jobs. A `503` or `409` on a create is retried with the same key.
3. While that runs, a worker is **killed with SIGKILL** every one to two seconds and a new one started in its place. The first victim is instead **paused with SIGSTOP** for 2.5 seconds, longer than its lease, and then resumed: it comes back holding a job that has been given to someone else.
4. When the load has stopped, the gate waits up to 90 seconds for the state to **converge**, then checks:
   - every request got an answer it allows: `201` for a create, `200` for a cancel, or `409` for cancelling a job that has already finished;
   - every repeated request returned the same job as the first;
   - every job reached a final state: none lost, none stuck in `queued` or `running`;
   - every job whose cancel got `200` ended `cancelled`, never `completed`;
   - every completed job has exactly one effect (`GET /effects/{id}`), and every other job has none.
5. `go_goroutines` on `/metrics` comes back to within 3 of what it was before the load.
6. SIGTERM to the control plane and every worker stops all of them within 7 seconds, and the control plane exits with status 0.
7. The race detector reported nothing in any process's output.

## Run it

~~~bash
bash gate/run.sh ~/blueprint/switchyard
~~~

It needs Go and `curl`, and nothing else listening on port 18080. It takes about a minute when it passes, and up to three when jobs get stuck, because it waits 90 seconds for them to settle. The numbers (jobs, cancels, kills) differ on every run.

## A pass looks like

~~~text
PASS  gofmt -l . lists nothing
PASS  go vet ./...
PASS  go test -race ./...
sending 10,000 state changes from 32 clients while workers are killed; this takes a minute or two
sent 10000 state changes in 1.8 s: 7064 creates, 1659 repeated with the same key, 1277 cancels (1026 accepted)
settled after 21.8 s: 7064 jobs: 6038 completed, 1026 cancelled, 0 failed
PASS  every request got an expected answer
PASS  a repeated request with the same key returned the same job
PASS  every job reached a final state (none lost, none stuck)
PASS  every job cancelled with 200 ended cancelled, never completed
PASS  every completed job has exactly one effect; every other job, none
      workers killed with SIGKILL: 15; one paused past its lease
      jobs handed back by the reconcile loop: 10
PASS  goroutines came back to the baseline (28 before, 28 after)
PASS  SIGTERM stopped the control plane and every worker within the grace period (1 s)
PASS  the race detector reported nothing

gate passed
~~~

Fifteen workers were killed and ten jobs were handed on to another worker (a worker killed between jobs holds nothing to hand on). Every job still finished, and every effect happened once.

## A fail looks like

Each of these is one small change to the finished code (the diffs are in [evidence/gate/broken/](../evidence/gate/broken/)). Only the lines that changed from a pass are shown.

**The idempotency middleware isn't wired in** (`httpapi.WithIdempotency(keys)` left out of `main.go`). Every test passes, because the middleware's own tests don't know whether `main` uses it. Under load, a retried `POST` creates a second job:

~~~text
FAIL  a repeated request with the same key returned the same job
        key gate-2-0: first job 4, retry got job 16 (replayed=false, err=<nil>)
        key gate-14-0: first job 6, retry got job 21 (replayed=false, err=<nil>)
        key gate-5-0: first job 17, retry got job 20 (replayed=false, err=<nil>)
        ...
~~~

The effects check still passes here: each duplicate job is a separate job with its own effect. That's the point of lesson 14: the ledger stops one job running its effect twice, but only the idempotency key stops a client making two jobs.

**The reconcile loop never runs** (`coordinator.Run` replaced by waiting for shutdown). A killed worker's lease is never noticed, so its job stays `running` for ever. The gate waits the full 90 seconds:

~~~text
settled after 92.0 s: 7101 jobs: 6072 completed, 1016 cancelled, 0 failed
FAIL  every job reached a final state (none lost, none stuck)
        job 4427 is running
        job 3844 is running
        job 2421 is running
        ...
      jobs handed back by the reconcile loop: 0
~~~

**A cancelled job is allowed to complete** (`StateCancelled: {StateCompleted}` added to the transition table). The module's own tests catch it first, and the load shows the result: a client was told "cancelled", and the work happened anyway:

~~~text
FAIL  go test -race ./...
      --- FAIL: TestFinalStates (0.00s)
          job_test.go:125: Final() for cancelled = false, want true
      --- FAIL: TestCancelledJobGetsNoEffect (0.00s)
          service_test.go:71: Finish after Cancel error = <nil>, want ErrInvalidTransition
      ...
FAIL  every job cancelled with 200 ended cancelled, never completed
        job 17 was cancelled (200), but ended completed
        job 59 was cancelled (200), but ended completed
        ...
~~~

**A data race** (`Coordinator.Stats` reads its maps without taking the lock). No test calls `Stats` while leases change, so `go test -race` passes. Under load, `/metrics` reads them while a worker takes a lease, the race detector reports it, and a program built with `-race` that found a race exits with status 66 instead of 0:

~~~text
FAIL  SIGTERM stops everything within the grace period
      control plane exit status 66 after 2 s (grace 5 s)
FAIL  the race detector reported nothing
      in control-plane.log:
      WARNING: DATA RACE
      Read at 0x00c000266900 by goroutine 77:
        switchyard/internal/coord.(*Coordinator).Stats()
            /tmp/gate-race/internal/coord/coord.go:277 +0x51
        main.run.func4()
            /tmp/gate-race/cmd/switchyard/main.go:154 +0x12
        ...
~~~

**A goroutine leak** (`Lease` starts a goroutine that waits for shutdown, one per call). Everything works, and every job converges; only the count gives it away:

~~~text
FAIL  goroutines came back to the baseline
      before the load: 36; 15 s after it: 6173. Something starts goroutines that never end.
~~~

What the other checks usually mean when they fail:

- **A request got an answer it doesn't allow**: a handler that returns `500` for a state conflict, or a `201` for a repeat that should have been replayed.
- **A completed job has 2 effects**: the effect is recorded when the worker finishes rather than when the control plane accepts the report, so a worker whose lease was lost still records it (lesson 16, step 4).
- **SIGTERM took longer than 7 seconds**: a worker that doesn't stop leasing on SIGTERM, or a control plane whose long-poll `Lease` calls don't end when it shuts down.
