# Review and readiness rubric

Review observable work, not confidence, terminology, typing speed or years of experience. State the selected route and acceptance criteria before the assignment. Use the phase-specific checks alongside this rubric.

## Criteria by route

| Dimension | Junior evidence | Intermediate evidence | Senior evidence |
|---|---|---|---|
| Framing | Restates the ticket and asks about a missing example | Turns ambiguity into a testable contract; records assumptions and dependencies | Reconciles stakeholder goals; compares doing nothing, improving the current system and replacing it; chooses explicit non-goals |
| Correctness | Positive, negative and relevant isolation tests; handles errors | Tests compatibility and concurrency at service boundaries; preserves existing users/data | Defines guarantees and unacceptable failure modes; ensures the delivery plan verifies them |
| Investigation | Reproduces a problem and explains the changed path | Maps unfamiliar code, separates symptoms from causes, records and eliminates hypotheses | Identifies the highest-risk uncertainty and commissions the cheapest useful investigation |
| Change safety | Small understandable diff and reproducible checks | Old/new coexistence, capacity budget, deployment steps, monitoring and demonstrated rollback | Orders changes across owners; identifies irreversible steps, decision points and contingency responsibility |
| Operations and cost | Documents how to run and recover the changed behaviour | Measures capacity and recovery; tracks dependencies and action items | Chooses and revisits a cost/reliability budget; accounts for operating effort and ownership consequences |
| Collaboration | Gives a reviewable PR and resolves feedback | Gets contract agreement, reviews a peer change and hands over operations | Defends and revises a proposal, helps another engineer deliver, resolves disagreement and closes cross-owner decisions |

Later-route work retains earlier-route requirements relevant to the change. A senior does not have to personally write every line, but must show that correctness and safe delivery were verified by identifiable owners.

## Scoring and verdict

For each applicable dimension record 0 (absent or unsafe), 1 (partial; needs specific help), 2 (meets this assignment's stated contract), or 3 (meets it and handles a justified additional challenge). Attach evidence to every score. Mark a dimension `not assessed` if it was not exercised; do not invent evidence or silently count it as a pass.

`Ready` requires every required dimension to reach at least 2, all phase acceptance checks to pass, and no unresolved blocker. A 3 elsewhere cannot compensate for a 0. Optional extensions do not lower the gate or rescue missing essentials. Record `needs revision` when evidence is incomplete/fails; record `not assessed` when no valid assessment occurred. A solo verdict is labelled self-assessed, even if all checks pass.

Blocking findings include cross-tenant access, silent data loss, a claimed guarantee contradicted by a test, unsafe irreversible migration, unbounded resource use under the stated contract, or a rollout with no recovery for an identified failure. Scope the blocker to the assignment: Phase 0 is not required to have Kubernetes or enterprise IAM.

## Review cycle

1. **Agree the ticket.** Capture baseline commit, expected behaviour, exclusions, evidence required and the reviewer. Name any constraints the learner may challenge.
2. **Self-review.** Learner links the diff, tests, explanation, known limits and operational notes. Run checks against the submitted commit, not an unrecorded later working tree.
3. **Review behaviour first.** Reviewer reproduces at least one key acceptance check, inspects failure handling and asks the learner to explain a relevant trade-off. Test names alone are not evidence.
4. **Write actionable feedback.** Each comment includes severity (`blocker`, `required`, `suggestion`), observed behaviour, why it matters and what would demonstrate resolution. Avoid prescribing implementation unless teaching that technique is the agreed objective.
5. **Revise and re-review.** Learner links the correction and relevant rerun, or explains a disagreement with evidence. Reviewer closes each required finding explicitly.
6. **Record readiness.** Save the rubric, evidence links, unresolved limits and next reassessment action using the [review record](templates.md#review-record).

Example feedback: “Required: the failed upstream call leaves its reservation active. The next valid request is rejected although capacity should be free. Add a failure/recovery check that demonstrates your documented accounting policy.” The learner must choose the appropriate implementation; the comment does not assume every reservation should be refunded.

## Review independence

A collaborator should review without having authored the submitted solution. Record their role and any help given. AI assistance may explain, critique or generate candidate tests, but a generated review is not an independent human sign-off. Keep self/AI review useful and honestly labelled. When no reviewer is available, finish the work and mark external review pending; unrelated learning can continue.

For senior practice, ask a peer to take the stakeholder role and challenge one assumption. Another actual contributor should own at least one bounded implementation task for the mentoring criterion. A simulated discussion or reviewing your own patch is rehearsal, not evidence of mentoring another person.
