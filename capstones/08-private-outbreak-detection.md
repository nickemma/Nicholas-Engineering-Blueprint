# 8. Private outbreak detection across clinics

**Field:** mathematics (statistics, differential privacy) · medicine (public health) · **Difficulty:** medium–high

## Problem

Outbreaks are caught earlier when many clinics pool their daily counts of symptoms, a practice called **syndromic surveillance**. But small clinics in small communities report small counts, and small counts can identify patients: "one case of X in this village this week". Clinics may refuse to share, or be forbidden to. Adding statistical noise to protect privacy also makes outbreaks harder to see.

## Who

Public health agencies, community clinics and epidemiologists. In the end, the communities protected by early warning.

## Gap

- **Differential privacy** (Dwork and Roth, 2014) gives a precise, provable privacy guarantee for released counts.
- Classical outbreak detectors such as **CUSUM** and **EARS** were designed for exact counts.
- How much detection power is lost under a given privacy budget (ε), for realistic small-count surveillance, and how detectors should adapt to noisy input, is rarely quantified in a way an agency can use to choose ε.

## Research question

> For daily syndromic counts from many small clinics, released with differential privacy at budget ε, what's the smallest outbreak that can be detected within a given delay and false-alarm rate? How much of the lost power can noise-aware detectors and smarter aggregation recover?

## Hypothesis and baseline

- **Baseline:** CUSUM on exact (non-private) counts, which is the best case, and on naively noised counts.
- **Hypothesis:** naive noise severely hurts detection of small outbreaks at strict ε. Detectors calibrated to the noise distribution, plus aggregation at the regional level before noise is added, recover much of the loss for moderate ε.

## System

- **Clinic nodes** (Runway services) that compute daily counts and release them through a differential-privacy mechanism (Laplace or Gaussian), with a privacy-budget accountant so repeated releases are tracked.
- **An aggregator** (Phase 6's policy and audit patterns) that combines releases and runs detectors.
- **Detectors:** CUSUM, EWMA, and noise-aware versions with thresholds derived from the noise distribution.
- **A simulator** that injects outbreaks of controlled size and shape into realistic baseline counts. Baselines come from public, aggregate surveillance data (such as CDC's ILINet), or a documented synthetic model with weekly seasonality.

## Experiment

| Variable | Values |
|---|---|
| Privacy budget ε per release | ∞ (no noise), 2, 1, 0.5, 0.1 |
| Clinics | 10, 50, 200 small clinics |
| Outbreak | Size (cases per day added), duration, how many clinics it spans |
| Detector | CUSUM, EWMA, noise-aware variants |
| Aggregation | Per clinic before noise; regional before noise (needs a trusted aggregator: state your trust model) |

## Measures

- Probability of detection.
- Detection delay in days.
- False-alarm rate (alarms per year with no outbreak).
- The privacy budget used per year.
- The minimum detectable outbreak size at fixed delay and false-alarm rate.

## What you might find

You might find a clear "price of privacy" curve. At strict ε, single-clinic outbreaks become undetectable while multi-clinic ones remain visible. Where the noise is added, and who is trusted, may matter more than which detector you choose.

## Limitations to expect

- Synthetic outbreaks only.
- The detector set is classical.
- Real deployment needs public-health partners and ethics review.
- Differential privacy protects released counts, not systems that are breached.

## Skills used

Phases 6 (privacy, policy, audit), 7 (statistics, experiments) and 3 (durable data), plus probability and statistics.

## Read first

- Dwork and Roth, *The Algorithmic Foundations of Differential Privacy*, 2014, Ch. 1–3 (free online)
- Page, *Continuous Inspection Schemes*, Biometrika 1954 (the original CUSUM)
- Fricker, *Introduction to Statistical Methods for Biosurveillance*, Cambridge University Press, 2013, if available; otherwise a survey of syndromic surveillance methods
