# Python Bridge: measure what you built

**Question:** your Phase 1 service "feels fast". How fast is it, for whom, and how would you know if a change made it worse?

**Time:** about 2 weeks. **Prerequisites:** [Phase 1](../01-reliable-service/README.md), with its server running.

## Syllabus

| Step | Topic | You'll learn |
|---|---|---|
| 1 | A first script, function and test | uv, virtual environments, `pyproject.toml`, indentation, lists, dicts, f-strings, exceptions, pytest, ruff |
| 2 | Why averages lie | Percentiles (nearest rank), tails, dataclasses, `sorted` vs `sort`, parametrised tests, floating point |
| 3 | A package and a CLI | The src layout, packages, argparse subcommands, comprehensions, `main(argv)` testability, fixtures |
| 4 | An HTTP client tested without a network | Classes, custom exceptions, classmethods, `match`, dependency injection, `httpx.MockTransport` |
| 5 | Load on a schedule | The GIL, asyncio, coroutines, semaphores, open vs closed loops, coordinated omission, raw data plus settings |
| 6 | Analysis and three experiments | pandas, groupby, matplotlib; baseline, freeze and saturation experiments; is the tool the bottleneck? |

## What you'll be able to do

- Write, package, lint and test Python with uv, ruff and pytest.
- Use Python's core data structures, classes, dataclasses, exceptions, comprehensions, closures and pattern matching.
- Build a testable CLI, and an HTTP client with an injected transport.
- Use `asyncio` for concurrent I/O, bounded by a semaphore.
- Explain why averages hide latency problems, and compute percentiles correctly.
- Explain and demonstrate coordinated omission, and build an open-loop load generator.
- Analyse results with pandas, plot them, and check whether the measuring tool is itself the bottleneck.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md), typing every piece of code yourself; you'll build `kload`.
2. Run the three experiments in step 6 against your own Phase 1 service.
3. Answer [learned.md](learned.md).
4. Build the exercise project, **[logstat](exercises.md)**, on your own: a log analyser and health prober. The exercise page shows exactly what the finished tool prints.
5. Take the [self-test](../../notes/learned/python-bridge.md).

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where | Evidence |
|---|---|---|
| Python and its tooling (row 9) | Steps 1–6 and logstat | Two packages, with tests and lint passing |
| Measurement and experimental method (row 10) | Steps 2, 5, 6 | Baseline, freeze and saturation experiments, with saved settings |
| Testing and TDD (row 5) | Every step | pytest suites with fixtures, parametrisation and fakes |

## Patterns introduced

- **Dependency injection in Python.**
- **Fakes over mocks:** `MockTransport(fake_api)` and `StallingServer` model behaviour.
- **Keep raw data plus settings** for reproducibility.
- **Open-loop measurement.**

## Next

[Phase 2](../02-connected-services/README.md) splits the service across processes and a message broker. `kload` and `logstat` are the tools you'll use to measure what that costs and what it buys.
