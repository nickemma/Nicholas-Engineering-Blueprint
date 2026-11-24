# Interview rehearsal for systems and infrastructure

Use this loop when interviews are near and implementation is already your strength. Attempt an unfamiliar prompt cold, explain the decision aloud, change a constraint, then score the response. Record the earliest miss, [sort it by type](#sort-each-miss), and repeat with a fresh prompt.

| Session | Timed attempt | Evidence of readiness |
|---|---|---|
| DSA · 35 minutes | Pick a mixed problem without reading its pattern label. Use your stronger interview language, Go or Python. Clarify the contract, compare two approaches, state the invariant, and use the remaining time to implement and test. | Explain why your choice fits the limits. Predict results for meaningful boundaries, such as duplicates or stale state. Adapt when the input becomes streaming or the memory bound tightens. [Practice sets](../dsa/README.md) |
| System design · 45 minutes | Clarify two requirements, estimate the bottleneck, and choose a design. Ask a partner to change one assumption at minute 25. Practise an incident or recovery timeline as part of the answer. | Defend a choice against a viable alternative. Trace what the user sees when a dependency fails. State the signal that would trigger rollback and say what new evidence would reverse your decision. [Scorecard](scorecard.md) · [Sharding drill](fundamentals/sharding.md) |
| Maths · 15 minutes | Derive a rough capacity result by hand from the same design. Keep units, use the appropriate average for concurrency, and test a burst or loss scenario. | Explain which decision the estimate supports and name one assumption that could make it misleading. Compare with a measurement or calculate a sensitivity case. [Capacity worksheet](../math/04-capacity-planning/README.md) |

## During the interview

The [DSA loop](../dsa/README.md#the-loop-for-every-problem) and the [45-minute design script](README.md#the-45-minute-script) give the full order. Under time pressure, keep these five:

1. **Restate and clarify.** Confirm the inputs, outputs, limits and edge cases before choosing anything.
2. **Baseline first.** Describe a correct solution and its cost before optimising, unless the best approach is obvious from the start.
3. **Explain before you build.** Name the data structure, algorithm or design, why it fits, and its complexity before you write code or draw boxes.
4. **Small, checkable steps.** Build a piece at a time and say what you're doing at each decision, so the interviewer can follow and help.
5. **Test out loud.** Normal cases, boundaries, empty input, duplicates and a failure case.

## Sort each miss

After every timed attempt, write down the **earliest** point where it went wrong and give it one type. The type decides what you practise next, so it's worth being honest about.

| Type | In a coding round | In a design round | What to practise |
|---|---|---|---|
| **Pattern** | You didn't see which approach fits, or chose one that can't meet the limits | You missed the crux, or chose a shape that can't meet a requirement | Mixed sets without labels. For each miss, write the clue that should have pointed to the right approach |
| **Implementation** | The idea was right, the code wasn't: boundaries, off-by-one, state not reset | A mechanism that wouldn't work as described | Re-solve from a blank file. Trace by hand before running |
| **Complexity** | Costs wrong or missing, or a solution too slow for the stated input size | No numbers, or numbers that don't support the choice | State the costs before coding, then check them against the limits |
| **Communication** | Silent stretches, a plan the interviewer couldn't follow, a hint missed | A monologue, or no check-ins at the milestones | Record yourself. Say the plan before acting |
| **Testing** | Bugs found late or not at all; no edge cases tried | No failure walk-through: what the user sees when a part dies | Write the edge cases or failure cases before the solution |

Keep the log in your own repository:

| Date | Prompt | Minutes | Earliest miss | Type | Next practice |
|---|---|---|---|---|---|
| | | | | | |

Every few sessions, count the types. Work on the most common one first: two fresh prompts aimed at it, then a mixed mock to check that the fix holds when you don't know the topic in advance.

## Practising for a specific company

Once you have interviews booked, aim part of your practice at that company. It changes what you practise, not how you learn.

- **Find out the format.** Ask the recruiter how many rounds there are, how long each is, which languages are allowed, whether code must run, whether it's a shared editor or a whiteboard, and whether the design round is general or ML. Then practise in that format: the same time limit, the same kind of editor, no hints.
- **Use company-tagged lists to choose problems.** LeetCode's company tags (a paid feature) and candidates' interview reports show what people say they were asked. Favour reports from the last 6–12 months, and patterns that come up again and again over one-off reports.
- **Keep the mocks mixed.** Draw from the tagged set at random. Choosing the topic in advance trains a skill the interview won't test.
- **Don't memorise the answers.** Reports are incomplete, and companies change their questions. For every tagged problem you solve, explain why the approach works, then change one constraint and adapt it: stream the input, bound the memory, allow duplicates. If you can't, you've learned an answer, not a pattern.
- **Startups differ.** Larger companies tend to use a stable structure that candidates describe consistently. Startups often build rounds around their own product and problems, so read their engineering blog and documentation, and expect a design or debugging round close to their work.

This repository keeps no company lists. They go stale within months, and most come from paid sites.

## Before the next interview

Run a cold DSA problem and the sharding prompt first. Fix one miss from each, then repeat on fresh prompts under the same time limits. Rotate in a capstone design and practise a five-minute ownership story from its evidence. Explain your decision, your contribution, the failure signal, and the resulting change. Describe the lab and its scope plainly. Use production examples from your own work when you have them. [Ownership tabletop](../ownership/README.md)

Look for repeatability across unfamiliar prompts and mock interviews. A useful checkpoint is two consecutive sessions where you make the decision independently, account for a realistic failure, and adapt it after a constraint changes. Use each miss to decide what to practise next. Completing the guides gives you material to reason from. Timed performance and feedback show how reliably you can use it.
