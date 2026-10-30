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

- [Phase 1, step 7](../../lessons/01-reliable-service/TEACHING.md#step-7-logs-metrics-and-panic-recovery): structured logs and Prometheus metrics.
- [Phase 5](../../lessons/05-constrained-operations/README.md):
  - [OpenTelemetry tracing](../../lessons/05-constrained-operations/TEACHING.md#step-9-tracing-with-opentelemetry) through the outbox and the broker;
  - [SLOs with tested burn-rate alerts](../../lessons/05-constrained-operations/TEACHING.md#step-10-prometheus-slos-and-burn-rate-alerts);
  - a game day.
- [Phase 6](../../lessons/06-safe-shared-queries/README.md): redaction of secrets and personal data in logs and traces.
- [Phase 7, step 12](../../lessons/07-utility-evaluation/TEACHING.md#step-12-finding-incidents-nobody-wrote-a-rule-for): anomaly detection scored against burn-rate alerts.
