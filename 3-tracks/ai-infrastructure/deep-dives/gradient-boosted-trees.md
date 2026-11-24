# Compare gradient-boosted trees honestly

Start with the [time split and comparison plan](../01-ml-for-infrastructure/lessons/03-split-by-time-and-plan-the-comparison.md). Predict job duration using only information available when the job is admitted. Start from a median or tenant-history baseline. Fit each tree to the residual left by the current prediction, and add a fraction of that tree's prediction to the ensemble.

## Run a fair comparison

1. Construct point-in-time features. When using tenant history, include only completions that happened before the target admission.
2. Freeze a chronological training, validation, and final-test split. Tune tree depth, learning rate, and the number of trees against validation only.
3. Compare the baseline and boosted model on exactly the same test rows. Report mean absolute error and errors on long jobs. Record inference time and artifact size.
4. Check one cohort with few tenant examples. A better average can hide deterioration for those tenants.
5. Feed both sets of predictions into the same [scheduling simulation](../01-ml-for-infrastructure/lessons/07-test-scheduling-utility-and-input-drift.md). Decide based on queue outcomes and cost as well as prediction error.

Submit a table with the same workload and rows on both sides, plus the decision you would make if the validation win comes with a slower serving path.

## Runnable check

Trace boosting on small residuals first. The check uses squared loss and decision stumps, with the validation rows held aside. Use the same split discipline with a full tree library.

<!-- file: boost.py -->
~~~python
from statistics import mean


def mse(predictions, labels):
    return mean((pred - label) ** 2 for pred, label in zip(predictions, labels))


def fit_stump(values, residuals):
    unique = sorted(set(values))
    if len(unique) < 2:
        return values[0], mean(residuals), mean(residuals)
    candidates = []
    for split in unique[:-1]:
        left = mean(r for value, r in zip(values, residuals) if value <= split)
        right = mean(r for value, r in zip(values, residuals) if value > split)
        predictions = [left if value <= split else right for value in values]
        candidates.append((mse(predictions, residuals), split, left, right))
    _, split, left, right = min(candidates)
    return split, left, right


def boost(values, labels, queries, rounds=4, rate=0.5):
    initial = mean(labels)
    current = [initial] * len(labels)
    result = [initial] * len(queries)
    for _ in range(rounds):
        residuals = [y - yhat for y, yhat in zip(labels, current)]
        split, left, right = fit_stump(values, residuals)
        current = [pred + rate * (left if x <= split else right)
                   for x, pred in zip(values, current)]
        result = [pred + rate * (left if x <= split else right)
                  for x, pred in zip(queries, result)]
    return result


values = [0, 1, 2, 3, 4, 5]
labels = [10, 10, 10, 40, 40, 40]
validation_x, validation_y = [1.5, 4.5], [10, 40]
predicted = boost(values, labels, validation_x)
assert mse(predicted, validation_y) < mse([mean(labels)] * 2, validation_y)
~~~

<!-- run: python3 boost.py -->

## Check the model on held-out data

This replay uses deterministic synthetic inputs and holds out a separate evaluation period. Keep the workload settings beside the result. Use a real trace to check how the comparison changes with a different mix.

<!-- file: compare_trees.py -->
~~~python
import numpy as np
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import mean_absolute_error
from time import perf_counter


def fixture():
    rng = np.random.default_rng(7)
    size = rng.integers(1, 1000, 1500)
    backlog = rng.integers(0, 20, 1500)
    duration = size ** 0.6 + 5 * backlog + rng.normal(0, 3, len(size))
    return np.column_stack((size, backlog)), duration


features, duration = fixture()
train, validation, test = slice(0, 900), slice(900, 1200), slice(1200, None)
candidates = []
for leaves in (7, 15, 31):
    model = HistGradientBoostingRegressor(max_leaf_nodes=leaves, random_state=7)
    model.fit(features[train], duration[train])
    error = mean_absolute_error(duration[validation], model.predict(features[validation]))
    candidates.append((error, leaves, model))

_, leaves, model = min(candidates, key=lambda row: row[:2])
baseline = np.full(len(duration[test]), np.median(duration[train]))
start = perf_counter()
predicted = model.predict(features[test])
elapsed_ms = (perf_counter() - start) * 1000
baseline_error = mean_absolute_error(duration[test], baseline)
boosted_error = mean_absolute_error(duration[test], predicted)
assert boosted_error < baseline_error
print(f"{leaves=}, {baseline_error=:.2f}, {boosted_error=:.2f}, {elapsed_ms=:.2f}")
~~~

<!-- run: uv run --no-project --python 3.12 --with numpy==2.5.4 --with scikit-learn==1.9.1 python compare_trees.py -->

~~~bash
uv run --no-project --python 3.12 --with numpy==2.5.4 --with scikit-learn==1.9.1 python compare_trees.py
~~~
