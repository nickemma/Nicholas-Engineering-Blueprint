# Benchmarks

*Methodology first, then numbers. Report where this loses, not only where it wins.*

## Methodology

<!-- Without this section the numbers mean nothing and cannot be defended. -->

- **Hardware:**
- **Load generator:**
- **Duration / warmup:**
- **What is measured:** <!-- added latency? end to end? which percentile, over what window -->
- **What is excluded and why:**
- **Reproduce:** `make bench` <!-- must actually work from a fresh clone -->

Raw output committed under `bench/results/` as JSON, one file per run, so the trend
across the module is chartable rather than remembered.

## Targets

<!-- charter:4 - non-functional targets -->
Seeded from the charter at kickoff. Never edited — these are the predictions being
scored. Every row also exists in the blueprint's `calibration.md`.
**Status:** not measured.

| Charter target | Predicted | Latest measured | Date |
|---|---|---|---|

## Results

<!-- charter:20 - measured results -->
**Status:** not measured.

| Metric | This system | Baseline | Conditions | Run |
|---|---|---|---|---|

## Where this loses

<!-- Against the production alternative — nginx, vLLM, etcd. Be specific about the
     mechanism, not apologetic about the outcome. This section is the most credible
     thing in the repository. -->

## Flamegraphs

<!-- Before/after one real optimization. Sources in assets/. -->
