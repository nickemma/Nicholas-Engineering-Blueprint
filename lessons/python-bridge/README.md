# Python Bridge: measure what you built

**Question:** your Phase 1 service "feels fast". How fast is it, for whom, and how would you know if a change made it worse?

**You build:** `kload`, a tested Python command-line tool:
- a client for the Phase 1 API;
- an open-loop async load generator;
- raw results saved with their settings;
- percentile reports and plots.

You then use it for three real experiments: a baseline, a server freeze measured two ways, and finding the point where the tool itself becomes the bottleneck.

**Time:** about 2 weeks. **Prerequisites:** [Phase 1](../01-reliable-service/README.md), with its server running.

| File | Use it for |
|---|---|
| [TEACHING.md](TEACHING.md) | The lesson |
| [steps/](steps) | Six runnable uv projects. `06-analysis` is the finished tool |
| [exercises.md](exercises.md) | Exercises for after the checkpoint |
| [learned.md](learned.md) | Your answer sheet |

## What you'll be able to do

- Write, package, lint and test Python with uv, ruff and pytest.
- Use Python's core data structures, classes, dataclasses, exceptions, comprehensions, closures and pattern matching.
- Build a CLI with argparse, and test it without starting a process.
- Write an HTTP client with dependency injection, and test it with a mock transport.
- Use `asyncio` for concurrent I/O, and bound it with a semaphore.
- Explain why averages hide latency problems, and compute percentiles correctly.
- Explain and demonstrate coordinated omission; build an open-loop generator.
- Analyse results with pandas and plot them with matplotlib; check that the measuring tool isn't the bottleneck.

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where | Evidence |
|---|---|---|
| Python and its tooling (row 9) | Steps 1–6 | The `kload` package, with tests and lint passing |
| Measurement and experimental method (row 10) | Steps 2, 5, 6 | The baseline, freeze and saturation experiments, with saved settings |
| Testing and TDD (row 5) | Every step | pytest suites with fixtures, parametrisation and fakes |

## Patterns introduced

- **Dependency injection in Python**: `JobsClient(http)`, `run_open_loop(client, request, ..., clock=...)`.
- **Fakes over mocks**: `MockTransport(fake_api)` and `StallingServer` model behaviour instead of recording calls.
- **Keep raw data plus settings** for reproducibility.
- **Open-loop measurement**.

## Run the finished tool

~~~bash
cd lessons/python-bridge/steps/06-analysis
uv run pytest
uv run kload smoke                               # needs the Phase 1 server running
uv run kload load --rate 100 --duration 5 --out results/run.csv
uv run kload analyze results/run.csv --plot results/run.png
~~~

## Next

[Phase 2](../02-connected-services/README.md) splits the service across processes and a message broker. `kload` is the tool you'll use to measure what that costs and what it buys.
