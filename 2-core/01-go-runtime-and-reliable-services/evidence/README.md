# Evidence: Go runtime and reliable services

Real outputs behind the lessons and the gate, captured on 2026-11-19 with Go 1.27.4.

## How they were captured

All runs used [Dockerfile](Dockerfile): a fresh Ubuntu 24.04 with the Foundations tools and an ordinary user, `ada`, on a 16-CPU x86-64 machine running WSL2. Each script installs Go from go.dev, as Foundations 01 does, and works in `~/blueprint/switchyard`, putting each lesson's code in place as the lessons build it. Commits use Foundations' example identity, Ada Lovelace.

- **`lessons/`** holds one file per command the lessons show, named by lesson and step (`1304-overload.txt` is lesson 13's fourth capture). Each file has the command, its output and its exit status. Times, PIDs, ports, addresses and memory figures differ on every run.
- The scripts, in the order they ran: [capture-01-02.sh](capture-01-02.sh), [capture-03-04.sh](capture-03-04.sh), [capture-05-12.sh](capture-05-12.sh), [capture-13.sh](capture-13.sh), [capture-14.sh](capture-14.sh), [capture-15.sh](capture-15.sh) and [capture-16.sh](capture-16.sh). Four were reruns of a few files:
  - [capture-01b.sh](capture-01b.sh) added `0107b-time.txt`, the CPU and memory cost of each `GOGC` setting;
  - [capture-10.sh](capture-10.sh) recaptured lesson 10's last step with both requests against one server, as the lesson runs them;
  - [capture-11-12.sh](capture-11-12.sh) recaptured lessons 11 and 12 after the first run showed `go get` alone leaves `go.sum` incomplete (lesson 11 now runs `go mod tidy` after it);
  - [capture-16b.sh](capture-16b.sh) recaptured `1604-notoken.txt` after the deliberate mistake was corrected to the one the lesson describes.
- Each deliberate mistake in [mistakes/](mistakes/) is the file as it was broken, named by lesson. The scripts lay it over the code, run the command, and put the real file back. Every capture has a two-minute limit, and anything left running is stopped before the next.
- Lesson 16's worker logs (`1601-kill.txt`, `1602-pause.txt`) show only the lines about the job being followed, with the timestamps removed; the command that produced them is in [capture-16.sh](capture-16.sh).

## Findings while building the module

- **`GOGC` trades memory for CPU, and not only in the collector.** The same allocation drill under `GOGC=50` used 30 MB of memory at most and 0.08 s of system time; under `GOGC=400`, 228 MB and 0.16 s. The extra system time is the kernel handing the bigger heap fresh pages. Under `GOGC=off` the drill finished in 0.02 s with 7 MB: the garbage was never touched again, so the pages were never needed ([0107b-time.txt](lessons/0107b-time.txt)). With an address-space limit, the same drill dies with `fatal error: out of memory` ([0111-oom.txt](lessons/0111-oom.txt)).
- **`GODEBUG=gctrace=1 go run` traces the `go` command too.** The `go` tool is a Go program, so its own collections came first in the output. The lesson builds the drill and runs the binary instead.
- **The default `http.Server` has no timeouts.** A client that sent half a request header and stopped kept its connection for the full 6 seconds the test allowed; with `ReadHeaderTimeout: 2 * time.Second` the server closed it after 2 s and sent nothing ([0206-slow.txt](lessons/0206-slow.txt)).
- **Go raises its own open-files limit.** The running service's soft limit was 1,048,575, one under the hard limit: the runtime raises it at start, so a shell's `ulimit -n` (often 1,024) understates what a Go server can hold. Its file descriptor 3 is `/sys/fs/cgroup/cpu.max`, which the runtime reads to size `GOMAXPROCS` to the container's CPU quota ([1203-proc.txt](lessons/1203-proc.txt)).
- **Little's law held to within 3%.** Ten 500 ms jobs a second against two workers and 20 queue slots: the first `503` came after 3.5 s, jobs finished at 3.93 a second and waited 3.50 s on average, so the law predicts 13.7 jobs waiting; sampling `jobs_queue_depth` measured 14.0 ([1304-overload.txt](lessons/1304-overload.txt)). With spare capacity and evenly spaced arrivals, nothing waited at all ([1305-spare.txt](lessons/1305-spare.txt)).
- **A `select` with two ready cases picks one at random.** The worker that checked "stop" and "next job" in one `select` took one or two extra jobs after being told to stop in 7 of 20 runs; a single run usually passes ([1306-select.txt](lessons/1306-select.txt)).
- **Without backpressure, the API itself slows down.** With the queue full and no `503`, the fourth and fifth `POST` each waited about a second for room instead of failing fast ([1308-nobackpressure-api.txt](lessons/1308-nobackpressure-api.txt)); the queue's own test hung, so the lesson runs it with `-timeout`.
- **Retries multiply attempts, not effects.** With half of all results lost after the work was done (`FAIL_RATE=0.5`) and three attempts each, 20 jobs took 35 attempts; the ledger recorded 20 effects and refused 15 duplicates. Four jobs ended `failed` with their effect already recorded, because the failure came after the work ([1403-lossy.txt](lessons/1403-lossy.txt)). Keying the ledger by attempt instead of by job recorded all 35 ([1405-attemptkey.txt](lessons/1405-attemptkey.txt)).
- **Protobuf is smaller, and silent about mistakes.** The same job was 37 bytes in protobuf and 172 in JSON ([1503-size.txt](lessons/1503-size.txt)). Swapping two field numbers in the `.proto` and rebuilding only the server made it read a client built from the old contract as an empty request, and reject it ([1504-swap.txt](lessons/1504-swap.txt)).
- **A lease alone doesn't fence a slow worker.** A worker paused with SIGSTOP past its lease came back and reported its job done; the fencing token made the control plane refuse it ([1602-pause.txt](lessons/1602-pause.txt)), and without the token check the module's own test caught the stale report being accepted ([1604-notoken.txt](lessons/1604-notoken.txt)). Without the reconcile loop, a killed worker's job stayed `running` with no effect ([1605-noloop.txt](lessons/1605-noloop.txt)).

## Gate

[gate/](gate/) holds the gate run against the finished module and five broken versions, from [capture-gate16.sh](capture-gate16.sh); [gate/broken/](gate/broken/) has each one as a diff against the finished code. Each run used a copy of the module in `/tmp/gate-NAME`, which is why `race.txt` shows that path.

| Run | Broken how | Fails |
|---|---|---|
| `pass.txt` | Not broken | Nothing: 7,064 jobs, 15 workers killed, 10 jobs handed back, every check passes |
| `noidempotency.txt` | `WithIdempotency` not wired into `main.go` | A retried `POST` creates a second job. Every test passes |
| `noreconcile.txt` | The reconcile loop never runs | Jobs stuck in `running` after 90 s; 0 handed back |
| `cancelcompletes.txt` | `cancelled` may move to `completed` | The module's own tests; cancelled jobs that completed |
| `race.txt` | `Stats` reads the maps without the lock | The race detector, and the control plane exits with 66. Every test passes |
| `leak.txt` | One goroutine per `Lease` call that waits for shutdown | Goroutines: 36 before the load, 6,173 after. Everything else passes |
