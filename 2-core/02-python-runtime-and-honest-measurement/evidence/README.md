# Evidence: Python runtime and honest measurement

Real outputs behind the lessons and the gate, captured on 2026-11-20 with Python 3.14.7, uv 0.12.7 and Go 1.27.4.

## How they were captured

All runs used [Dockerfile](Dockerfile): a fresh Ubuntu 24.04 with the Foundations tools and an ordinary user, `ada`, on a 16-CPU x86-64 machine running WSL2. Each script installs Go from go.dev, as Foundations 01 does. Three things were set up differently from the lessons, to save downloads on a slow link: uv's binary (the same 0.12.7 that Foundations 04 installs) was copied in; `uv python install` read the Python 3.14.7 builds, standard and free-threaded, from a local copy of the same files (`UV_PYTHON_INSTALL_MIRROR`); and Switchyard was built from core 01's finished code using a local copy of its Go modules, with the network off.

- **`lessons/`** holds one file per command the lessons show, named by lesson and step (`0702-freeze.txt` is lesson 07's second capture). Each file has the command, its output and its exit status. Times, PIDs, ports and latencies differ on every run. The lessons leave out uv's own lines about building and installing the project: the scripts swap in each lesson's code before running its commands, which makes uv re-sync, something a learner following the lessons sees only after `uv add`.
- The scripts, in the order they ran:
  - [capture.sh](capture.sh): every lesson, from `uv init` to lesson 08, using snapshots of the project made by replaying the lessons up to lesson 04 step 2, lesson 04, lesson 05 step 2 and lesson 06.
  - [capture-b.sh](capture-b.sh) reran eight captures after fixes found in the first run: the freeze and bottleneck commands waited for every background job with a bare `wait`, including Switchyard, and timed out (the lessons now use `wait $!`); "start every task at once" showed little at 1,000 requests a second, so it moved to 3,000; and the builds experiment gained its warm-up run. The first run's files for those captures are kept, as `first-0607-gather-all.txt`, `first-0607b-dispatcher.txt` and `first-0705-bottleneck.txt`; its `0805-fixed.txt` is the one lesson 08 shows.
  - [capture-c.sh](capture-c.sh) reran lesson 01's reference-count drill after its label was corrected for Python 3.14.
  - [capture-d.sh](capture-d.sh) measured httpx against `kload`'s own client: [probes/clients.py](probes/clients.py), output in `probes/clients.txt`.
- Each deliberate mistake in [mistakes/](mistakes/) is the file as it was broken, named by lesson. The scripts lay it over the code, run the command, and put the real file back.

## Findings while building the module

- **httpx was too slow to send the load.** The first `kload` used httpx's `AsyncClient`. Against the gate's server with a 5 ms delay, on the same open loop ([probes/clients.txt](probes/clients.txt)): at 200 requests a second, httpx reported a p50 of 8.10 ms and used 2.24 ms of CPU per request, against 6.72 ms and 0.30 ms for `kload`'s own client; at 500 a second, httpx used 5.11 ms of CPU per request, took 12.8 s for a 5-second run, and reported a p50 of 4,397 ms. `kload`'s client stayed on schedule at 2,000 a second, at 0.12 ms of CPU per request. On the host, the very first version also had a start-up spiral: httpx imports parts of itself on its first request (about 1.2 s), so the first requests were late, the backlog opened many connections at once, and httpx's connection pool, which does more work the more connections it holds, fell further behind.
- **Creating every task up front makes the first requests late.** With all 15,000 tasks of a 3,000-a-second, 5-second run started at the beginning, the send lag's p99 was 48.6 ms and `kload` refused the run; with a dispatcher that starts each task when it's due, 1.17 ms ([0607-gather-all.txt](lessons/0607-gather-all.txt), [0607b-dispatcher.txt](lessons/0607b-dispatcher.txt)). At 1,000 a second the difference was small in the container (1.26 ms against 1.16 ms) and 15 ms against 1.2 ms on the host.
- **The closed loop first missed the freeze entirely.** It sent its 1,600 requests back to back and finished in 0.5 s, before the freeze began 3 s in. The old Python Bridge's closed loop worked the same way. It now follows the same schedule as the open loop, one request at a time, so the freeze lands in both runs: open p99 926 ms, closed p99 0.81 ms, and the closed loop's own send lag p99 925 ms ([0702-freeze.txt](lessons/0702-freeze.txt)).
- **asyncio's timers have a 1 ms floor on Linux.** `epoll_wait` takes its timeout in whole milliseconds, so a sleep can end up to 1 ms late. At 200 requests a second, the send lag's p99 was 1.33 ms and the p50 latency 1.27 ms; at 4,000 a second, with the loop rarely idle, the p50 fell to 0.60 ms ([0604-health.txt](lessons/0604-health.txt), [0605-limit.txt](lessons/0605-limit.txt)).
- **Send lag alone doesn't catch every distortion.** At 4,000 requests a second one `kload` kept its send lag near 1 ms but used about 80% of a CPU, and its p99 varied from run to run: 1.56 ms in [0705-bottleneck.txt](lessons/0705-bottleneck.txt), 5.61 ms in the first capture, 20.6 ms on the host, where two `kload` processes at 2,000 a second each saw 1.8 ms. Hence the CPU warning above 70%.
- **A fixed order with no warm-up failed an A/A test.** The first builds experiment ran `plain`, `race`, `plain-again` in turn with no warm-up; its very first run had a p99 of 2.47 ms against 1.58 to 1.75 for the rest, and the same binary came out "faster" than itself ([0805-fixed.txt](lessons/0805-fixed.txt)). The rerun passed ([0805b-fixed-again.txt](lessons/0805b-fixed-again.txt)). On the host, a fixed interleaving put each `plain-again` run straight after a `race` run, and `plain-again` came out 0.10 ms slower at the p99 (95% CI [+0.06, +0.14]) than the identical `plain`; randomising the order removed it. The first random-order run in the container stopped when its first run, on a cold machine, fell behind (send lag p99 44.7 ms). With a warm-up run and a random order, the A/A test passed and the race build was 0.17 ms slower at the p50 and 0.18 ms at the p99 ([0804-builds.txt](lessons/0804-builds.txt)).
- **Python 3.14's `sys.getrefcount` no longer counts its own argument** for a local variable, which 3.14 loads without taking a new reference: the drill prints 1, 2, 1, where older Pythons printed 2, 3, 2.
- **Go's loop overflowed silently.** The sum of squares below 10 million is 333,333,283,333,335,000,000; Go's `int` wrapped and printed 1,291,890,006,563,070,912 ([0105-loop.txt](lessons/0105-loop.txt)).
- **The GIL's switch interval shows up in timing.** A thread sleeping 1 ms woke 5.22 ms late while another thread computed, and 0.09 ms late under the free-threaded build ([0203-switch.txt](lessons/0203-switch.txt)).
- **A busy CPU makes timing tests flaky, and so can a busy port range.** One replay of lesson 06's tests failed while the gate ran beside it, generating tens of thousands of connections; it passed alone, and under 16 CPU-burning loops.

## Gate

[gate/](gate/) holds the gate run against the finished `kload` and five broken versions, from [capture-gate.sh](capture-gate.sh); [gate/broken/](gate/broken/) has each one as a diff against the finished code.

| Run | Broken how | Fails |
|---|---|---|
| `pass.txt` | Not broken | Nothing: every check passes |
| `fromsent.txt` | Latency timed from when a request was sent | The module's own test; at 20,000 a second, 39,499 latencies shorter than their own send lag. Accuracy and the freeze pass: when nothing holds `kload` back, sending is on time |
| `nokey.txt` | No `Idempotency-Key` on a `POST` | Ruff (an unused variable); accuracy: the server can't number the requests |
| `neverbehind.txt` | `cmd_load` always returns 0 | Ruff; the module's own test; exit 0 at 20,000 a second, though it printed that it fell behind |
| `sleepblocks.txt` | `time.sleep` in the dispatcher | Three of the module's tests; accuracy and the freeze, both exit 3 with about 5 s of send lag |
| `compareflip.txt` | `bootstrap(b, a)` in `cmd_compare` | The module's own test; "B is faster" where B is 2 ms slower |
