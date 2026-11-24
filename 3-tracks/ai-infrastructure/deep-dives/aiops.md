# Find unusual incidents in operational signals

Use [recorded incident evidence](../../../ownership/README.md) for one worked case, then run a local fixture with marked failure windows and a normal period. Collect aligned slices of error rate, request latency, queue depth, and a count of selected log events. Preserve missing-data flags so an unavailable measurement does not appear as a healthy zero.

## Compare two detectors

Start with the existing [SLO alert](../../../2-core/08-shipping-safely/lessons/05-define-reliability-from-the-client-side.md). Compare it with an unsupervised anomaly detector using a fixed feature window. Fit the anomaly detector and choose a threshold using earlier data. Keep a quiet and a fault period aside until evaluation. One model to try is an isolation forest fitted to the normal windows.

Replay the same sequence through both detectors and group consecutive alert windows into incidents. Report detection delay, false alerts in the quiet run, and missed failures. Label periods where the fault mechanism changed or where no useful signal reached the collector. Investigate false alerts with the original request and log timelines before claiming a better incident signal.

Pick one example the model surfaced and one it missed. Decide which alert should page an operator and which should appear as extra context. A detector score is evidence for triage. Verify recovery with the original client operation.

## Runnable check

Check the evaluation plumbing with a median-based detector and a fixed-rule baseline. This fixture is intentionally small and synthetic. The held-out incident begins at window four and the value at window two is missing.

<!-- file: detect.py -->
~~~python
from statistics import median


def detector(normal, multiplier=5):
    center = median(normal)
    spread = median(abs(value - center) for value in normal)
    threshold = center + multiplier * max(spread, 1)
    return lambda value: value is not None and value > threshold


def observe(windows, classify):
    return [i for i, value in enumerate(windows) if classify(value)]


training = [19, 20, 21, 22, 20]
validation = [20, 20, None, 23, 55, 57, 21]
assert observe(validation, detector(training)) == [4, 5]
assert observe(validation, lambda value: value is not None and value > 60) == []
~~~

<!-- run: python3 detect.py -->

## Measure an injected incident

This replay uses deterministic synthetic inputs and holds out a separate evaluation period. Keep the workload settings beside the result. Use a real trace to check how the comparison changes with a different mix.

<!-- file: compare_alerts.py -->
~~~python
import numpy as np
from sklearn.ensemble import IsolationForest


rng = np.random.default_rng(27)
baseline = rng.normal([20.0, 0.001], [1.0, 0.00014], size=(240, 2))
calibration = rng.normal([20.0, 0.001], [1.0, 0.00014], size=(120, 2))
run = rng.normal([20.0, 0.001], [1.0, 0.00014], size=(120, 2))
incident = np.arange(50, 65)
run[incident] += [8.0, 0.002]

model = IsolationForest(n_estimators=96, random_state=27)
model.fit(baseline)
limit = np.quantile(model.score_samples(calibration), 0.025)
alerts = {
    "fixed error rule": run[:, 1] >= 0.005,
    "isolation forest": model.score_samples(run) <= limit,
}
quiet = np.ones(len(run), dtype=bool)
quiet[incident] = False
for name, alarm in alerts.items():
    hit = np.flatnonzero(alarm & ~quiet)
    delay = int(hit[0] - incident[0]) if len(hit) else None
    print(name, "quiet windows flagged:", int(alarm[quiet].sum()), "delay:", delay)
assert not alerts["fixed error rule"][incident].any()
assert alerts["isolation forest"][incident].any()
~~~

<!-- run: uv run --no-project --python 3.12 --with numpy==2.5.4 --with scikit-learn==1.9.1 python compare_alerts.py -->

~~~bash
uv run --no-project --python 3.12 --with numpy==2.5.4 --with scikit-learn==1.9.1 python compare_alerts.py
~~~
