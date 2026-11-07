# Phase 0 assessment: One request and a reviewable change

Use the [assessment and ownership track](../ownership/README.md) to choose a route. Complete the existing phase exercise and self-test as well as the selected assignment. These are independent tasks with acceptance contracts, not solution code.

## Common readiness gate

Start the service from a clean checkout, trace an HTTP request and demonstrate the documented invalid-input and unavailable-server cases. Explain status, headers, body and process exit without the guide.

Record the baseline/submitted commits, reproduction commands, actual results and limits. Apply the [review rubric](../ownership/reviews.md); unresolved critical correctness or safety findings block readiness for the affected capability.

## Junior: bounded independent tickets

Choose one ticket at a time. Agree its scope with a reviewer, implement without copying a guide solution, and correct review feedback. Split the ticket if it exceeds a session or two. Existing behaviour outside its contract must remain covered.

1. **Whitespace-only names.** Make the greeting contract specify and reject whitespace-only input; check an ordinary name still works. State whether other whitespace is preserved.
2. **Unknown route.** Give an unknown path a documented not-found response without changing the existing routes. Check both paths.
3. **Another person starts it.** Have a reviewer follow the setup instructions from a clean directory; correct one reproduced ambiguity and record the exact successful commands.

**Ready when:** the selected ticket's positive and negative/isolation checks pass, the diff is small and understandable, the learner explains it without the guide, and the reviewer can reproduce the documented result. A solo attempt is recorded as self-reviewed, with external feedback pending.

## Intermediate: investigate, change and operate

“The client says the service is up, but their greeting request fails.” Receive a baseline commit and failing client command without a diagnosis. Map the request path, distinguish routing/input/environment explanations, and agree the response contract before fixing it.

Use the [investigation and rollout templates](../ownership/templates.md). The evaluator supplies a working baseline and a reproducible symptom, not the diagnosis. Record ambiguities and agree answers before coding.

- Reproduce the original symptom and show why the chosen diagnosis fits better than one rejected hypothesis.
- Show the existing client and corrected client against the changed service; retain the current contract or explicitly agree the change.
- Run a small repeatable request sample, document its resource context, and demonstrate restarting the prior commit. This is local recovery, not a Kubernetes rollout.

**Ready when:** the diagnosis is evidenced, the agreed checks above pass, and another person can follow the change/recovery instructions. Include capacity, monitoring and rollback evidence appropriate to this phase; label anything not exercised. Use independent unfamiliar code where possible and disclose prior knowledge/help.

## Senior: decide, coordinate and review

A teammate wants accounts, a database and Kubernetes before the first user trial; another needs a local demonstration tomorrow. Write a one-page decision comparing the current service, one bounded improvement and the proposed expansion. Negotiate the smallest acceptable trial.

- State which requests and users the trial supports, what remains local-only, and what you deliberately defer.
- Give an effort/resource budget and assign implementation, review and demo ownership; explain a condition that would justify the deferred work.
- Have a peer challenge the decision and implement or review one bounded ticket. Record how the proposal changed; do not claim broader team leadership from this exercise.

**Ready when:** a reviewed decision explains the selected and rejected options, the implementation meets the relevant junior/intermediate safety checks, delivery/recovery ownership is explicit, and review objections have recorded resolutions. Actual collaboration is required for a collaboration verdict; solo role-play remains rehearsal.

Use the [artifact templates](../ownership/templates.md) and retain the [review record](../ownership/templates.md#review-record) in your own Runway repository. Record `ready`, `needs revision` or `not assessed` per route, rather than assigning yourself a job title.
