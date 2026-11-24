# Platform

For platform and developer-infrastructure roles. A platform is a product whose users are engineers. These designs are about golden paths, safe change, and many teams sharing infrastructure without stepping on each other.

**Worked design:** [a deployment orchestrator with progressive rollouts](deployment-orchestrator.md). Do it yourself first, then compare.

**How to use the prompts:**
1. Set a 45-minute timer and design with the [template](../_template.md).
2. Open **the crux** only if you haven't named one by minute 10.
3. Open **what a strong answer covers** only after the timer, then score yourself with the [scorecard](../scorecard.md).

## 1. An internal developer platform

200 teams create, deploy and operate services. A new service, with CI, deployment, observability and secrets, must be running in production within a day, following the company's standards, without a ticket to another team.

<details><summary>The crux</summary>Abstraction level: hide enough of Kubernetes and the cloud that teams move fast, but not so much that they can't debug or escape when they need to. And keeping hundreds of services on the golden path as the path changes.</details>

<details><summary>What a strong answer covers</summary>

- Templates (golden paths) that generate a working service with CI, deployment, dashboards and alerts.
- A service catalogue: ownership, dependencies, on-call.
- Self-service through declarative specs (reconciled by controllers), not tickets.
- Guardrails as policy (admission control), not reviews.
- Upgrading hundreds of services: versioned templates, automated pull requests.
- Escape hatches, and the support cost of each.
- Measures of success: lead time, deployment frequency, change failure rate.
</details>

**Built in:** [Kubernetes and delivery](../../3-tracks/shared-units/kubernetes-and-delivery/README.md) (Helm, promotion by digest, a controller).

## 2. A feature-flag service

Flags evaluated in every request of 500 services: 5 million evaluations a second, under 1 ms each, targeting by user, tenant and percentage, changes live within 10 seconds, and a broken flag service must not break products.

<details><summary>The crux</summary>Evaluations must be local (no network call per evaluation) while changes propagate fast and consistently. The flag service must sit off the request path, so its failure only means "flags stop changing".</details>

<details><summary>What a strong answer covers</summary>

- SDKs hold the full flag configuration in memory and evaluate locally.
- Distribution: streaming updates (server-sent events) with periodic full sync and versioning; a local file cache for cold starts.
- Deterministic percentage rollouts: hash of (flag, user), so a user stays in the same bucket.
- Defaults compiled in, for when nothing has loaded.
- Audit log of changes; approvals for risky flags; automatic cleanup of stale flags.
- Experiments on top: exposure logging.
</details>

**Built in:** [Tenancy and abuse control](../../3-tracks/shared-units/tenancy-and-abuse-control/exercise-flagpole.md)'s exercise (flagpole: multi-tenant feature flags), [Core 02](../../2-core/02-python-runtime-and-honest-measurement/lessons/08-repeat-runs-and-confidence-intervals.md) (experiments).

## 3. Configuration management

Runtime configuration for 1,000 services in 3 regions: validated, versioned, rolled out gradually, rolled back in seconds; secrets kept separate.

<details><summary>The crux</summary>A bad configuration change is the most common cause of large outages. Configuration needs the same safety as code: validation, staged rollout, fast rollback, and blast-radius limits.</details>

<details><summary>What a strong answer covers</summary>

- Configuration as code in Git; schema validation in CI.
- Versioned snapshots distributed to services (pull, with caching), never partial updates.
- Staged rollout by region or percentage, with health checks between stages.
- Rollback = point back to the previous version.
- Services keep the last good configuration when the config service is down.
- Secrets through a secrets manager, referenced (not embedded) by configuration.
</details>

**Built in:** [Core 01, lesson 09](../../2-core/01-go-runtime-and-reliable-services/lessons/09-wiring-and-configuration.md), [Kubernetes and delivery, lesson 05](../../3-tracks/shared-units/kubernetes-and-delivery/lessons/05-roll-out-a-canary-with-helm.md) (Helm values), [Core 08, lesson 04](../../2-core/08-shipping-safely/lessons/04-limit-what-the-gateway-can-read-and-record.md) (secrets kept out of code).

## 4. Multi-tenant Kubernetes

One large Kubernetes platform shared by 100 teams: fair resources, isolation between teams, no team able to break another, and costs reported per team.

<details><summary>The crux</summary>Isolation in a system designed for sharing: noisy neighbours (CPU, memory, API server load), security boundaries (network, identity, privileges), and fair scheduling, all without giving each team its own cluster.</details>

<details><summary>What a strong answer covers</summary>

- A namespace per team; RBAC; resource quotas and limit ranges.
- NetworkPolicies, default-deny; Pod Security standards.
- API server protection: priority and fairness, rate limits per client.
- Node isolation for sensitive or noisy workloads (taints and dedicated pools).
- Cost allocation from requests and usage, per namespace.
- When to give a team its own cluster instead (the hard multi-tenancy limit).
</details>

**Built in:** [Kubernetes and delivery](../../3-tracks/shared-units/kubernetes-and-delivery/lessons/10-enforce-the-deployment-boundary.md) (namespaces, NetworkPolicies, Pod Security), [Tenancy and abuse control](../../3-tracks/shared-units/tenancy-and-abuse-control/README.md) (tenant isolation).

## 5. A service mesh control plane

mTLS, retries, timeouts and traffic shifting for 2,000 services, configured centrally and enforced by sidecars, with certificate rotation that never causes an outage.

<details><summary>The crux</summary>Pushing configuration and certificates to thousands of proxies consistently and safely, and keeping the data plane working when the control plane is down.</details>

<details><summary>What a strong answer covers</summary>

- Data plane (sidecar proxies) and control plane (configuration and identity) separated.
- Configuration distributed incrementally, with versions and acknowledgements.
- Workload identity (SPIFFE IDs); a CA that issues short-lived certificates; rotation with overlapping trust.
- Proxies keep the last known configuration when the control plane is down.
- The cost of sidecars (latency, CPU, memory), and when not to use them.
- Retries in the mesh multiplied by retries in the application: retry budgets.
</details>

**Built in:** [Core 08, lesson 03](../../2-core/08-shipping-safely/lessons/03-issue-certificates-and-require-mtls.md) (your own CA and mTLS), [The proxy's control plane, lessons 03–04](../../3-tracks/cloud-and-network/03-proxy-control-plane/lessons/03-bind-management-peer-identities.md) (per-peer identity, rotation, a sidecar).
