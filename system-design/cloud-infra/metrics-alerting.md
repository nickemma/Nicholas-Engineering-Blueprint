# Design: a metrics and alerting system

**Track:** cloud-infra · **Built in:** [Phase 5](../../lessons/05-constrained-operations/README.md) (Prometheus, SLOs, burn-rate alerts), [Phase 7](../../lessons/07-utility-evaluation/README.md) (anomaly detection) · **Time:** 45 minutes

This is a worked reference. Do the design yourself first, with a timer, then read this and note what you missed.

## 0. The crux

Three things:
- **Ingest a firehose of tiny samples** (hundreds of thousands a second), and store them compactly enough to query weeks of history quickly.
- **Survive cardinality explosions:** one bad label shouldn't take the whole system down.
- **Alerting must keep working when the things it watches are broken:** a monitoring system that fails with the outage is worse than none.

## 1. Requirements

**Functional**

1. Collect metrics from every host and service.
2. Query them for dashboards: ranges, rates, percentiles.
3. Evaluate alert rules continuously, and notify the right people, once.

**Non-functional**

| Property | Target |
|---|---|
| Sources | 10,000 hosts, ~1,000 active series each: 10 million series |
| Resolution | One sample every 15 seconds |
| Retention | 15 days at full resolution; 1 year downsampled |
| Query latency | A 24-hour dashboard panel in under 2 s |
| Alert latency | A rule fires within 1 minute of the condition |
| Availability | Alerting at 99.99%, higher than anything it watches |

**Out of scope:** logs and traces (mention how they'd join), billing.

## 2. Estimates

- **Ingest:** 10⁷ series ÷ 15 s ≈ 670,000 samples a second.
- **Bytes per sample:** with Gorilla-style compression (delta-of-delta timestamps, XOR'd floats), about 1.4 bytes a sample (Facebook's Gorilla paper reports 1.37).
- **A day at full resolution:** 670,000 × 86,400 ≈ 5.8 × 10¹⁰ samples × 1.4 B ≈ 80 GB.
- **15 days:** ~1.2 TB; ~2.4 TB with two copies.
- **A year downsampled** to 5-minute points, keeping min, max, sum and count: 10⁷ series × 105,000 points × 4 values × ~1.4 B ≈ 6 TB, in object storage.
- **Memory:** each active series costs a few kilobytes in the in-memory head. 10⁷ × 3 KB ≈ 30 GB, split over the shards.

**What this decides:**
- One machine can't do it, but **ten shards of ~1 million series** each can, doubled for redundancy.
- Long-term data goes to **object storage**: cheap, and with no disks to manage.

## 3. API

- **Ingest:** scrape (`GET /metrics` on every target) or remote-write (push).
- **Query:** a PromQL-like language over HTTP.
- **Rules:** YAML in Git, deployed by CI after unit tests (`promtool test rules`).

## 4. Core entities

- **Series:** a metric name plus labels.
- **Sample:** (timestamp, value).
- **Block:** two hours of compressed samples for many series, plus an index.
- **Rule:** an expression, a duration and labels.
- **Alert:** firing or resolved.

## 5. High-level design

~~~mermaid
flowchart LR
    T[Targets: hosts and services] -->|scrape| P1[Collector shard 1, A and B]
    T -->|scrape| P2[Collector shard N, A and B]
    P1 -->|blocks every 2h| OS[(Object storage)]
    P2 --> OS
    C[Compactor and downsampler] --> OS
    Q[Query layer: fan out, deduplicate] --> P1
    Q --> P2
    Q --> SG[Store gateway] --> OS
    P1 -->|alerts| AM[Alertmanager cluster]
    P2 --> AM
    AM --> N[Pager, chat]
    W[Watchdog: always-firing alert] --> EXT[External dead man's switch]
~~~

**The pieces:**
1. Each **collector shard** scrapes its share of targets (assigned by a hash of the target), as a pair (A and B) for redundancy.
2. A shard writes samples to a **write-ahead log**, keeps the last two hours in memory, then writes an immutable **block** to local disk and uploads it to object storage.
3. **Queries** fan out to the shards for recent data and to a store gateway for older blocks, then deduplicate the A/B copies.
4. **Rules** are evaluated next to the data, in each shard, so alerting doesn't depend on the query layer.

## 6. Deep dives

### 6.1 Storing samples compactly (the crux, part 1)

- **Time-series compression:**
  - timestamps arrive at near-regular intervals, so store the **delta of the delta**, usually zero, in a bit or two;
  - values change slowly, so XOR each with the previous and store only the meaningful bits.

  Together they take a 16-byte sample down to ~1.4 bytes.
- **An inverted index** maps each label pair (`job="api"`) to its series. A query intersects the lists, the way a search engine intersects words.
- **Immutable two-hour blocks** make compaction (merging into larger blocks), downsampling and deletion simple file operations.

### 6.2 Cardinality (the crux, part 2)

One deployment that adds `user_id` as a label creates millions of series and exhausts the shard's memory. Defences, in layers:
- **Per-target sample limits:** a scrape returning more than *N* series is rejected and alerted on.
- **Per-tenant series limits** in a multi-tenant setup.
- **A cardinality dashboard** (top metrics by series count), and review of label changes in code review.
- **Shard by target**, so one bad service exhausts one shard, not all.

### 6.3 Alerting that survives the outage (the crux, part 3)

- **Rules run in the shards,** in pairs. If one copy dies, the other still fires.
- **Alertmanager runs as a cluster.** It deduplicates the two copies of each alert, groups related alerts (one page for "20 instances down", not twenty) and routes them.
- **A watchdog alert always fires.** An **external** service pages if it *stops* arriving, so a dead monitoring system is noticed. That's the dead man's switch.
- **Alert on symptoms:** SLO burn rates over multiple windows, not CPU thresholds (Phase 5).

### 6.4 Push or pull?

| | Pull (scrape) | Push (remote-write) |
|---|---|---|
| Knows a target is down | Yes: the scrape fails (`up == 0`) | Only by absence |
| Short-lived jobs | Miss them | Fine |
| Firewalls, NAT | Hard | Easy |

**Chosen: pull for services and hosts; push for batch jobs and remote sites.**

## 7. Trade-offs

| Decision | Chose | Instead of | Because | Revisit when |
|---|---|---|---|---|
| Long-term storage | Object storage | Bigger disks on collectors | Cheap, durable, no capacity planning | Query latency on old data matters a lot |
| Redundancy | Two independent collectors per shard | Replicating one collector's writes | Simple, with no coordination; deduplicate at query time | Storage cost of two copies is too high |
| Rule evaluation | In each shard | A central ruler | Alerting doesn't depend on the query path | Rules need data from several shards (then add a ruler, and accept the dependency) |

## 8. Failure modes

| Failure | Effect | Detection | Mitigation |
|---|---|---|---|
| A collector dies | Its twin keeps scraping and alerting | `up` of the collector, from the twin | Pairs; restart replays the WAL |
| A cardinality bomb | One shard runs out of memory | Series count per target | Sample limits; per-shard isolation |
| Object storage slow | Old dashboards slow; recent data and alerts unaffected | Store-gateway latency | Caching; the hot path never touches it |
| The whole monitoring cluster dies | Nobody is paged... | The external dead man's switch | Run the watchdog's receiver somewhere else entirely |
| A query of death (a year, every series) | Query layer overloaded | Query cost metrics | Limits on series and samples per query; time-outs |

## 9. With more time

- Logs and traces linked by trace ID (exemplars).
- Recording rules to precompute expensive queries.
- Multi-tenancy with per-tenant limits.
- Anomaly detection for things nobody wrote a rule for (Phase 7, step 12).

## 10. Where you've built this

- [Phase 5](../../lessons/05-constrained-operations/README.md):
  - Prometheus on Kubernetes, scraping Runway;
  - SLOs with multi-window burn-rate alerts, unit-tested with `promtool`;
  - a game day.
- [Phase 7, step 12](../../lessons/07-utility-evaluation/TEACHING.md#step-12-finding-incidents-nobody-wrote-a-rule-for): detectors scored against injected incidents and against the burn-rate alerts.

## 11. What an interviewer will push on

- "Why not just put it all in a relational database?" (Write rate and compression: 670,000 rows a second.)
- "A team adds a label with request IDs. Walk me through the next ten minutes."
- "How do you know your alerting works?"
- "Pull or push for a fleet of phones?"
