# 03 Split by time and plan the comparison

> ML for infrastructure · Week 2

## The problem

A random split mixes yesterday with tomorrow. Even a time split can leak when it includes a label that arrived after the model would have been trained.

## The mental model

~~~text
day 0–9     fit scales and weights             label known by day 10
day 10–13   select the checkpoint              label known by day 14
day 14–19   compare locked artifacts           label known by day 20
~~~

## The pattern

Assign rows by admission time, then require that completion happened before the relevant window closed. Set the error metric and promotion rules in advance. Use mean absolute error in milliseconds. Compare to the median of the training targets and a least-squares model using only work size. The candidate must reduce holdout MAE by 15% versus the stronger reference and stay within 5 ms of the incumbent in each pool.

A training set defines the scaler, model weights, and baselines. The validation set selects the candidate epoch. Release decisions compare the finalized versions on a held-out window. Repeated development against the same holdout would turn it into a tuning set.

## Check it

~~~bash
uv run --locked python -c "from pathlib import Path; from ml_lab.dataset import load_split; s=load_split(Path('dataset')); print(len(s.train), len(s.valid), len(s.test), s.late)"
~~~

<!-- run: uv run --locked python -c "from pathlib import Path; from ml_lab.dataset import load_split; s=load_split(Path('dataset')); assert (len(s.train), len(s.valid), len(s.test), s.late) == (640, 256, 384, 1)" -->

Expect `640 256 384 1`. The extra event was admitted just before the training cutoff and completed after it. If the training count is 641, trace the missing completion-time condition.
