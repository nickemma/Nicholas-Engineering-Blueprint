# Phase 9 self-test: secure the AI layer

Close the guide. Use your own diagrams, code and retained evidence.

1. Draw the assistant's trust boundaries. Mark every place untrusted text enters and every place a decision is enforced, and say which of them the model can influence.
2. Reproduce G1 before and after the fix. Explain the status code, the template calls and the reservations separately.
3. Remove the application's tenant filter from a retrieval query and show what still holds. Then show the one query from Step 8 that row-level security didn't stop, and why.
4. Run a looping request against an agent without limits, then with them. Report tool calls, tokens and time, and explain why one wording loops and another doesn't.
5. As a reader, try to change a job, and to touch another tenant's job, through the real model. Show the tool server's audit line for each, and the model's account of it.
6. Run a direct-injection set against a rule that lives only in the prompt, then against the same rule enforced in code. Report proposals and applied changes separately, with intervals.
7. Plant an instruction in a runbook and in a job's failure text. Show the harm before approvals, then a proposal that waits, then a legitimate change going through after approval.
8. Make the assistant's page leak data through an image, in a real browser; then stop it with escaping, and separately with the Content-Security-Policy alone.
9. Show one tenant reading another's answer through a shared cache, and the timing difference a shared prompt cache creates. Fix both, and show the measurement after.
10. Extract a secret from a system prompt; replace it with a canary; name a disguise your check misses.
11. Flood the platform with one tenant's agents and measure another tenant's experience, before and after per-tenant limits.
12. Load a pickle in a locked-down container; sign a release; show the agent refusing changed tool descriptions.
13. Run the adversarial suite scripted and live, with a reviewer who declines and one who approves everything. Explain what each number does and doesn't support.
14. Defend your report: one row that held, one that held with limits, one you didn't test, and the evidence that would change each.

Pass when you can predict each result, reproduce its evidence, and explain its limits without claiming more than you measured. Return to the [phase](../../lessons/09-secure-ai-layer/README.md) for any part you can't yet defend.
