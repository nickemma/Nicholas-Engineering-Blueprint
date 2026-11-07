# Phase 1 assessment: Concurrency, shutdown and compatibility

Use the [assessment and ownership track](../ownership/README.md) to choose a route. Complete the existing phase exercise and self-test as well as the selected assignment. These are independent tasks with acceptance contracts, not solution code.

## Common readiness gate

Explain the handler/service boundaries, reproduce a concurrency failure and demonstrate graceful shutdown with checks from the phase. The race-enabled test suite must pass.

Record the baseline/submitted commits, reproduction commands, actual results and limits. Apply the [review rubric](../ownership/reviews.md); unresolved critical correctness or safety findings block readiness for the affected capability.

## Junior: bounded independent tickets

Choose one ticket at a time. Agree its scope with a reviewer, implement without copying a guide solution, and correct review feedback. Split the ticket if it exceeds a session or two. Existing behaviour outside its contract must remain covered.

1. **Invalid limit.** Reject one out-of-range request parameter with a documented error while keeping the valid boundary cases working.
2. **Cancelled request.** Add a focused check for cancellation during one operation; show the expected error and that a later valid request still works.
3. **Concurrent isolation.** Verify concurrent independent requests do not share mutable response state. Explain the state ownership and document the contract.

**Ready when:** the selected ticket's positive and negative/isolation checks pass, the diff is small and understandable, the learner explains it without the guide, and the reviewer can reproduce the documented result. A solo attempt is recorded as self-reviewed, with external feedback pending.

## Intermediate: investigate, change and operate

“Requests disappear during restarts.” Investigate an unfamiliar revision while a supplied client continuously sends uniquely identified requests. Agree what is accepted, rejected and drained; do not promise durable delivery before the storage phase.

Use the [investigation and rollout templates](../ownership/templates.md). The evaluator supplies a working baseline and a reproducible symptom, not the diagnosis. Record ambiguities and agree answers before coding.

- Trace one accepted request across a restart; classify every offered request instead of counting only successful responses.
- Run existing and modified clients against the new server, including a slow/disconnecting client, and check concurrency with the race detector.
- Define load and drain deadlines, demonstrate recovery to the previous version and document the limits of in-memory state.

**Ready when:** the diagnosis is evidenced, the agreed checks above pass, and another person can follow the change/recovery instructions. Include capacity, monitoring and rollback evidence appropriate to this phase; label anything not exercised. Use independent unfamiliar code where possible and disclose prior knowledge/help.

## Senior: decide, coordinate and review

Two stakeholders disagree: one requires immediate restarts, another requires all accepted work to finish. Propose a shutdown contract within a fixed termination window and resource budget.

- Choose explicit acceptance/rejection/drain semantics and name the case that cannot be guaranteed without durable storage.
- Assign release and shutdown ownership; agree abort thresholds and the fallback when draining exceeds the window.
- Review another implementation or test patch and retain the correction cycle; defend why the chosen contract is worth its operational cost.

**Ready when:** a reviewed decision explains the selected and rejected options, the implementation meets the relevant junior/intermediate safety checks, delivery/recovery ownership is explicit, and review objections have recorded resolutions. Actual collaboration is required for a collaboration verdict; solo role-play remains rehearsal.

Use the [artifact templates](../ownership/templates.md) and retain the [review record](../ownership/templates.md#review-record) in your own Runway repository. Record `ready`, `needs revision` or `not assessed` per route, rather than assigning yourself a job title.
