# Phase 6 assessment: A second tenant without harming the first

Use the [assessment and ownership track](../ownership/README.md) to choose a route. Complete the existing phase exercise and self-test as well as the selected assignment. These are independent tasks with acceptance contracts, not solution code.

## Common readiness gate

Demonstrate authenticated allowed/denied operations, cross-tenant rejection, shared-resource limits and the phase's recovery/rotation checks. Identify the trust boundary and tenant source.

Record the baseline/submitted commits, reproduction commands, actual results and limits. Apply the [review rubric](../ownership/reviews.md); unresolved critical correctness or safety findings block readiness for the affected capability.

## Junior: bounded independent tickets

Choose one ticket at a time. Agree its scope with a reviewer, implement without copying a guide solution, and correct review feedback. Split the ticket if it exceeds a session or two. Existing behaviour outside its contract must remain covered.

1. **Cross-tenant read.** Add a negative test for a second tenant reading one existing resource; retain the positive same-tenant case.
2. **Cross-tenant mutation.** Prove a rejected update leaves both tenants' state unchanged; document the externally visible error contract.
3. **Safe diagnostic.** Improve one diagnostic without leaking a credential or tenant payload; test/document the error path and a valid request.

**Ready when:** the selected ticket's positive and negative/isolation checks pass, the diff is small and understandable, the learner explains it without the guide, and the reviewer can reproduce the documented result. A solo attempt is recorded as self-reviewed, with external feedback pending.

## Intermediate: investigate, change and operate

“Onboard another tenant next week, keeping the current tenant stable.” Clarify isolation, throughput and retention expectations in an unfamiliar service; inspect data access, caches, queues and credentials.

Use the [investigation and rollout templates](../ownership/templates.md). The evaluator supplies a working baseline and a reproducible symptom, not the diagnosis. Record ambiguities and agree answers before coding.

- Prove two-tenant read/write/cache isolation with concurrent traffic and failure cases; include old/new service versions during rollout.
- Measure existing-tenant latency/errors while the new tenant reaches its agreed capacity. Enforce admission/limits and observe cross-tenant impact.
- Stage schema/config/credential changes, test monitoring and rollback, and document key rotation plus ownership of security/dependency follow-ups.

**Ready when:** the diagnosis is evidenced, the agreed checks above pass, and another person can follow the change/recovery instructions. Include capacity, monitoring and rollback evidence appropriate to this phase; label anything not exercised. Use independent unfamiliar code where possible and disclose prior knowledge/help.

## Senior: decide, coordinate and review

Compare shared tables, separate schemas/databases and dedicated deployments for two tenants with conflicting cost, performance and isolation goals. Choose and defend a strategy, not a universal winner.

- Document required isolation, threat assumptions, capacity and operating cost; identify explicit non-goals and triggers to change strategies.
- Sequence the migration across API/data/platform owners, with contract agreement, reviewed recovery and decommissioning responsibility.
- Have peers review the operational plan; mentor another contributor through a bounded isolation-test change and use its result in the release decision.

**Ready when:** a reviewed decision explains the selected and rejected options, the implementation meets the relevant junior/intermediate safety checks, delivery/recovery ownership is explicit, and review objections have recorded resolutions. Actual collaboration is required for a collaboration verdict; solo role-play remains rehearsal.

Continue the [twelve-week ownership exercise](../ownership/sustained.md) alongside this phase. Phase completion does not establish sustained ownership until that evidence exists.

Use the [artifact templates](../ownership/templates.md) and retain the [review record](../ownership/templates.md#review-record) in your own Runway repository. Record `ready`, `needs revision` or `not assessed` per route, rather than assigning yourself a job title.
