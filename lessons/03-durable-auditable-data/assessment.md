# Phase 3 assessment: Data changes without abandoning old versions

Use the [assessment and ownership track](../ownership/README.md) to choose a route. Complete the existing phase exercise and self-test as well as the selected assignment. These are independent tasks with acceptance contracts, not solution code.

## Common readiness gate

Demonstrate durable state after restart, a transaction/isolation failure, and restore/reconciliation checks from the phase. Identify which records are authoritative.

Record the baseline/submitted commits, reproduction commands, actual results and limits. Apply the [review rubric](../ownership/reviews.md); unresolved critical correctness or safety findings block readiness for the affected capability.

## Junior: bounded independent tickets

Choose one ticket at a time. Agree its scope with a reviewer, implement without copying a guide solution, and correct review feedback. Split the ticket if it exceeds a session or two. Existing behaviour outside its contract must remain covered.

1. **Query boundary.** Add a boundary/invalid-input check for one existing query; preserve the valid result and avoid changing unrelated query behaviour.
2. **Independent records.** Show changing one job or account does not mutate a second record, including an error-path case.
3. **Migration explanation.** Document one existing migration's intended data effect, how to verify it and the limitations of undoing it. Do not equate a down migration with safe data recovery.

**Ready when:** the selected ticket's positive and negative/isolation checks pass, the diff is small and understandable, the learner explains it without the guide, and the reviewer can reproduce the documented result. A solo attempt is recorded as self-reviewed, with external feedback pending.

## Intermediate: investigate, change and operate

“Add a required job field without interrupting old workers.” Start from an unfamiliar populated schema. Clarify the default/meaning for historical records and deliver an expand/backfill/cutover/contract plan.

Use the [investigation and rollout templates](../ownership/templates.md). The evaluator supplies a working baseline and a reproducible symptom, not the diagnosis. Record ambiguities and agree answers before coding.

- Run old and new binaries against the expanded schema; demonstrate writes/readbacks from both versions and an interrupted/restarted idempotent backfill.
- Measure query latency and pool/lock behaviour during backfill at a declared workload. State the data validation that permits cutover.
- Roll back before contraction and demonstrate forward recovery or restore for the irreversible stage. Reconcile counts and invariants; assess a driver/database dependency change separately.

**Ready when:** the diagnosis is evidenced, the agreed checks above pass, and another person can follow the change/recovery instructions. Include capacity, monitoring and rollback evidence appropriate to this phase; label anything not exercised. Use independent unfamiliar code where possible and disclose prior knowledge/help.

## Senior: decide, coordinate and review

Two service owners and an analyst depend on the old field. Negotiate semantics and a removal deadline under a downtime and operating-cost budget. Compare keeping compatibility with a destructive cutover.

- Record data ownership, reconciliation responsibility, reader/writer sequencing and who may authorise the point of no return.
- Defend the chosen consistency/availability trade-off, backfill capacity and a scoped alternative if the deadline slips.
- Have affected-role peers review the migration and another contributor own a bounded validation task; record objections and actual closure.

**Ready when:** a reviewed decision explains the selected and rejected options, the implementation meets the relevant junior/intermediate safety checks, delivery/recovery ownership is explicit, and review objections have recorded resolutions. Actual collaboration is required for a collaboration verdict; solo role-play remains rehearsal.

Use the [artifact templates](../ownership/templates.md) and retain the [review record](../ownership/templates.md#review-record) in your own Runway repository. Record `ready`, `needs revision` or `not assessed` per route, rather than assigning yourself a job title.
