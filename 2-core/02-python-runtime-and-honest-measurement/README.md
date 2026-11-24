# 02 Python runtime and honest measurement

> The core · Time: 2 weeks at 12–15 hours a week · Builds on: [01 Go runtime and reliable services](../01-go-runtime-and-reliable-services/README.md), with Switchyard running · Status: ready

## What you'll learn

How Python runs your code (objects, reference counting, bytecode, the GIL, and what the `asyncio` event loop really does), and how to measure a service without fooling yourself: percentiles instead of averages, an open loop instead of a closed one, a load generator that knows when it has fallen behind, and repeat runs with confidence intervals instead of one lucky number.

## What you'll build

**`kload`**, an open-loop load generator in Python, packaged and tested, and the analysis behind it. You point it at Switchyard: a baseline, a freeze that a closed loop can't see, a saturation run that fills the job queue until it answers `503`, and two builds compared properly. `kload` reports its own lateness and CPU use, so every run says whether its numbers can be trusted. Core 06 uses it to load the Go ↔ Rust wire.

## Lessons

| # | Lesson | What it teaches | Time |
|---|---|---|---|
| 01 | [How Python runs your code](lessons/01-how-python-runs-your-code.md) | Everything is an object; names are references; reference counting and the cycle collector; bytecode with `dis`; why `[[0] * 3] * 3` shares its rows and a mutable default remembers; the same loop in Python and Go, measured | ~4 h |
| 02 | [The GIL: threads, processes and the free-threaded build](lessons/02-the-gil-threads-processes-and-the-free-threaded-build.md) | CPU-bound work in 1, 2, 4 and 8 threads (no faster), then in processes (faster); I/O-bound work in threads (faster); Python 3.14's free-threaded build, measured; what this means for a load generator | ~3 h |
| 03 | [How the event loop works](lessons/03-how-the-event-loop-works.md) | A small event loop by hand, from generators and `selectors`, running an echo server and three clients in one thread; what `await` does underneath; the same program on `asyncio`; blocking the loop by mistake (`time.sleep`, CPU work) and measuring the lag it causes; debug mode; moving blocking work off the loop | ~4 h |
| 04 | [`kload` as a package: why averages lie](lessons/04-kload-as-a-package-why-averages-lie.md) | The src layout, `pyproject.toml`, `argparse` subcommands, a testable `main(argv)`; Foundations 04's nearest-rank percentile as a frozen dataclass summary; 99 requests at 10 ms and one at 5 s: the mean describes none of them | ~3 h |
| 05 | [An HTTP client tested without a network](lessons/05-an-http-client-tested-without-a-network.md) | `httpx`; classes, custom exceptions, `match`; dependency injection; fakes with `httpx.MockTransport` that answer, fail and stall | ~3 h |
| 06 | [Load on a schedule: open and closed loops](lessons/06-load-on-a-schedule-open-and-closed-loops.md) | Why httpx was too slow to send the load; an HTTP/1.1 client on `asyncio` streams; a dispatcher that starts each request when it's due, its latency timed from then; coordinated omission; `kload` records its own send lag and CPU time, and exits 3 when it fell behind | ~4 h |
| 07 | [Three experiments on Switchyard](lessons/07-three-experiments-on-switchyard.md) | pandas and matplotlib; a baseline on `GET /health`; freezing the control plane with `SIGSTOP`, measured open and closed (the same freeze, answers hundreds of times apart); `POST /jobs` past the queue's capacity, where the `503`s from core 01 lesson 13 appear; finding the rate where `kload` itself becomes the bottleneck | ~4 h |
| 08 | [Repeat runs and confidence intervals](lessons/08-repeat-runs-and-confidence-intervals.md) | Why one run proves nothing; bootstrap confidence intervals over repeat runs; saved settings that rerun an experiment; Switchyard's plain and `-race` builds compared in a random order, with an A/A test first, and what a fixed order does | ~3 h |

**Absorbs** the Python Bridge's steps 2–6 (its step 1 is in Foundations 04, lesson 06). Lessons 04–07 are those steps, re-based on Foundations 04 and pointed at Switchyard instead of the old Phase 1 service; lesson 06 replaces httpx with its own client, and its closed loop now follows the same schedule as the open one. Lessons 01–03 and 08 are new.

**Not here any more:** the Python Bridge's "7-second tail" (SYN retransmissions during a freeze) becomes a question carried into core 06, where you capture the packets.

## The gate

`gate/run.sh` builds and installs your `kload`, and runs it against **the gate's own server**: a small Go program whose answers take a known time, which can freeze on command, and which logs when each request really arrived. Because the gate knows the truth, it can check your numbers:

1. **Accurate:** 200 requests a second for 5 seconds against a 5 ms server: all 1,000 arrive, numbered by their `Idempotency-Key`, the p99 of their arrivals within 10 ms of schedule (from the server's own log); no latency is shorter than the server's own time for that request, and the p50 `kload` reports is within 3 ms of the server's.
2. **Open, not closed:** the server freezes for 1 second, 2 seconds in, at 100 requests a second. In open-loop mode, between 40 and 60 requests take 500 ms or more (about 50 were due in the first half of the freeze); in closed mode, at most 2 do, and `kload` says it ran a closed loop.
3. **Honest about itself:** at 20,000 requests a second, `kload` must say it fell behind and exit with status 3. Every latency in its CSV must include the time the request waited inside `kload`, and the server's log must confirm the requests really did arrive late.
4. **Compares properly:** on sets of five runs the gate writes itself, `kload compare` says "no difference shown" for two sets from the same server, and "B is slower", with an interval above zero, when B is 2 ms slower.
5. `ruff format`, `ruff check` and `pytest` are clean.

The [gate's page](gate/README.md) shows a pass and each kind of fail.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Package and test a Python tool, and explain why the mean hides slow requests |
| Intermediate | Explain the GIL and the event loop, find a blocked loop, and show coordinated omission with numbers |
| Senior | Design a measurement that can't fool you: open loop, a generator with checked headroom, repeat runs, confidence intervals, and settings someone else can rerun |

## Practice

- [Exercises](exercises.md): `logstat`, a log analyser and health prober for Switchyard's JSON logs (after lesson 07).
- [Self-check](self-check.md): explain-it questions per lesson, then a test from memory.

## Next

[03 Docker and Postgres](../03-docker-and-postgres/README.md): Switchyard's jobs move into PostgreSQL, and `kload` measures what that costs.

---

<sub>The raw runs behind this module's outputs and its gate are in [evidence/](evidence/README.md). You don't need them to follow the lessons.</sub>

Use [Compare repeated Go benchmarks](go-benchmark-comparison.md) to apply the same experiment design to a microbenchmark.
