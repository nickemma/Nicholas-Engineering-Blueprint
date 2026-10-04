# Python Bridge: measure what you built

> **Status: planned.** This bridge is written after Phase 1 is rebuilt, because it measures the Phase 1 service. The outline below is the plan. The authoritative route is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

**Question:** your Phase 1 service "feels fast". How fast is it, for whom, and how would you know if a change made it worse?

**You build:** a Python command-line load generator that drives the Phase 1 jobs API at a chosen rate, records every request's latency and status, and writes them to a CSV file. A second script turns that file into percentiles and plots. Both have pytest tests.

**Time:** about 2 weeks. **Prerequisites:** Phase 1 finished and running.

## Planned steps

| Step | You learn | You build |
|---|---|---|
| 1 | Installing Python with `uv`, virtual environments, running a script | `hello.py`; `uv init`; `uv run` |
| 2 | Values, types, lists, dicts, functions, type hints | A function that summarises a list of latencies |
| 3 | pytest; TDD in Python | Tests for the summary function, written first |
| 4 | Modules, packages, the standard library, `argparse` | A CLI: `kload --url ... --rate 50 --duration 30s` |
| 5 | HTTP from Python with `httpx`; errors and timeouts | A load generator that sends one request at a time |
| 6 | `asyncio`: concurrency without threads | The same generator at a fixed request rate, with many requests in flight |
| 7 | Files and CSV; reproducibility (seeds, recording the configuration) | Raw results saved alongside the run configuration |
| 8 | pandas basics; percentiles; why averages hide the tail | `analyze.py` reports p50/p95/p99 and the error rate |
| 9 | Plotting with matplotlib | Latency-over-time and distribution plots |
| 10 | Coordinated omission (a classic measurement mistake) | An experiment that shows it and fixes it |

## Gaps this closes

Python language and tooling (ledger row 9), and measurement and experimental method (row 10). See the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

## Why it comes here

From Phase 2 on, every experiment (killing workers, partitions, impaired networks, the Phase 7 evaluation) is driven and analysed with these tools. The Phase 7 ML pipeline builds on the same Python base.
