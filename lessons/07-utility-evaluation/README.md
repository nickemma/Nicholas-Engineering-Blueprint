# Phase 7: measure and learn

**Question:** is Runway actually any good, how would you prove a change made it better, and can its own record of everything it has done make it better still?

**Time:** about 10 weeks. **Prerequisites:** [Phase 6](../06-safe-shared-queries/README.md), with its kind cluster and Compose services; `uv` and `kload` from the [Python Bridge](../python-bridge/README.md); Java 17 or newer, for Spark in step 4. No GPU: every model trains on a laptop CPU in minutes. Kafka runs on kind, so the data comes from the cluster the models serve on.

## Syllabus

| Step | Topic | You'll learn |
|---|---|---|
| 1 | Experiments done right | The experimental unit; A/A runs and the noise floor; interleaving; bootstrap confidence intervals; permutation tests; effect sizes and margins; plans written first; multiple comparisons and peeking, simulated |
| 2 | Jobs that do real work | Fixed and proportional cost; contention and CPU limits; event time vs processing time; unknown is not zero; readers before writers; Poisson arrivals and log-normal sizes in a workload generator |
| 3 | A data contract and an event pipeline | Versioned JSON Schema contracts; Kafka to Parquet; partitioning by event time; write, then commit; deduplication; quarantine; late events; backfill; reconciling two records of the same facts; DuckDB |
| 4 | Big data, honestly | MapReduce from scratch: splits, shuffle, partitioning, combiners, algebraic vs holistic aggregates, skew, stragglers and speculation; Spark locally; McSherry's COST, and why one machine wins here |
| 5 | The dataset and the baselines to beat | Point-in-time features and leakage, caught by a test; late labels; splits in time; median and power-law baselines; MAE, MAPE's trap, log error, rank correlation; quantiles, pinball loss and coverage; paired block bootstraps |
| 6 | Gradient-boosted trees, honestly compared | Feature pipelines; gradient boosting; quantile regression; tuning without leaks (time-ordered folds); conformal calibration; slices; permutation importance |
| 7 | Neural networks, from scratch and in PyTorch | Backpropagation by hand; gradient checking; standardisation; embeddings; Adam and early stopping; spread across seeds; the cost of a prediction |
| 8 | Serving predictions | Online vs offline features and a parity test that found a real leak; train/serve skew, measured; which clock a feature may use; a model as an artifact; timeout, breaker and fallback in Go; mTLS through Phase 6's sidecar; cost per call under contention |
| 9 | Using the predictions | Shortest job first; work-conserving vs reserved lanes; planning by work, not count; starvation; simulate, then measure; a feedback loop between predictions and load |
| 10 | Models with a history | Experiment tracking with MLflow; a registry with aliases; reproducible training; champion and challenger; a gate beyond noise, with guardrails; model cards; promotion and rollback |
| 11 | Watching a model in production | Data, concept, prediction and label drift; PSI and KS; out-of-range and unseen inputs as an alert; drift isn't damage; a shadow deployment; retraining for a new tenant |
| 12 | Finding incidents nobody wrote a rule for | Injected incidents as ground truth; precision, recall, time to detect, time alarmed; threshold, MAD, EWMA and an isolation forest; minimum changes; Drain log templates; symptoms vs causes; why the burn-rate alerts stayed quiet; a held-out test predicted in advance |
| 13 | The report | Claims as code; replication on new data; three verdicts, not two; negative results; threats to validity; provenance |

## What you'll be able to do

- Design an experiment on a noisy machine, write its plan first, and say with an interval whether a change made a difference that matters.
- Give a system a workload that models its users, and measure what limits it.
- Define a data contract, and move events from Kafka into partitioned Parquet without losing, duplicating or silently dropping any.
- Explain what MapReduce and Spark do, and show when one good machine beats a cluster.
- Build a training set with no leakage, pick the error metric for the use, and set the baselines a model must beat.
- Fit and compare gradient-boosted trees and neural networks honestly: paired, with intervals, per slice, and with their cost.
- Serve a model behind a Go API so that a slow or dead model server costs the users nothing, and prove the served features match the training ones.
- Use predictions to schedule, and measure whether they helped, and whom.
- Track, register, gate, promote and roll back models, and write the card that says where a model can be trusted.
- Notice drift, tell drift from damage, and test a challenger in the shadow.
- Score anomaly detectors on metrics and logs against incidents you injected, and explain why they and the SLO alerts disagree.
- Write a report that re-tests its own conclusions, and say plainly which ones didn't hold.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md), typing every piece of code yourself, starting from your Phase 6 code.
2. Do every "Run it" and every "Break it" on your own machine. Your numbers will differ from the guide's, more than in earlier phases, because this phase measures. Compare the shapes: which conditions differ, roughly by how much, and which don't. A disagreement is a finding, not a failure.
3. Answer [learned.md](learned.md).
4. Build the exercise project, **[buildcast](exercises.md)**, on your own. It predicts build times for a shared build farm. The exercise page shows exactly what finished looks like.
5. Take the [self-test](../../notes/learned/07-utility-evaluation.md).

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where | Evidence |
|---|---|---|
| Measurement and experimental method (row 10) | Steps 1, 9, 12, 13 | A/A runs; interleaved experiments with bootstrap intervals; a pre-registered prediction; the report's verdicts |
| Data engineering and big data (row 31) | Steps 3, 4 | The Kafka-to-Parquet pipeline with its contract; MapReduce from scratch; the COST grid |
| ML, deep learning, MLOps, AIOps (row 32) | Steps 5–12 | Baselines, trees and networks compared with intervals; the registry and its gate; drift checks and a shadow; scored anomaly detectors |
| Python and its tooling (row 9) | Every step | The `lab` project: `uv`, extras, a locked environment, tests in CI |
| SQL, indexes, query plans (row 15) | Steps 3, 4 | DuckDB over Parquet; Spark's plan |
| Observability and SLOs (row 26) | Steps 8, 11, 12 | Prediction outcome metrics; the unusual-inputs alert; detectors against burn-rate alerts |
| Research method and technical writing (row 34) | Steps 1, 13 | Plans written first; the rerunnable report with its negative results and limits |

## Patterns introduced

These link to the [patterns ledger](../../JOURNEY.md#6-patterns-ledger):
- feature pipeline with train/serve parity;
- model registry, champion and challenger, and shadow deployment;
- a fallback for an optional dependency in the request path (timeout, breaker, no prediction);
- priority lanes from predictions;
- claims as code: a report that re-tests itself.

## Next

You have every tool now: building, connecting, storing, replicating, operating, securing and measuring. The [capstone](../../capstones/README.md) asks you to use them on a research question nobody has answered for you.
