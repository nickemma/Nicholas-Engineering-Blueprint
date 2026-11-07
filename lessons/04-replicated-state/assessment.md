# Phase 4 assessment: Guarantees under partitions and change

Use the [assessment and ownership track](../ownership/README.md) to choose a route. Complete the existing phase exercise and self-test as well as the selected assignment. These are independent tasks with acceptance contracts, not solution code.

## Common readiness gate

Explain the stated failure model and invariant; reproduce a partition/crash case and run the phase's simulation or linearizability checks. Name what is not guaranteed.

Record the baseline/submitted commits, reproduction commands, actual results and limits. Apply the [review rubric](../ownership/reviews.md); unresolved critical correctness or safety findings block readiness for the affected capability.

## Junior: bounded independent tickets

Choose one ticket at a time. Agree its scope with a reviewer, implement without copying a guide solution, and correct review feedback. Split the ticket if it exceeds a session or two. Existing behaviour outside its contract must remain covered.

1. **Lost leader.** Write one focused regression scenario for a documented leadership failure; demonstrate the safety invariant and recovery condition.
2. **Stale operation.** Test rejection of an operation with a stale fencing token without rejecting a valid current owner.
3. **Limit statement.** Correct one operational claim so it names the failure model and a measurable recovery condition; ask the reviewer to reproduce the supporting case.

**Ready when:** the selected ticket's positive and negative/isolation checks pass, the diff is small and understandable, the learner explains it without the guide, and the reviewer can reproduce the documented result. A solo attempt is recorded as self-reviewed, with external feedback pending.

## Intermediate: investigate, change and operate

“Some clients hang after a configuration change.” Diagnose an unfamiliar cluster revision using deterministic traces. Clarify whether the request is a timeout adjustment or an actual membership/protocol change.

Use the [investigation and rollout templates](../ownership/templates.md). The evaluator supplies a working baseline and a reproducible symptom, not the diagnosis. Record ambiguities and agree answers before coding.

- Retain the smallest replayable failing trace and invariant checks; do not treat a successful happy-path request as proof of safety.
- For a configuration change, run old/new binaries through a mixed-version and rollback matrix under partitions. If protocol membership changes are requested, document unsupported cases rather than shipping an unproved shortcut.
- Measure recovery and availability at declared conditions, including a slow node; bound resource use and show safe recovery without discarding committed records.

**Ready when:** the diagnosis is evidenced, the agreed checks above pass, and another person can follow the change/recovery instructions. Include capacity, monitoring and rollback evidence appropriate to this phase; label anything not exercised. Use independent unfamiliar code where possible and disclose prior knowledge/help.

## Senior: decide, coordinate and review

A stakeholder asks for writes in both sides of a partition and no conflicting records. Negotiate an achievable contract, comparing quorum ownership, explicit conflict handling and reducing scope.

- Tie the decision to the actual failure model and user-visible guarantees, including a counterexample to the rejected promise.
- Assign ownership of membership, recovery and protocol compatibility; define evidence required before any cross-version rollout.
- Review an independently produced fault scenario and revise the design or claim when the evidence demands it.

**Ready when:** a reviewed decision explains the selected and rejected options, the implementation meets the relevant junior/intermediate safety checks, delivery/recovery ownership is explicit, and review objections have recorded resolutions. Actual collaboration is required for a collaboration verdict; solo role-play remains rehearsal.

Use the [artifact templates](../ownership/templates.md) and retain the [review record](../ownership/templates.md#review-record) in your own Runway repository. Record `ready`, `needs revision` or `not assessed` per route, rather than assigning yourself a job title.
