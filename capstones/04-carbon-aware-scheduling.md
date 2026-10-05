# 4. Carbon-aware job scheduling

**Field:** cloud and infrastructure · energy · **Difficulty:** medium

## Problem

The carbon intensity of electricity changes hour by hour, with how much comes from wind, sun or gas. Much computing is **deferrable**: nightly builds, ML training, batch reports, backups. Running it when and where the grid is cleaner cuts emissions at no extra energy cost. But deferral risks missing deadlines, and schedulers rarely know the grid exists.

## Who

Platform teams running batch and CI workloads, and organisations with emissions targets. Indirectly, everyone who pays for or breathes the result.

## Gap

- *Let's Wait Awhile* (Wiesner et al., Middleware 2021) showed temporal shifting can cut emissions noticeably, depending on region and flexibility.
- Production schedulers (Kubernetes, batch systems) schedule for capacity and fairness, not carbon.
- Little practical guidance exists on how to **trade deadline risk against carbon** for a mixed workload, using real, forecast-driven carbon data.

## Research question

> For a mix of deferrable jobs with deadlines, how much carbon does a forecast-driven scheduler save compared with run-immediately and simple time-of-day rules? How often, and by how much, does it miss deadlines when the forecast is wrong?

## Hypothesis and baseline

- **Baselines:**
  - (a) run immediately;
  - (b) a fixed "run at night" rule.
- **Hypothesis:** a forecast-driven scheduler saves substantially more than the night rule in regions with variable renewables. A deadline buffer keeps misses under 1%, at the cost of part of the savings.

## System

- **Runway**, extended with job deadlines and a pluggable scheduler: the job state gains "deferred until".
- **A carbon-intensity provider** that replays historical intensity data and forecasts. Public sources include the UK's free Carbon Intensity API (carbonintensity.org.uk) and published grid data from system operators such as Ontario's IESO.
- **A workload generator** with job sizes and deadlines drawn from a published cluster trace (such as Google's Borg traces) or documented synthetic distributions.
- **An analysis notebook** that computes emissions as energy × intensity, with stated energy assumptions.

## Experiment

| Variable | Values |
|---|---|
| Scheduler | Run immediately; night rule; forecast-driven; forecast-driven with a deadline buffer |
| Region trace | At least two regions with different energy mixes |
| Flexibility | Deadlines of 2 h, 8 h, 24 h |
| Forecast error | Perfect knowledge; real forecasts; forecasts with added noise |
| Load | 30%, 60%, 90% of cluster capacity |

## Measures

- Estimated grams of CO₂ per job.
- Deadline misses (count, and how late).
- Average delay.
- Cluster utilisation.
- Scheduler overhead.

## What you might find

Savings may be large in regions with variable renewables and small in steady ones. High load may erase savings, because there's no free capacity in clean hours. And forecast error may matter less than flexibility does.

## Limitations to expect

- Energy per job is estimated, not measured.
- Average versus marginal carbon intensity is a debated choice; state yours.
- Shifting by region involves data-residency and latency questions this project doesn't model.

## Skills used

Phases 1–3 (jobs, durable state, background jobs), 5 (Kubernetes, AWS), and the Python Bridge and Phase 7 (experiments and analysis).

## Read first

- Wiesner et al., *Let's Wait Awhile: How Temporal Workload Shifting Can Reduce Carbon Emissions in the Cloud*, Middleware 2021
- Verma et al., *Large-scale cluster management at Google with Borg*, EuroSys 2015
- The documentation of whichever carbon-intensity data source you use: understand how it's computed before you trust it
