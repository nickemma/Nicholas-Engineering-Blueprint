# 2. Gray-failure detection: services that watch each other

**Field:** distributed systems · AIOps · **Difficulty:** medium–high

## Problem

The worst outages often aren't crashes. They're **gray failures**: a node whose disk is slow, whose network card drops a few percent of packets, or that answers health checks perfectly while failing real requests. The failure detector says "healthy", while users and *other services* say "broken". Detection takes minutes to hours, and is usually done by a human.

## Who

SRE and platform teams running microservices, and any system whose health checks test something other than real work.

## Gap

- Heartbeats and liveness probes detect **crashes**, not degradation.
- *Gray Failure: The Achilles' Heel of Cloud-Scale Systems* (Huang et al., HotOS 2017) argues that failures look different from different vantage points, so detectors should use the observations of the components that depend on each other. *Panorama* (Huang et al., OSDI 2018) built that idea into existing systems.
- Anomaly detection on metrics (AIOps) produces many false alarms and needs labelled incidents.
- A lightweight, **peer-observation** detector that a platform team can add to its own services, and evaluate honestly against heartbeats and metric-based anomaly detection, is still missing for many stacks.

## Research question

> Can a detector that aggregates the success and latency each service *observes* when calling its dependencies catch gray failures faster than health checks and metric anomaly detection, with no more false positives?

## Hypothesis and baseline

- **Baselines:**
  - (a) Kubernetes liveness and readiness probes;
  - (b) an anomaly detector on per-service metrics (Phase 7's AIOps model).
- **Hypothesis:** peer observations detect slow-disk, partial-packet-loss and "healthy but wrong" faults sooner, because they measure real work. Requiring agreement among several observers keeps false positives low.

## System

- Runway's services, extended so that every client call records outcome and latency per dependency instance. This is a library, and middleware like Phase 1's.
- **An observation aggregator** that turns those reports into a suspicion score per instance, with a voting rule (suspect only when k of n observers agree).
- **A fault injector** for slow I/O (cgroup I/O throttling), packet loss on one instance (`tc netem`), CPU starvation, and a buggy build that passes health checks but returns errors.
- **A scorer** that compares each detector's alerts against the injected fault timeline.

## Experiment

| Variable | Values |
|---|---|
| Detector | Probes; metric anomaly detection; peer observation; peer observation plus metrics |
| Fault | None (to measure false positives); slow disk; 2%/5%/20% packet loss; CPU starvation; health-passing bug |
| Load | Low, medium, near saturation |
| Topology | 5–30 service instances |

## Measures

- Time to detect.
- Precision and recall of alerts.
- False positives per hour on healthy runs.
- Overhead: CPU and network spent on observation.

## What you might find

Peer observation might catch the health-passing bug and partial packet loss far sooner, but struggle at low load (too few observations) and with faults that affect every caller equally. Combining it with metrics might give the best precision.

## Limitations to expect

- Injected faults are cleaner than real ones.
- A small topology may hide effects that appear at scale.
- Observers can themselves be faulty.

## Skills used

Phases 1 (middleware, metrics), 2 (RPC), 5 (Kubernetes, fault injection, SLOs) and 7 (anomaly detection, precision and recall).

## Read first

- Huang et al., *Gray Failure: The Achilles' Heel of Cloud-Scale Systems*, HotOS 2017
- Huang et al., *Capturing and Enhancing In Situ System Observability for Failure Detection* (Panorama), OSDI 2018
- *Site Reliability Engineering*, Ch. 6 and 22
