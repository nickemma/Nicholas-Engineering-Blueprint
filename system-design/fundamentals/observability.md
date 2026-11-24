# Observability

Observability is being able to answer new questions about a running system from the outside, without shipping new code: is it working, for whom, and if not, why? Every design needs a sentence on it, and SRE and platform interviews need a page.

## The signals

| Signal | Answers | Cost | Tools |
|---|---|---|---|
| **Metrics** | How much, how fast, how often, over time | Cheap per event; expensive per label combination (cardinality) | Prometheus, OpenTelemetry metrics |
| **Logs** | What exactly happened in this event | Expensive at volume | Structured JSON logs, Loki |
| **Traces** | Where did this request spend its time, across services? | Sampled to control cost | OpenTelemetry, Jaeger, Tempo |
| **Profiles** | Which code is using the CPU and memory? | Low, continuously sampled | pprof |

## What to measure

- **The four golden signals** for every service: latency (as percentiles), traffic, errors and saturation.
- **RED** for request-driven services: rate, errors, duration.
- **USE** for resources: utilisation, saturation, errors.
- **SLIs and SLOs:** the few numbers that describe what users experience ("99.9% of job submissions succeed within 300 ms"), and the error budget they imply.

## Alerting

- **Alert on symptoms users feel** (SLO burn rate), not on causes (CPU at 80%).
- **Multi-window burn-rate alerts** page when the budget burns fast, and open a ticket when it burns slowly.
- Every page needs a **runbook**, and should be actionable. A page that's always ignored trains people to ignore pages.

## How it fails

- **Cardinality explosions:** a label with the user ID makes millions of series and takes the metrics system down.
- **Averages** hide the tail; dashboards of means look fine during an incident.
- **Monitoring that shares the failure:** if the alerting runs in the same cluster that's down, nobody hears about it.
- **Logging secrets or personal data.**

## In an interview

Name the SLIs and SLOs for the design, which metrics and traces show the crux working, and what pages someone at 3 a.m. Then say how you'd tell a slow dependency from a slow service: a trace.

## Where you built it

- [Core 01, lesson 11](../../2-core/01-go-runtime-and-reliable-services/lessons/11-logs-metrics-and-panic-recovery.md): structured logs and Prometheus metrics.
- [Core 08](../../2-core/08-shipping-safely/README.md) and [Kubernetes and delivery](../../3-tracks/shared-units/kubernetes-and-delivery/README.md):
  - [OpenTelemetry tracing](../../3-tracks/shared-units/kubernetes-and-delivery/lessons/07-follow-a-request-through-the-cluster.md) through the outbox and the broker;
  - [SLOs with tested burn-rate alerts](../../3-tracks/shared-units/kubernetes-and-delivery/lessons/08-alert-on-budget-burn.md);
  - a game day.
- [Core 08, lesson 04](../../2-core/08-shipping-safely/lessons/04-limit-what-the-gateway-can-read-and-record.md): a data inventory, and a canary that proves secrets and personal data stay out of the logs.
- [The AI operations deep dive](../../3-tracks/ai-infrastructure/deep-dives/aiops.md): anomaly detection scored against burn-rate alerts.
