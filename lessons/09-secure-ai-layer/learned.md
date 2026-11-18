# Phase 9: explain what you built

Answer from your own code and your own evidence. For each answer, predict a failure, and name the test or measurement that could prove you wrong.

## Threats and retrieval

1. Trace the trust boundaries in your threat model. Which actors can influence the assistant without ever talking to it?
2. Why does `messages: null` count as valid JSON but invalid input? What did G1's dependency counters prove that a 502 alone couldn't?
3. Why must the embedding model, its revision and the chunking rules change together? What breaks if you re-embed half the corpus?
4. R1: what made "more like this" return another tenant's runbook? Why did row-level security fix it better than adding the missing filter?
5. R2: why did a shared approximate index empty a mid-size tenant's results, and why did it depend on table statistics?

## The agent and its authority

6. What's the difference between a chat call and an agent loop? Name every place the loop spends resources or reads untrusted text.
7. Which three limits does Step 4 put on a run, and what does each protect? Why is no tool run on the last turn?
8. In Step 4, the model said "has been retried" when the job had failed again, and later "has been canceled" with no tool call. Where do you look for the truth, and why there?
9. Explain the confused deputy with the agent's service token. Why can't a sentence in the system prompt fix it?
10. What does a user token carry, who issues it, and why can the agent's service token no longer call a tool?
11. Why does another tenant's job answer 404 rather than 403?
12. The Python client sent `name`; the Go issuer wanted `user`. Both sides' tests passed. What kind of test caught it, and why?

## Attacks through text

13. Step 6: how many of your 32 payloads got a protected-job change through the plain prompt, and the hardened one? Why does that difference not matter once the store enforces the rule?
14. Why count proposed and applied changes separately? Give a case where they differ.
15. Why does one run per payload count as one trial at temperature 0? What would make repeats meaningful?
16. Step 7: who can write a runbook or a job's failure text in Runway? Trace a planted instruction from the writer to a tool call.
17. What does a grant bind, and why must it bind the note's text and the notification's destination as well as the job?
18. Reads still run without approval. What could a planted instruction still achieve with `status` and `find`?

## Output, leaks and secrets

19. Why does an image in Markdown leak data without anyone clicking? What do escaping and the Content-Security-Policy each stop?
20. Step 8: the plain `UNION` returned nothing from Hooli; the one with `set_config` returned its bridge code. What was row-level security trusting, and what does a parameter change?
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
