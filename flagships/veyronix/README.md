# VEYRONIX — the journey

The system lives at **https://github.com/nickemma/veyronix**. Partly built and publicly announced before this standard existed.
Its architecture, API, threat model, runbook, and benchmark results live there, current
as of `main`. This directory holds what the code cannot: intent, prediction, surprise,
and judgment.

- Charter (frozen intent) — [/docs/part-6-flagships/veyronix.md](../../docs/part-6-flagships/veyronix.md)
- Repository standard — [Chapter 40b](../../docs/part-6-flagships/repo-standard.md)
- [calibration.md](calibration.md) — every prediction, predicted beside actual
- [as-built.md](as-built.md) — written at level exit, never before
- Detours triggered by this build — [/detours](../../detours)

**Status:** ◐ in progress — charter freezes late; see Chapter 40b §8

## Behavior ladder (Module 3)

Charter point 3 decomposed into shippable increments. Written at kickoff; see
[Chapter 40b §5](../../docs/part-6-flagships/repo-standard.md).

| | Behavior | Satisfies charter point 3 |
|---|---|---|
| B1 | a hand-assembled cluster boots and schedules a pod | — (understanding, not shipped) |
| B2 | a CRD + controller reconciles one field | Kubernetes provider as an operator |
| B3 | `git push` creates infrastructure via Terraform; drift detected | everything GitOps after Wk17 |
| B4 | ArgoCD promotes dev → staging → prod; bad manifest rejected | one workflow, pluggable providers |
| B5 | two tenants share a cluster; neither starves nor reads the other | RBAC/ABAC · per-tenant isolation, quotas |
| B6 | golden-signal dashboards + burn-rate alerts page before users notice | observability (points 17–18) |
| B7 | a deliberately bad release canaried, detected, auto-rolled-back | health verification · automatic rollback |
| B8 | control plane sheds load instead of dying | control plane sustains concurrent deploys |
| B9 | `git push` → production URL under 10 min, two providers | non-functional requirement 4 |


## Session log

| # | Date | Shipped | Tag | Detours | Loose end |
|---|---|---|---|---|---|
