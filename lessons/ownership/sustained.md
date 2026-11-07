# Twelve weeks of service ownership

Start after Phase 5's operational foundation. Continue while working on later phases; do not add twelve weeks to the roadmap if they already overlap. Choose one service, a fixed synthetic workload and a cost/resource budget. Run locally by default; a cloud deployment is optional and must have its own budget and cleanup plan.

The objective is continuity: changes, monitoring, maintenance, decisions and handover over twelve actual weeks. This is a lab service, not evidence of production users or real on-call. Record actual uptime and observation windows. If it runs only during study sessions, describe it as session-based ownership rather than 24/7 availability.

## Agree before starting

Name the owner and reviewer, service boundary, current release, objective, workload, budget, maintenance window and recovery definition. Define a small number of useful measures: offered/successful requests, user-visible latency, errors, queue/resource saturation, recovery and resource/cost consumption. Predeclare when to roll back, shed work or stop an experiment.

Keep weekly records using the [ownership template](templates.md#weekly-ownership-record). A dashboard screenshot without the covered dates and raw/query evidence is insufficient. No incident is required to occur naturally: clearly label injected faults and scheduled exercises. Do not manufacture a production story.

## Schedule

| Actual week | Required event | Evidence to retain |
|---|---|---|
| 1 | Baseline and ownership agreement | Contract, release, reproducible workload, objective, budget and named owners |
| 2 | First small compatible release | Review, positive/negative checks, observed rollout and tested rollback |
| 3 | Dependency maintenance | Dependency inventory; one version/security-notice assessment, chosen action or justified deferral, upgrade checks |
| 4 | Unfamiliar incident | Evaluator-supplied symptom, investigation record, detection/recovery times and postmortem |
| 5 | Requirement negotiation | A peer changes a requirement; revised scope, acceptance contract and deferred work |
| 6 | Mixed-version change | Old/new coexistence checks, migration/backfill where applicable and recovery rehearsal |
| 7 | Capacity and cost review | Repeatable load test; measured headroom; decision within the agreed budget |
| 8 | Help another contributor deliver | Bounded ticket delegated to an actual peer, review feedback and corrected submission; solo simulation labelled separately |
| 9 | Reliability trade-off | Compare two mitigations, including operator effort; implement or explicitly defer with rationale |
| 10 | Dependency/owner disruption | Simulate unavailable dependency or owner; exercise escalation and recovery without undocumented knowledge |
| 11 | Handover | Another person follows start/deploy/recover instructions; record failures and fix the documentation |
| 12 | Outcome review | Actual twelve-week timeline, objectives/budget versus outcomes, recurring issues, closed actions and next owner's plan |

Use synthetic identities and data. Keep load and failure injection confined to the owned lab. Do not count a planned change as a completed event. A dependency review may correctly conclude “do not upgrade yet,” provided it identifies the relevant risk, compatibility evidence, owner and revisit date.

## Route expectations

An intermediate learner owns the service changes and operational records, negotiates the week-5 contract, demonstrates mixed-version delivery and leaves a usable handover. They may seek design help, but must record what help was needed.

A senior learner additionally owns decisions and coordination: review the proposal with another stakeholder, assign clear boundaries across API/worker/platform roles, reject at least one unjustified expansion, help another contributor deliver, and revisit a cost/reliability decision using later evidence. Roles can be simulated by peers in a small group; identify which roles are simulated and which contributions are real. An unreviewed fictional stakeholder conversation cannot pass the collaboration criterion.

The junior minimum route does not require this exercise. A junior may contribute a bounded ticket under an owner's review without becoming responsible for the entire service.

## Completion

A reviewer can trace each required event to its actual date, release, evidence and decision. Required findings have owners and closure evidence; remaining work has explicit handover. The recipient can recover the service without the original owner supplying missing commands. Review the [rubric](reviews.md) against the selected route.

A weekend replay can be a useful accelerated rehearsal, labelled with its actual elapsed duration. It cannot satisfy the twelve-week continuity criterion. If no independent reviewer/contributor is available, mark the relevant criteria pending and keep the self-reviewed technical evidence; do not invent sign-off or block unrelated phase study.
