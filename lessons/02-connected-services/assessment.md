# Phase 2 assessment: Independent producers and consumers

Use the [assessment and ownership track](../ownership/README.md) to choose a route. Complete the existing phase exercise and self-test as well as the selected assignment. These are independent tasks with acceptance contracts, not solution code.

## Common readiness gate

Trace one job across producer, broker and worker; reproduce duplicate delivery and worker failure. Explain acknowledgement, retry and dead-letter behaviour using observed records.

Record the baseline/submitted commits, reproduction commands, actual results and limits. Apply the [review rubric](../ownership/reviews.md); unresolved critical correctness or safety findings block readiness for the affected capability.

## Junior: bounded independent tickets

Choose one ticket at a time. Agree its scope with a reviewer, implement without copying a guide solution, and correct review feedback. Split the ticket if it exceeds a session or two. Existing behaviour outside its contract must remain covered.

1. **Poison job.** Add an acceptance check showing malformed work is quarantined without stopping a subsequent valid job.
2. **Duplicate result.** Demonstrate that the same job delivered twice follows the documented side-effect policy; preserve a different job's result.
3. **Dependency instructions.** Document broker/client version and startup requirements, then have another person reproduce one connection failure and recovery.

**Ready when:** the selected ticket's positive and negative/isolation checks pass, the diff is small and understandable, the learner explains it without the guide, and the reviewer can reproduce the documented result. A solo attempt is recorded as self-reviewed, with external feedback pending.

## Intermediate: investigate, change and operate

“After a worker update, some jobs never finish.” Receive an independently deployed producer/consumer baseline and an incomplete event-change request. Investigate schema, retries, acknowledgements and dependency versions before changing the contract.

Use the [investigation and rollout templates](../ownership/templates.md). The evaluator supplies a working baseline and a reproducible symptom, not the diagnosis. Record ambiguities and agree answers before coding.

- Build the old/new producer-by-consumer compatibility matrix; run mixed-version traffic and retain per-job outcomes.
- Propose an additive event change and a reader-before-writer rollout, with poison/duplicate tests and an old-consumer retirement condition.
- Measure offered/completed work and backlog at a fixed load; demonstrate rollback without a retry storm or silent loss. Assess one broker/client upgrade and its compatibility constraints.

**Ready when:** the diagnosis is evidenced, the agreed checks above pass, and another person can follow the change/recovery instructions. Include capacity, monitoring and rollback evidence appropriate to this phase; label anything not exercised. Use independent unfamiliar code where possible and disclose prior knowledge/help.

## Senior: decide, coordinate and review

API and worker owners disagree on event semantics and upgrade timing. Compare a compatible extension, a versioned event and a coordinated cutover; include the cost of maintaining compatibility.

- Obtain explicit producer/consumer contract agreement, non-goals and owners for dead-letter/replay decisions.
- Stage the migration across owners, with measurable exit/abort conditions and a retirement date for old consumers.
- Delegate one contract-test task, review the resulting patch and resolve one objection before approving the release.

**Ready when:** a reviewed decision explains the selected and rejected options, the implementation meets the relevant junior/intermediate safety checks, delivery/recovery ownership is explicit, and review objections have recorded resolutions. Actual collaboration is required for a collaboration verdict; solo role-play remains rehearsal.

Use the [artifact templates](../ownership/templates.md) and retain the [review record](../ownership/templates.md#review-record) in your own Runway repository. Record `ready`, `needs revision` or `not assessed` per route, rather than assigning yourself a job title.
