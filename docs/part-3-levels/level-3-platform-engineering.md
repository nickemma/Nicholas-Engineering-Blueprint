# Level III — Platform Engineering

*A full mini-course: theory → labs → production flagship → exit criteria.*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../../README.md) — v1.1*

---

# Chapter 21 · Level III — Platform Engineering

**Weeks 16–23 · Flagship: VEYRONIX v1 · Cloud: GCP · Pre-covers: CIS 5580 (operations half); fills Penn’s platform gap**

### Overview & why it matters

Penn does not teach platform engineering directly — which is exactly why owning it publicly makes you rare among your future classmates and target roles. This level takes you from “engineer who uses Kubernetes” to “engineer who extends it,” and finishes VEYRONIX — the IDP you announced in public. Finishing an announced system is a stronger signal than starting a new one.

### Objectives / Learning outcomes

- Understand Kubernetes at the level of reconciliation loops, the API machinery, and etcd’s role — not kubectl fluency.
- Write a custom operator (CRD + controller) that is the deploy engine of a real platform.
- Operate to SLOs: golden signals, error budgets, burn-rate alerts, incident response.
- Practice secure delivery: progressive rollout, signed artifacts, supply-chain provenance.

### Prerequisites

Levels I–II (VEYRONIX injects secrets via MERIDIAN and runs services fronted by EMBER-class thinking). Basic container familiarity.

### Timeline

Eight weeks: K8s internals & operators (16–17) → IaC/GitOps (18) → identity & multi-tenancy + game day #1 (19) → observability (20) → delivery & supply chain (21) → reliability + game day #2 (22) → ship (23).

### Theory

- Kubernetes internals: reconciliation, API server, scheduler, kubelet, etcd.
- Extending K8s: CRDs, controller-runtime, informers, work queues.
- IaC & GitOps: Terraform module design, state, drift; ArgoCD; environment promotion.
- Identity & multi-tenancy: RBAC vs ABAC, workload identity, OPA/Gatekeeper.
- Observability: Prometheus internals, OpenTelemetry, SLOs & error budgets.
- Delivery & supply chain: canary analysis, rollback, SBOM, sigstore, SLSA provenance.

### Architecture concepts

- Control plane vs data plane, formally: desired vs observed state, level- vs edge-triggered logic.
- Golden paths: platforms win by making the right thing the easy thing, not by mandating.
- Multi-tenancy models: namespace-per-tenant vs cluster-per-tenant vs vcluster — the cost of each.

### Hands-on labs & assignments

- Labs: “Kubernetes the hard way” once on GCE; a GKE cluster via Terraform; veyronix-operator v0 reconciling a sample app; golden-signal dashboards with burn-rate alerts; a signed+canaried pipeline.
- Assignments: per-tenant isolation (RBAC + quotas + OPA admission); two game days with public incident reports; load-test the control plane and add shedding + priority.

### Production project — VEYRONIX v1

A provider-agnostic internal developer platform: one workflow (git push → production URL with TLS, dashboards, rollback, in < 10 minutes) hiding GKE, Cloud Run, and a VPS behind pluggable providers; a Go control plane with a reconciler; the veyronix-operator for the Kubernetes provider; secrets injected via MERIDIAN (your platform eating your platform); a Next.js console with catalog, deploy timeline, SLO view, and audit trail. Full charter in Part VI.

### Reading — tiered

- **Required:** Production Kubernetes (Rosso et al.) · Programming Kubernetes (for the operator weeks) · Google SRE ch. 1–14 (selective).
- **Recommended:** Kubernetes Up & Running (fast first pass) · Terraform: Up & Running (reference).
- **Papers:** Borg · “Borg, Omega, and Kubernetes” · Dapper · Zanzibar · the SLSA framework docs.
- **Blogs:** the CNCF blog, Google/Cloudflare postmortems (analyze two). **RFCs/specs:** the Kubernetes API conventions; OpenTelemetry spec. **Repos:** controller-runtime; a small real operator.

### Open source tasks

Ladder Stages 5–7: writing tests (Month 3) then a feature (Month 4). Kill a flaky test and document it — maintainers remember that. Design-comment before coding the feature.

### Deliverables

- **GitHub:** veyronix-operator public Wk17; both incident reports published (Wk19, Wk22).
- **Portfolio:** VEYRONIX with the 10-minute “scaffold → URL” demo video.
- **Blog:** post #3 — “One Deployment Workflow for Every Provider: Finishing the IDP I Announced” + the package.

### Interview topics unlocked

How reconciliation works; writing an operator; RBAC vs ABAC; SLOs and error budgets; canary + rollback; supply-chain security; “design a CI/CD system / a multi-tenant platform / an internal PaaS.”

### Weekly schedule

Chapter 14 default; **applications open Week 18** at 10–15/week, each mapped to the platform/tooling segment (Shopify, Stripe, HashiCorp, Canonical). Game-day weeks merge a morning block into the exercise.

### Exit criteria

- VEYRONIX v1: git push → production URL < 10 min, across at least two providers, with rollback and SLO dashboards.
- Two public incident reports; signed, canaried pipeline; Meridian-Standard docs.
- First OSS feature merged; applications flowing since Wk18.

### Reflection questions

What did writing an operator teach about Kubernetes that using it hid? Which game-day failure surprised you? Where did “golden path” beat “more options”?
