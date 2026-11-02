# Phase 7 exercise: buildcast, build times for a shared build farm

Build this **on your own**, in a new repository, after finishing [TEACHING.md](TEACHING.md). It's a different system from Runway, so you can't copy the guide's code. But to build it and measure it well, you need every Phase 7 idea:
- an experiment with a plan written first, A/A runs and intervals;
- a workload that models its users, and a data contract;
- a pipeline from events to partitioned Parquet;
- a leak-free dataset, baselines, and models compared honestly;
- a model served behind a scheduler that doesn't need it;
- predictions used to schedule, and measured;
- a registry with a gate, drift checks and a shadow;
- anomaly detectors scored against incidents you inject;
- a report that re-tests its own claims.

There's no solution in this repository. This page shows exactly what the finished system does.

## What you're building

A **build farm** runs other teams' CI builds on a pool of machines. Teams wait for builds, so knowing how long one will take is worth something: the farm can run short builds first, and tell each team when theirs will finish. Real farms (Bazel's remote execution, GitHub's larger runners, Buildkite's queues) face exactly this.

What makes a build's time hard to predict, and so worth modelling:
- **the repository and its size:** some repositories are big, and their builds long;
- **the cache:** a build whose dependencies are already in the worker's cache is several times faster than a cold one;
- **the change:** a one-line change rebuilds little, and a change to a core library rebuilds everything;
- **the farm's load:** builds that share a machine slow each other down.

You write the farm yourself, as a **simulator with real work**: a worker "builds" by doing CPU work (compressing, hashing, sorting) whose amount depends on the repository, the change and the cache. As in step 2 of the guide, how long a build takes must come from running it, never from a number the simulator declares.

Four parts:
- **`farm`**: a scheduler and a pool of workers, in Go, behind an HTTP API (`POST /builds`, `GET /builds/{id}`). It emits a `BuildChanged` event at every state change.
- **`buildload`**: a workload generator, from a TOML file: teams, repositories, arrival rates, change sizes.
- **`cast`**: the Python project: pipeline, dataset, models, serving, registry, drift, detectors, report.
- **`castd`**: the model server (FastAPI). The scheduler calls it with a deadline, and works without it.

A build request:

~~~bash
curl -s localhost:8090/builds -d '{"team":"payments","repo":"ledger","files_changed":3,"touches_core":false}'
~~~

~~~json
{"id": 4182, "state": "queued", "prediction": {"run_s": 41.2, "p90_s": 77.0, "model": "cast-v3"}}
~~~

With `castd` stopped, the same request still succeeds, with `"prediction": null`.

## Requirements

**Measure first.**
1. `experiments/aa/plan.toml` and an A/A experiment: the same build, twice as two conditions, interleaved, at least 20 rounds. Report the noise floor as a ratio with a 95% interval. Then the same run in sequence, under a CPU hog, showing a fake difference.
2. One real experiment, planned before it runs: does a warm cache cut build time by at least 30%? Give the verdict in one of four outcomes (different and important; different but not important; equivalent; inconclusive).

**Data.**
3. `BuildChanged` has a JSON Schema in `contracts/`, with examples written by a test on the Go side and checked by a test on the Python side. Adding an optional field needs no new version; show a change that does.
4. A pipeline from the event stream (Kafka, or Redis Streams if you prefer) to Parquet, partitioned by event hour: write, then commit; deduplicated by event ID; events that break the contract quarantined with the reason; late events landing in their own hour. Show a rebuild from the beginning giving the same result.
5. A reconciliation: the farm's database and the Parquet files agree on the count of finished builds per hour, with every difference explained.

**Models.**
6. A dataset with point-in-time features: what the farm knew when the build was submitted, including how warm the chosen worker's cache was then. A test rebuilds every row as of its submission time and requires the same values. Split by time.
7. Baselines: the median per repository, and a power law in the build's size per repository. Report MAE, log error and Spearman's rank correlation. Then show MAPE rewarding a baseline that guesses low.
8. Gradient-boosted trees, and one small neural network, each compared with the best baseline on the same test builds, job by job, with a paired bootstrap that resamples whole minutes. Report error per repository and per load, and the cost of one prediction.
9. A p90 bound, with its coverage on the test split.

**Serving and use.**
10. `castd` computes features online from the event stream, and a parity test replays recorded events and requires exactly the batch's features, build by build.
11. The scheduler calls `castd` with a 100 ms deadline and a circuit breaker, counting every outcome in a metric. With `castd` down, every build is still accepted.
12. Short builds first: one queue with priority for builds predicted under a threshold you choose by work, not by count. An experiment, FIFO against priority, interleaved rounds, reporting mean and p99 wait for short and long builds, and whether long builds starved.

**Running it.**
13. MLflow tracking and a registry: every model with the fingerprints of its data, code and environment; `champion` and `previous` aliases; a gate that promotes only if the improvement's interval is below zero, the p90's coverage hasn't dropped, and one prediction fits the deadline. Show it refusing a reseeded model.
14. A model card, generated, with the operating range of every number the model trained on.
15. Drift: PSI per feature against the training data, and a counter of unusual inputs (out of range, or unseen) per request, with an alert. Then add a new repository, much bigger than the others, and show the alert firing, the champion's error on it, and a retrained challenger winning in the shadow before it's promoted.

**Operations.**
16. At least five kinds of incident you can inject, each with a start and a stop command: a slow disk on one worker, the cache server down, a worker lost, `castd` slowed, the event stream down. An incident plan with a seed and a warm-up.
17. Detectors on the farm's metrics (threshold, MAD, EWMA) and on its logs (Drain templates), scored against the incidents: found, precision, median time to detect, and the share of quiet time alarmed. Compare them with an SLO burn-rate alert on build wait.
18. A held-out quiet hour, with its prediction written and the detectors' hashes recorded before it runs.

**The report.**
19. `cast report` re-tests every conclusion above as a claim with a test that can fail, gives each a verdict (holds, fails or inconclusive), lists what didn't work and the limits, includes the champion's card, and fingerprints its inputs. `cast report --check` exits 1 if a verdict changed.

## What finished looks like

The A/A experiment:

~~~text
$ cast analyze experiments/aa/results/first
b / a  1.012  (95% CI 0.981 to 1.044)   permutation p 0.47
verdict: equivalent within 5%
~~~

The warm cache, planned before it ran:

~~~text
$ cast analyze experiments/warm-cache/results/first
warm / cold  0.312  (95% CI 0.287 to 0.339)
verdict: different, and more than the 30% margin
~~~

The pipeline, killed mid-batch and restarted:

~~~text
$ cast pipeline --once
read 18,204 events; wrote 18,204 to 6 hours; 0 quarantined
$ cast warehouse check
events 18,204 (412 duplicates removed); builds 3,051; finished per hour matches the database in 6 of 6 hours
~~~

The models, on the test split:

~~~text
$ cast evaluate results/dataset.parquet --split test
model                     MAE_s  log_factor  spearman
median per repo           38.1       2.41      0.52
power law per repo        21.7       1.62      0.81
trees                     14.9       1.38      0.90
network                   15.3       1.40      0.89
trees minus power law, log error: -0.081 (95% CI -0.103 to -0.060)
~~~

The scheduler with `castd` stopped:

~~~text
$ curl -s localhost:8090/metrics | grep cast_predictions_total
cast_predictions_total{outcome="ok"} 0
cast_predictions_total{outcome="timeout"} 5
cast_predictions_total{outcome="open"} 211
cast_predictions_total{outcome="error"} 0
~~~

…and every one of those 216 builds accepted and finished.

The gate refusing a reseed:

~~~text
$ cast mlops gate 4
champion v3 vs challenger v4 on 2,912 newest builds
log error difference -0.0009 (95% CI -0.0041 to +0.0022): within noise
coverage 89.8% -> 89.6%; latency 0.21 ms
REFUSED: not better beyond noise
~~~

The new repository arriving:

~~~text
$ cast drift --live
feature          psi    ks     unusual
repo             0.41   -      6.8% unseen
files_changed    0.08   0.06   0.0%
cache_warmth     0.03   0.04   0.0%
ALERT CastInputsUnusual firing for 10m
~~~

The detectors, against the incidents:

~~~text
$ cast detect results/run1-signals.parquet --truth results/run1-truth.jsonl
 detector  found  precision  median_ttd_s  quiet_alarmed_%
threshold    4/5      1.000          31.0             12.4
      mad    5/5      0.833          24.5             15.1
     ewma    4/5      1.000          29.0              8.9
     logs    3/5      1.000          11.0             10.2
 burn-rate   1/5      1.000         412.0              0.0
~~~

The report:

~~~text
$ cast report
step  1  holds         A/A interleaved: 1.012 (0.981 to 1.044)
step  1  holds         warm cache: 0.312 (0.287 to 0.339)
step  5  holds         trees minus power law: -0.081 (-0.103 to -0.060)
step  9  inconclusive  long builds under priority: +1.4 s (-0.6 to +3.5)
...
wrote docs/report.md: 15 of 17 as reported
~~~

Your numbers will be different. What must be true is the shape: an A/A that finds nothing, a pipeline that loses and duplicates nothing, models compared with intervals, a scheduler that doesn't need its model, a gate that refuses noise, an alert for the new repository, detectors with a time-alarmed column, and a report with at least one verdict that isn't "holds".

## Done when

- [ ] `make test` runs the Go tests with `-race` and the Python tests, and CI runs both.
- [ ] Every experiment has a `plan.toml` committed before its `results/` folder.
- [ ] Deleting the dedupe step makes a test fail; so does computing a feature from a time later than submission.
- [ ] The parity test passes on at least 10,000 recorded events.
- [ ] Stopping `castd` changes no build's outcome.
- [ ] The gate refuses at least one challenger, and the README shows it.
- [ ] The report's "what didn't work" section isn't empty.
- [ ] A reviewer can rerun the report from your README on a fresh clone with your saved data, and get the same verdicts.

## How it will be checked

Your repository's CI runs the tests and the contract checks. Then a reviewer (or you, honestly) reads each experiment's plan and checks it was committed before its results, reruns `cast report`, and picks two claims to try to break: by changing a seed, a split date, or a threshold you chose. Every "Break it" in your README must show the failing test or the wrong result, not just the passing one.

## Stretch goals

- **An ETA for the whole wait:** predict queueing time too, from the queue and the policy, and score the finish-time promise rather than the run time.
- **An autoscaler on predicted work:** add workers when the queue's predicted work, not its length, crosses a threshold. Measure it against a length-based autoscaler.
- **Cache-aware placement:** send a build to the worker whose cache is warmest for it, and measure the trade-off against waiting for that worker.
- **A second region:** two farms, one model each, and drift between them.
- **Spark or DuckDB on a month of synthetic events:** find your own COST.
