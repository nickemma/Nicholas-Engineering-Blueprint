# Design: a deployment orchestrator with progressive rollouts

**Track:** platform · **Built in:** [Phase 5](../../lessons/05-constrained-operations/README.md) (Helm, canaries, CI/CD by digest, a controller), [Phase 7, step 1](../../lessons/07-utility-evaluation/TEACHING.md#step-1-experiments-done-right) (telling a change from noise) · **Time:** 45 minutes

This is a worked reference. Do the design yourself first, with a timer, then read this and note what you missed.

## 0. The crux

**Deciding automatically, and correctly, whether a new version is healthy**, from a small slice of traffic and in minutes, then rolling back safely when it isn't. The statistics of a small canary are the hard part. So are database changes, which make "roll back" harder than redeploying the old image.

## 1. Requirements

**Functional**

1. Deploy a built artifact (by digest) to one or more clusters.
2. Roll out progressively: canary, then a percentage ramp, then everyone.
3. Analyse each stage against the service's SLOs; promote or roll back automatically.
4. Manual approve, pause and roll back; a full audit trail.

**Non-functional**

| Property | Target |
|---|---|
| Scale | 500 services, 3 regions, ~200 deploys a day |
| Rollback | Traffic back on the old version within 5 minutes of detection |
| Safety | A bad version reaches at most 5% of traffic before automatic rollback |
| Availability | The orchestrator being down must not affect running services |

**Out of scope:** building artifacts (CI does that), feature flags (a separate system, mention it).

## 2. Estimates

The scale is small: 200 deploys a day is one every 7 minutes. **Storage and compute aren't the problem; statistics are.**

Take a service at 1,000 requests a second with a 1% canary. That's 10 requests a second, or 6,000 in 10 minutes. If the error rate rises from 0.1% to 0.5%:
- **Expected errors in 10 minutes:** 6 under the old version, 30 under the new one. That's detectable.
- **The same comparison for a service at 10 requests a second:** 60 requests in 10 minutes and 0.06 expected errors. **Nothing** is detectable.

**Low-traffic services need a bigger canary, a longer bake time, or synthetic traffic.** A fixed "1% for 10 minutes" policy is wrong for most of the fleet.

## 3. API

- `POST /releases {service, digest, strategy}` creates a release.
- `POST /releases/{id}/pause | resume | rollback | approve`.
- `GET /releases/{id}` returns the stage, analysis results and events.

## 4. Core entities

- **Release:** service, digest, strategy, state, created by.
- **Stage:** weight, bake time, analysis verdict.
- **Analysis:** metrics, canary versus baseline, decision, evidence.

## 5. High-level design

~~~mermaid
flowchart LR
    CI[CI: build once, sign, push by digest] --> API[Orchestrator API]
    API --> DB[(PostgreSQL: releases, stages, audit)]
    CTRL[Rollout controller] --> DB
    CTRL -->|desired state| AG1[Cluster agent, region 1]
    CTRL -->|desired state| AG2[Cluster agent, region 2]
    AG1 -->|weights| MESH1[Traffic split: gateway / mesh]
    AN[Analysis worker] -->|queries| PROM[(Metrics)]
    AN --> DB
~~~

- **The rollout controller** is a reconciliation loop. For each active release, it compares the desired stage with what the clusters report, and moves one step.
- **Each cluster's agent pulls its desired state.** The control plane never needs to reach into clusters, and if it's down, clusters keep running what they have.
- **Traffic is split by weight** at the gateway or mesh, between a **canary** and a **baseline**. The baseline is a fresh copy of the old version, started at the same moment.

## 6. Deep dives

### 6.1 Deciding health (the crux)

- **Compare the canary with a baseline started at the same time, not with last week.** Fresh pods behave differently from old ones (cold caches, JIT warm-up), and both see the same traffic and the same dependencies. Comparing canary against a fresh baseline cancels most of that out. Phase 7 learned the same lesson as **A/A runs** and **interleaving**.
- **Use SLO metrics:** error rate and latency percentiles, and saturation as a guardrail.
- **Each check is a statistical test with a minimum sample size.** "Not enough data yet" is a verdict that **extends the bake**; it isn't a pass.
- **Decide margins in advance**, as Phase 7's experiment plans did: "fail if the canary's error rate exceeds the baseline's by more than 0.2 points with 95% confidence".
- **Multiple comparisons:** checking ten metrics every minute finds a "failure" by chance. Use few metrics, and correct for the number of looks.
- **The ramp:** 1% → 5% → 25% → 100%, each with a bake time scaled to traffic (section 2). Any failure rolls back to 0% at once.

### 6.2 Rollback, and the database

- **Rolling back traffic is easy:** set the canary's weight to 0. It takes seconds, because the baseline is already running.
- **Rolling back schema isn't.** A migration that drops a column can't be undone by redeploying old code. So enforce **expand and contract**:
  1. add the new column;
  2. deploy code that writes both and reads the new;
  3. backfill;
  4. deploy code that reads only the new;
  5. **in a later release**, drop the old.

  Every step is safe to roll back. The orchestrator refuses a release whose migrations aren't backwards-compatible (checked in CI).

### 6.3 The control plane failing

The agents hold the last desired state and keep it. A release mid-ramp **pauses** where it is: it doesn't roll forward, and doesn't roll back. Manual break-glass (applying a previous manifest directly) is documented and audited.

## 7. Trade-offs

| Decision | Chose | Instead of | Because | Revisit when |
|---|---|---|---|---|
| Comparison | Canary against a fresh baseline | Canary against history | Cancels warm-up, time-of-day and dependency noise | Traffic can't support three versions at once |
| Delivery | Agents pull | Control plane pushes | Clusters run on when the control plane is down; no inbound access needed | — |
| Policy | Bake time scaled to traffic | A fixed bake time | Low-traffic services can't produce evidence in 10 minutes | — |
| Migrations | Enforced expand and contract | Trusting teams | Rollback must always be possible | — |

## 8. Failure modes

| Failure | Effect | Detection | Mitigation |
|---|---|---|---|
| A bad version | Errors in the canary slice | Analysis fails | Automatic rollback to 0% |
| A slow-burn bug (memory leak) | Passes analysis, fails hours later | SLO burn alerts | Keep the previous version's images and manifests ready; one-click rollback; longer final bake for risky services |
| Noisy metrics | False rollbacks (annoying) or false passes (dangerous) | Rollback rate per service | A/A checks of the analysis itself; minimum sample sizes |
| Orchestrator down | Releases pause; services unaffected | Its own SLOs | Pull-based agents; break-glass runbook |
| A dependency outage during a canary | Both canary and baseline degrade equally | Baseline also failing | Compare against the baseline, so the canary isn't blamed |

## 9. With more time

- **Feature flags,** to separate deploy from release.
- **Deploy freezes and approvals by risk.**
- **Automatic rollback on SLO burn after full rollout.**
- **Multi-region ordering:** one region first, then the rest.

## 10. Where you've built this

- [Phase 5](../../lessons/05-constrained-operations/README.md):
  - Helm with hooks and safe rollouts;
  - a canary;
  - CI/CD that builds once and deploys by digest;
  - a reconciliation controller with least-privilege RBAC;
  - SLOs and burn-rate alerts.
- [Phase 3](../../lessons/03-durable-auditable-data/README.md): migrations.
- [Phase 7, step 1](../../lessons/07-utility-evaluation/TEACHING.md#step-1-experiments-done-right): A/A noise, interleaving, intervals and margins: the statistics this design depends on.

## 11. What an interviewer will push on

- "Your canary gets 3 requests a minute. What does the analysis do?"
- "The new version adds a column. How does rollback work?"
- "What happens if the orchestrator dies halfway through a ramp?"
- "How do you know your analysis isn't just rolling back noise?"
