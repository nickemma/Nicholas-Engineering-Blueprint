# 6. Drug-shortage early warning from public signals

**Field:** pharmacy · data engineering · applied ML · **Difficulty:** medium

## Problem

Medicine shortages delay treatment, force substitutions, and cost pharmacies and hospitals large amounts of staff time. Many shortages have warning signs:
- a manufacturing site gets a poor inspection result;
- a product is recalled;
- a sole supplier exits the market;
- demand spikes.

Those signals are scattered across separate public databases and reports, and nobody connects them in time.

## Who

Hospital and community pharmacists, procurement teams, and health ministries. In the end, patients.

## Gap

- Regulators publish shortage reports (the US FDA's Drug Shortages database, and Drug Shortages Canada), recalls and enforcement reports (openFDA), and some inspection results. But these are mostly *reports of shortages that are already happening*.
- Research on predicting shortages exists, but practical, reproducible pipelines that join **open** signals and measure how far ahead they help are rare.

## Research question

> Can a model trained only on public signals (recalls, enforcement actions, product discontinuations, past shortages, and the number of approved manufacturers) predict new shortages of a medicine 4–12 weeks before they're reported, better than simple baselines? Which signals carry the warning?

## Hypothesis and baseline

- **Baselines:**
  - (a) "a medicine that was short before will be short again";
  - (b) a rule on the number of approved manufacturers (sole-source products are at higher risk).
- **Hypothesis:** combining signals improves precision at useful recall, with recalls and manufacturer counts carrying most of the signal.

## System

- **A data pipeline** (Phase 7's data engineering): scheduled ingestion from public APIs and downloads, schema validation (data contracts), entity resolution across sources (matching the same drug by ingredient, strength and form), and storage in Parquet, queried with DuckDB.
- **Feature and label construction**, with strict **time-based splits**, so the model only ever sees data available *before* each prediction date. Leakage is the main methodological risk.
- **Models:** baselines, gradient-boosted trees, and a simple time-series model. Experiments are tracked with MLflow.
- **A small API and dashboard** (Go plus Runway patterns) serving weekly risk scores with explanations.

## Experiment

| Variable | Values |
|---|---|
| Horizon | 4, 8, 12 weeks |
| Model | Baselines; logistic regression; gradient boosting |
| Signals | Each signal alone; all together; all but one (ablation) |
| Jurisdiction | US data; Canadian data; train on one and test on the other |

## Measures

- Precision and recall at a fixed alert budget (for example, the top 50 alerts a week).
- Area under the precision–recall curve.
- Lead time gained.
- Calibration.
- Pipeline freshness and reliability.

## What you might find

Lead time may be real but modest, and signals may help most for sterile injectables and sole-source products. You may also find that the hardest, most valuable part is resolving entities across sources, not the model.

## Limitations to expect

- Public data misses private supply-chain signals (orders, inventory).
- Reporting practices change over time.
- A prediction is not an intervention.

## Skills used

The Python Bridge, Phases 3 (data modelling), 5 (scheduled jobs on AWS), 7 (pipelines, ML, MLOps) and 6 (API security).

## Read first

- The documentation for the FDA Drug Shortages database, openFDA's enforcement and recall endpoints, and Drug Shortages Canada
- Kaufman et al., *Leakage in Data Mining: Formulation, Detection, and Avoidance*, KDD 2011
- Huyen, *Designing Machine Learning Systems*, Ch. 4 (training data) and Ch. 6 (evaluation)
