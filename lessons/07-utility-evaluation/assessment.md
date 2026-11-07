# Phase 7 assessment: Evidence as a release dependency

Use the [assessment and ownership track](../ownership/README.md) to choose a route. Complete the existing phase exercise and self-test as well as the selected assignment. These are independent tasks with acceptance contracts, not solution code.

## Common readiness gate

Reproduce train/serve parity and fallback checks, identify leakage controls and distinguish measured, inconclusive and unmeasured claims. Record data/model versions.

Record the baseline/submitted commits, reproduction commands, actual results and limits. Apply the [review rubric](../ownership/reviews.md); unresolved critical correctness or safety findings block readiness for the affected capability.

## Junior: bounded independent tickets

Choose one ticket at a time. Agree its scope with a reviewer, implement without copying a guide solution, and correct review feedback. Split the ticket if it exceeds a session or two. Existing behaviour outside its contract must remain covered.

1. **Missing feature.** Test the existing contract for a missing/invalid feature and show a valid request is unaffected.
2. **Slow predictor.** Demonstrate timeout/fallback without dropping the original job; document which metric records the outcome.
3. **Honest comparison.** Add a regression check that a failed or missing evaluation cannot be reported as a successful promotion.

**Ready when:** the selected ticket's positive and negative/isolation checks pass, the diff is small and understandable, the learner explains it without the guide, and the reviewer can reproduce the documented result. A solo attempt is recorded as self-reviewed, with external feedback pending.

## Intermediate: investigate, change and operate

“The new model looks better offline but scheduling got worse.” Investigate an unfamiliar release with data/feature/model histories. Establish the user objective before tuning.

Use the [investigation and rollout templates](../ownership/templates.md). The evaluator supplies a working baseline and a reproducible symptom, not the diagnosis. Record ambiguities and agree answers before coding.

- Test feature/schema compatibility across old/new API and model versions, including fallback when the optional predictor is unavailable.
- Run a shadow/canary evaluation with fixed acceptance criteria, quality slices, latency/capacity and uncertainty; retain failed observations.
- Demonstrate rolling back the model plus preprocessing contract, assess an ML dependency update and track drift/incident follow-ups through ownership records.

**Ready when:** the diagnosis is evidenced, the agreed checks above pass, and another person can follow the change/recovery instructions. Include capacity, monitoring and rollback evidence appropriate to this phase; label anything not exercised. Use independent unfamiliar code where possible and disclose prior knowledge/help.

## Senior: decide, coordinate and review

Product wants accuracy, operations wants latency and finance wants lower prediction cost. Decide whether a model change, simpler baseline or no release best meets the agreed objective.

- Write and defend a proposal with a fixed evaluation plan, quality/cost guardrails, non-goals and data/model ownership.
- Coordinate pipeline/serving/scheduling release stages; specify review authority, stop conditions and rollback responsibilities.
- Review a peer's experiment, challenge a weak causal claim and revisit the promotion decision with later operating evidence.

**Ready when:** a reviewed decision explains the selected and rejected options, the implementation meets the relevant junior/intermediate safety checks, delivery/recovery ownership is explicit, and review objections have recorded resolutions. Actual collaboration is required for a collaboration verdict; solo role-play remains rehearsal.

Continue the [twelve-week ownership exercise](../ownership/sustained.md) alongside this phase. Phase completion does not establish sustained ownership until that evidence exists.

Use the [artifact templates](../ownership/templates.md) and retain the [review record](../ownership/templates.md#review-record) in your own Runway repository. Record `ready`, `needs revision` or `not assessed` per route, rather than assigning yourself a job title.
