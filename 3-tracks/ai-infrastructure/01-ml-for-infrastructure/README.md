# 01 ML for infrastructure

> AI infrastructure track · Time 5 weeks at 12–15 hours a week · Builds on [Core 02 Python runtime and honest measurement](../../../2-core/02-python-runtime-and-honest-measurement/README.md) and [Core 03 Docker and Postgres](../../../2-core/03-docker-and-postgres/README.md) · Status ready

Build a Switchyard job-duration prediction lab. Turn synthetic job events into time-partitioned Parquet, fit simple baselines and a small PyTorch model, and compare their predictions on later jobs. Track the model versions you evaluate, choose an active artifact, and prove you can roll it back. Then ask whether the estimates help a scheduler and whether a new window looks like the workload you trained on.

Start with [Before you start](lessons/00-before-you-start.md). The lab runs on CPU with pinned Linux x86-64 dependencies.

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Capture admission and completion](lessons/01-capture-admission-and-completion.md) | Separate features the scheduler knows at admission from the completion label. |
| 1 | 02 | [Build private Parquet snapshots](lessons/02-build-private-parquet-snapshots.md) | Validate, deduplicate, quarantine, and publish an allowlisted, checksummed dataset. |
| 2 | 03 | [Split by time and plan the comparison](lessons/03-split-by-time-and-plan-the-comparison.md) | Exclude labels unavailable at cutoff and set release criteria in milliseconds. |
| 2 | 04 | [Train a CPU model and score it](lessons/04-train-a-cpu-model-and-score-it.md) | Compare median and size-only baselines with a small PyTorch network. |
| 3 | 05 | [Promote versioned artifacts](lessons/05-promote-versioned-artifacts.md) | Store immutable weights and metrics, then change the active alias under a quality policy. |
| 3 | 06 | [Serve the active version](lessons/06-serve-the-active-version.md) | Check feature parity and identify which artifact answered a request. |
| 4 | 07 | [Test scheduling utility and input drift](lessons/07-test-scheduling-utility-and-input-drift.md) | Compare FIFO and predicted-first ordering on matching synthetic cohorts and alert on shifted input. |
| 4 | 08 | [Operate the local lab](lessons/08-operate-the-local-lab.md) | Run training, activation, inference, reporting, and rollback through the CLI. |
| 5 | 09 | [Run the lifecycle gate](lessons/09-run-the-lifecycle-gate.md) | Rebuild from a clean event export, refuse a weak candidate, and prove rollback over HTTP. |

This unit adapts the workload, dataset, model, and evaluation work from [Measure and learn](README.md). It uses a finite synthetic export so every learner can reproduce the same changes on a CPU.

## The gate

The [gate](gate/README.md) checks the data privacy projection and temporal cutoffs, fixed-seed training, baseline comparisons, artifact integrity, and the prediction path. A baseline-quality artifact must leave the active pointer unchanged. The trained artifact must pass the release policy. A shifted queue-depth window raises an input alert, and rolling back restores the previous response on the same loopback prediction server.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Rebuild the dataset, identify the label, and compare the model's error with a simple baseline. |
| Intermediate | Trace a prediction to its data and weight versions, preserve feature parity, and show rollback changed what the service returned. |
| Senior | State the conditions behind a release decision, distinguish scheduling utility from model error, and validate a drift alert against fresh labeled outcomes. |

## Practice

- [Exercise](exercises.md). Estimate build duration on a simulated build farm.
- [Self-check](self-check.md). Trace the data, release, and rollback boundaries from memory.
- [Evidence](evidence/README.md). Inspect the measured sample, limits, and reproduction commands.

Continue to [Serving and scaling models](../02-serving-and-scaling-models/README.md).
