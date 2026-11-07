# Phase 5 assessment: A service another person can operate

Use the [assessment and ownership track](../ownership/README.md) to choose a route. Complete the existing phase exercise and self-test as well as the selected assignment. These are independent tasks with acceptance contracts, not solution code.

## Common readiness gate

Deploy on the phase's supported local environment, locate its telemetry and demonstrate a rollback and recovery drill. Distinguish offline cloud planning from an applied deployment.

Record the baseline/submitted commits, reproduction commands, actual results and limits. Apply the [review rubric](../ownership/reviews.md); unresolved critical correctness or safety findings block readiness for the affected capability.

## Junior: bounded independent tickets

Choose one ticket at a time. Agree its scope with a reviewer, implement without copying a guide solution, and correct review feedback. Split the ticket if it exceeds a session or two. Existing behaviour outside its contract must remain covered.

1. **Useful health check.** Add a focused check for one documented readiness dependency; distinguish an unavailable dependency from a crashed process.
2. **Runbook correction.** Have a reviewer execute one recovery instruction and correct a reproduced missing command or prerequisite.
3. **Alert evidence.** Trigger one existing alert with a bounded synthetic failure, show recovery and document what user impact the alert represents.

**Ready when:** the selected ticket's positive and negative/isolation checks pass, the diff is small and understandable, the learner explains it without the guide, and the reviewer can reproduce the documented result. A solo attempt is recorded as self-reviewed, with external feedback pending.

## Intermediate: investigate, change and operate

“Latency got worse after deployment, but CPU looks normal.” Investigate an unfamiliar operational baseline. Gather evidence before proposing scaling or new infrastructure.

Use the [investigation and rollout templates](../ownership/templates.md). The evaluator supplies a working baseline and a reproducible symptom, not the diagnosis. Record ambiguities and agree answers before coding.

- Compare pre/post-release latency, offered load, errors and relevant saturation. Eliminate at least one competing explanation.
- Canary a compatible change with explicit capacity, monitoring window and abort thresholds; demonstrate rollback under continuing traffic.
- Audit one pinned dependency/image update for compatibility and security risk, run its checks and start the twelve-week ownership record.

**Ready when:** the diagnosis is evidenced, the agreed checks above pass, and another person can follow the change/recovery instructions. Include capacity, monitoring and rollback evidence appropriate to this phase; label anything not exercised. Use independent unfamiliar code where possible and disclose prior knowledge/help.

## Senior: decide, coordinate and review

Choose a reliability/cost policy for a service with a fixed monthly resource budget and a short maintenance window. Negotiate availability expectations and compare capacity, admission control and architectural changes.

- Assign API/platform/on-call roles, escalation and release authority; keep synthetic role exercises distinct from real operational responsibility.
- Approve a staged rollout and a disaster-recovery exercise against agreed RPO/RTO; explain what you decline to promise within budget.
- Review another contributor's operational change and begin the sustained ownership exercise, including later budget and reliability reassessment.

**Ready when:** a reviewed decision explains the selected and rejected options, the implementation meets the relevant junior/intermediate safety checks, delivery/recovery ownership is explicit, and review objections have recorded resolutions. Actual collaboration is required for a collaboration verdict; solo role-play remains rehearsal.

Continue the [twelve-week ownership exercise](../ownership/sustained.md) alongside this phase. Phase completion does not establish sustained ownership until that evidence exists.

Use the [artifact templates](../ownership/templates.md) and retain the [review record](../ownership/templates.md#review-record) in your own Runway repository. Record `ready`, `needs revision` or `not assessed` per route, rather than assigning yourself a job title.
