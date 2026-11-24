# Interview rehearsal for systems and infrastructure

Use this loop when interviews are near and implementation is already your strength. Attempt an unfamiliar prompt cold, explain the decision aloud, change a constraint, then score the response. Record the earliest reasoning miss and repeat with a fresh prompt.

| Session | Timed attempt | Evidence of readiness |
|---|---|---|
| DSA · 35 minutes | Pick a mixed problem without reading its pattern label. Use your stronger interview language, Go or Python. Clarify the contract, compare two approaches, state the invariant, and use the remaining time to implement and test. | Explain why your choice fits the limits. Predict results for meaningful boundaries, such as duplicates or stale state. Adapt when the input becomes streaming or the memory bound tightens. [Practice sets](../dsa/README.md) |
| System design · 45 minutes | Clarify two requirements, estimate the bottleneck, and choose a design. Ask a partner to change one assumption at minute 25. Practise an incident or recovery timeline as part of the answer. | Defend a choice against a viable alternative. Trace what the user sees when a dependency fails. State the signal that would trigger rollback and say what new evidence would reverse your decision. [Scorecard](scorecard.md) · [Sharding drill](fundamentals/sharding.md) |
| Maths · 15 minutes | Derive a rough capacity result by hand from the same design. Keep units, use the appropriate average for concurrency, and test a burst or loss scenario. | Explain which decision the estimate supports and name one assumption that could make it misleading. Compare with a measurement or calculate a sensitivity case. [Capacity worksheet](../math/04-capacity-planning/README.md) |

## Before the next interview

Run a cold DSA problem and the sharding prompt first. Fix one miss from each, then repeat on fresh prompts under the same time limits. Rotate in a capstone design and practise a five-minute ownership story from its evidence. Explain your decision, your contribution, the failure signal, and the resulting change. Describe the lab and its scope plainly. Use production examples from your own work when you have them. [Ownership tabletop](../ownership/README.md)

Look for repeatability across unfamiliar prompts and mock interviews. A useful checkpoint is two consecutive sessions where you make the decision independently, account for a realistic failure, and adapt it after a constraint changes. Use each miss to decide what to practise next. Completing the guides gives you material to reason from. Timed performance and feedback show how reliably you can use it.
