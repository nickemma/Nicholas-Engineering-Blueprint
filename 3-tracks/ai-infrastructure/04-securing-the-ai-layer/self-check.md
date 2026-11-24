# Securing the AI layer · Self-check

Answer from your own code and your own evidence. For each answer, predict a failure, and name the test or measurement that could prove you wrong.

## Threats and retrieval

1. Trace the trust boundaries in your threat model. Which actors can influence the assistant without ever talking to it?
2. Why does `messages: null` count as valid JSON but invalid input? What did G1's dependency counters prove that a 502 alone couldn't?
3. Why must the embedding model, its revision and the chunking rules change together? What breaks if you re-embed half the corpus?
4. R1: what made "more like this" return another tenant's runbook? Why did row-level security fix it better than adding the missing filter?
5. R2: why did a shared approximate index empty a mid-size tenant's results, and why did it depend on table statistics?

## The agent and its authority

6. What's the difference between a chat call and an agent loop? Name every place the loop spends resources or reads untrusted text.
7. Which three limits does lesson 04 put on a run, and what does each protect? Why is no tool run on the last turn?
8. In lesson 04, the model said "has been retried" when the job had failed again, and later "has been canceled" with no tool call. Where do you look for the truth, and why there?
9. Explain the confused deputy with the agent's service token. Why can't a sentence in the system prompt fix it?
10. What does a user token carry, who issues it, and why can the agent's service token no longer call a tool?
11. Why does another tenant's job answer 404 rather than 403?
12. The Python client sent `name`; the Go issuer wanted `user`. Both sides' tests passed. What kind of test caught it, and why?

## Attacks through text

13. Lesson 06: how many of your 32 payloads got a protected-job change through the plain prompt, and the hardened one? Why does that difference not matter once the store enforces the rule?
14. Why count proposed and applied changes separately? Give a case where they differ.
15. Why does one run per payload count as one trial at temperature 0? What would make repeats meaningful?
16. Lesson 07: who can write a runbook or a job's failure text in Switchyard? Trace a planted instruction from the writer to a tool call.
17. What does a grant bind, and why must it bind the note's text and the notification's destination as well as the job?
18. Reads still run without approval. What could a planted instruction still achieve with `status` and `find`?

## Output, leaks and secrets

19. Why does an image in Markdown leak data without anyone clicking? What do escaping and the Content-Security-Policy each stop?
20. Lesson 08: the plain `UNION` returned nothing from Hooli; the one with `set_config` returned its bridge code. What was row-level security trusting, and what does a parameter change?
21. Why does the strict reply check refuse an extra field instead of ignoring it? What did strictness cost on your legitimate requests?
22. What must an answer-cache key contain beyond the question, and why the sources' digests?
23. Explain the prompt-cache timing channel. Why did your experiment need a shuffled order and a control of similar length? What did the gateway's setting change in your measurement?
24. Why log counts and sizes but no text? Who reads logs that no tenant should?
25. Why is "never reveal it" not a control? What does a canary detect, and which disguises did yours miss?

## Limits, supply chain and evidence

26. Why must per-tenant limits live in Redis rather than in each agent process? What does Hooli's latency during an Acme flood show, before and after?
27. What ran when the pickle loaded? What does GGUF change, and what does it not tell you?
28. Why pin the approved manifest's digest as well as the release key? Describe a release each check alone would let through.
29. What does the scripted suite prove, and what can only the live suite measure? What does the careless reviewer measure?
30. "Zero effects on 48 payloads": what range of true rates is that consistent with, and what does it not say?
31. Describe the red-team chain. Which link would you remove first, and why not the approval?
32. Map every threat-model row to your evidence. Name two rows you'd mark "held, with limits" and the experiment that would change each verdict.

## From memory


Close the lessons. Use your own diagrams, code and retained evidence.

1. Draw the assistant's trust boundaries. Mark every place untrusted text enters and every place a decision is enforced, and say which of them the model can influence.
2. Reproduce G1 before and after the fix. Explain the status code, the template calls and the reservations separately.
3. Remove the application's tenant filter from a retrieval query and show what still holds. Then show the one query from lesson 08 that row-level security didn't stop, and why.
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

Pass when you can predict each result, reproduce its evidence, and explain its limits without claiming more than you measured. Return to the [module](README.md) for any lesson you can't yet defend. Question 14 applies if you did the optional red team.
