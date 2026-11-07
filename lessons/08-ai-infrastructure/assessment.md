# Phase 8 assessment: Fair capacity and an authorised model release

Use the [assessment and ownership track](../ownership/README.md) to choose a route. Complete the existing phase exercise and self-test as well as the selected assignment. These are independent tasks with acceptance contracts, not solution code.

## Common readiness gate

Run the published CPU checks and identify which live server, cluster, signing, Ray and GPU claims remain unmeasured. Do not treat syntax checking as execution or chunks as authoritative token counts.

Record the baseline/submitted commits, reproduction commands, actual results and limits. Apply the [review rubric](../ownership/reviews.md); unresolved critical correctness or safety findings block readiness for the affected capability.

## Junior: bounded independent tickets

Choose one ticket at a time. Agree its scope with a reviewer, implement without copying a guide solution, and correct review feedback. Split the ticket if it exceeds a session or two. Existing behaviour outside its contract must remain covered.

1. **Interrupted stream.** Add a contract case for an incomplete answer and retain the successful completion case. Explain how failure is counted.
2. **Tenant admission.** Test rejection at one tenant/admission boundary and show a later allowed request can proceed under the documented accounting policy.
3. **Release instructions.** Have a reviewer follow one local server startup procedure with verified artifacts; fix a reproduced ambiguity and record hardware limits.

**Ready when:** the selected ticket's positive and negative/isolation checks pass, the diff is small and understandable, the learner explains it without the guide, and the reviewer can reproduce the documented result. A solo attempt is recorded as self-reviewed, with external feedback pending.

## Intermediate: investigate, change and operate

“Add a second tenant to inference without breaking the first tenant's TTFT objective.” Start from an unfamiliar gateway and frozen workload; clarify token budgets, fairness, cancellation and quality before changing capacity.

Use the [investigation and rollout templates](../ownership/templates.md). The evaluator supplies a working baseline and a reproducible symptom, not the diagnosis. Record ambiguities and agree answers before coding.

- Prove concurrent isolation and shared budget accounting across gateway replicas; confirm actual backend work stops or capacity is otherwise bounded after disconnect.
- Run old/new gateway, model and template contracts through a staged rollout; measure all-arrivals objectives, quality, resource headroom and completed-token cost.
- Reject unauthorised/tampered releases, exercise rollback and capture cold-start/overload recovery. Hardware-dependent checks stay pending when hardware is unavailable.

**Ready when:** the diagnosis is evidenced, the agreed checks above pass, and another person can follow the change/recovery instructions. Include capacity, monitoring and rollback evidence appropriate to this phase; label anything not exercised. Use independent unfamiliar code where possible and disclose prior knowledge/help.

## Senior: decide, coordinate and review

Choose a tenant isolation/capacity strategy under an explicit budget: shared model capacity, reserved lanes or dedicated capacity. Negotiate incompatible latency, quality and cost requests before proposing more GPUs.

- Defend the chosen strategy with measured workload evidence and explicit non-goals; account for idle capacity, model loading, trust roots and operator effort.
- Coordinate gateway/platform/model-owner stages, signature authorisation, abort thresholds and recovery; get the operational plan reviewed.
- Delegate and review a bounded fairness or release test, then revisit the decision during sustained ownership. A CPU simulator cannot sign off a GPU performance promise.

**Ready when:** a reviewed decision explains the selected and rejected options, the implementation meets the relevant junior/intermediate safety checks, delivery/recovery ownership is explicit, and review objections have recorded resolutions. Actual collaboration is required for a collaboration verdict; solo role-play remains rehearsal.

Continue the [twelve-week ownership exercise](../ownership/sustained.md) alongside this phase. Phase completion does not establish sustained ownership until that evidence exists.

Use the [artifact templates](../ownership/templates.md) and retain the [review record](../ownership/templates.md#review-record) in your own Runway repository. Record `ready`, `needs revision` or `not assessed` per route, rather than assigning yourself a job title.
