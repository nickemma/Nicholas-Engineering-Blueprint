# VEYRONIX — Internal Developer Platform

*Organization-grade project charter (24-point standard).*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../../README.md) — v1.1*

---

# Chapter 44 · VEYRONIX — Internal Developer Platform

**Level III · Weeks 16–23 · GCP · Consumes: MERIDIAN (secrets) · Provides: platform/operations patterns for TESSERA**

### 1–2 · Vision & problem

Developers waste days on deployment, config, and infrastructure toil. An internal developer platform makes shipping a single golden path. VEYRONIX — the IDP you announced publicly — delivers git push → production URL across multiple providers, with the platform handling auth, secrets, health, rollback, and observability.

### 3 · Functional requirements

- One workflow deploys to GKE, Cloud Run, or a VPS via pluggable providers.
- Authentication (OIDC), RBAC/ABAC, per-tenant isolation and quotas.
- Secret injection (via MERIDIAN); health verification; automatic rollback; full audit trail.
- CLI (five verbs) + console (catalog, deploy timeline, SLO view, logs).

### 4 · Non-functional requirements

- Scaffold → production URL (TLS, dashboards, rollback) in < 10 minutes.
- Reconcile latency p99 low; control plane sustains concurrent deploys; SLOs defined before features.

### 5–6 · Constraints & trade-offs

- **Constraint:** everything GitOps after Wk17 — the repo is the source of truth; the Kubernetes provider is an operator (CRD + controller).
- **Trade-off:** provider-plugin abstraction (extensibility, more upfront design) vs hard-coding GKE (faster, brittle) — chose the abstraction; it’s the whole value proposition.
- **Trade-off:** namespace-per-tenant (simpler, weaker isolation) vs cluster-per-tenant (stronger, costlier) — chose namespace + OPA for v1; documented.

### 7–9 · Architecture / sequence / component (described)

- **Architecture:** CLI/console → control plane (API + reconciler) → provider plugins (gke/cloudrun/vps); veyronix-operator reconciles the K8s provider; MERIDIAN injects secrets; audit + observability throughout.
- **Sequence (deploy):** git push → API creates release → reconciler drives desired state → provider applies → secrets injected → health check → (pass) traffic shifted / (fail) auto-rollback → audit event + timeline update.
- **Component:** api · reconcile · providers · operator · auth · secrets · audit · console.

### 10–11 · Schema & API

- **Postgres:** tenants · users · apps · releases · deployments(status,provider,health,rollback_of) · providers · secrets_bindings · audit_events(append-only).
- **API:** POST /v1/apps · POST /v1/apps/{id}/deployments · POST /v1/deployments/{id}/rollback · GET /v1/deployments/{id}/logs · GET /v1/audit. **CLI:** vx init/deploy/status/rollback/logs.

### 14–17 · Threat model, security, CI/CD, observability

- Assets: tenant workloads, secrets, the deploy pipeline. Adversaries: malicious tenant, supply-chain tampering. Controls: RBAC/ABAC, OPA admission, signed artifacts (sigstore/SLSA), secrets via MERIDIAN (never in env/plaintext), full audit.
- Observability: golden-signal dashboards, burn-rate alerts, tracing across the deploy pipeline; two documented game days.

### 19–24 · Testing, benchmarks, scale, lessons

- Testing: unit + integration + provider e2e + chaos (provider outage mid-deploy, etcd loss during reconcile). Benchmarks: scaffold→URL wall-clock, concurrent deploys, reconcile p99.
- **Scale:** more provider plugins, multi-cluster, vcluster tenancy. **Future:** preview environments, cost dashboards, policy marketplace. **Lessons:** the “finishing the announced IDP” post + two incident reports.
