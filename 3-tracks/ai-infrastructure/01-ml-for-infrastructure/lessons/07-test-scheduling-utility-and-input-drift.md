# 07 Test scheduling utility and input drift

> ML for infrastructure · Week 4

## The problem

Lower prediction error is only meaningful if it improves a decision. A deployment also needs to notice when the job mix leaves the conditions used to evaluate the model.

## The mental model

~~~text
same ready cohort + same service times → FIFO wait distribution
                                     → predicted-first wait distribution
features in a new window               → input-drift check
~~~

## The pattern

Use replay to compare FIFO with ordering a ready cohort by estimated service time. The scheduler sees predictions and the evaluator uses actual service times. Compare mean and p95 wait. Simulate one worker per pool and day with all jobs in that cohort ready at once. Real arrival times, starvation, concurrent capacity, and feedback would need a different experiment.

Track the changes in feature means in training standard deviations and the fraction outside training ranges. An alert describes the inputs. Use newly observed outcomes to evaluate the model's error and support any retraining decision.

## Build it

### Compare the policies and score a feature window

Use the same cohort and order ties consistently. Require a minimum sample size for the input-drift exercise.

Create `ml_lab/observe.py`.

<!-- file: ml_lab/observe.py -->
~~~python
"""Compare scheduling decisions and audit distribution changes."""

import math
from collections import defaultdict
from statistics import fmean

from .contract import DAY, FEATURE_NAMES, Event, Features
from .model import Predictor

MEAN_SHIFT = 1.25
RANGE_RATE = 0.10


def schedule(rows: list[Event], predictor: Predictor) -> dict:
    # Model a ready cohort per day and worker pool. Both policies get the
    # same service times; only their order changes.
    cohorts = defaultdict(list)
    for row in sorted(rows, key=lambda row: (row.submitted_ms, row.event_id)):
        cohorts[(row.submitted_ms // DAY, row.pool)].append(row)
    waits = {"fifo": [], "predicted_first": []}
    for cohort in cohorts.values():
        estimates = predictor.predict([row.features() for row in cohort])
        estimate_by_event = {row.event_id: estimate for row, estimate in zip(cohort, estimates, strict=True)}
        ordered = sorted(cohort, key=lambda row: estimate_by_event[row.event_id])
        for policy, rows_in_order in (("fifo", cohort), ("predicted_first", ordered)):
            elapsed = 0
            for row in rows_in_order:
                waits[policy].append(elapsed)
                elapsed += row.runtime_ms

    return {policy: {"mean_wait_ms": fmean(values),
                     "p95_wait_ms": sorted(values)[math.ceil(0.95 * len(values)) - 1]}
            for policy, values in waits.items()}


def drift(samples: list[Features], manifest: dict) -> dict:
    if len(samples) < 32:
        raise ValueError("drift window requires 32 rows")
    rows = [sample.numeric() for sample in samples]
    columns = zip(*rows, strict=True)
    reference = manifest["scale"]
    shifts = {name: abs(fmean(column) - mean) / sd for name, column, mean, sd in
              zip(FEATURE_NAMES, columns, reference["mean"], reference["std"], strict=True)}
    bounds = manifest["training_range"]
    rate = fmean(any(value < low or value > high for value, (low, high) in
                     zip(row, bounds, strict=True)) for row in rows)
    return {"rows": len(rows), "mean_shifts_sd": shifts, "outside_range_rate": rate,
            "alert": max(shifts.values()) >= MEAN_SHIFT or rate >= RANGE_RATE}
~~~

## Check it

~~~bash
uv run --locked python -c "from ml_lab.observe import MEAN_SHIFT, RANGE_RATE; print(MEAN_SHIFT, RANGE_RATE)"
~~~

<!-- run: uv run --locked python -c "from ml_lab.observe import MEAN_SHIFT, RANGE_RATE; assert (MEAN_SHIFT, RANGE_RATE) == (1.25, .1)" -->

The plan alerts when a feature mean shifts by at least 1.25 training standard deviations or at least 10% of rows leave the training range. The gate compares a stable window with a larger queue-depth window before exercising rollback.
