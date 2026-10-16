# Phase 6 self-test

Answer from memory, then check yourself against [the lesson](../../lessons/06-safe-shared-queries/TEACHING.md). Write each "predict" answer before running anything.

## A. Threat modelling

1. What are Shostack's four questions? Which step of the phase answers each?
2. What is a trust boundary? Name three in Runway, including one the step 1 diagram doesn't draw.
3. Name the six STRIDE threats and the property each violates.
4. Why does each threat in the model carry a command as evidence?
5. Why is "the operator" a non-goal, and what would it take to change that?

## B. Identity and authorization

6. What is a JWT made of? What can anyone holding one read?
7. List the five checks in `Verify`, in order, and the attack each stops.
8. Predict: you remove the audience check. Which test fails, with what error, and what could an attacker now do?
9. Why does an asymmetric signature suit an API that many services verify?
10. How does a key rotation proceed without breaking any valid token? What are the two waiting periods?
11. Why does the API refuse to start without `AUTH_ISSUER`?
12. Policy decision point vs enforcement point: give Runway's, and say why there's one decision point.
13. Predict: a new route is added without asking the policy. Which test catches it, and how?

## C. Tenants and capacity

14. What is BOLA? Why is `404` the right answer for another tenant's job?
15. Name every place Runway uses a job's ID as a key, and how each is scoped to a tenant.
16. To which roles does row-level security apply? Why does the store `SET LOCAL ROLE`?
17. Why did the first `current_tenant()` quietly match nothing, and why is an error better?
18. Predict: the cache key loses its tenant. Which existing test catches it? (Careful.)
19. Explain a token bucket without a timer. Why does the Redis version run as one Lua script?
20. Why does the limiter charge only requests the policy allowed?
21. Why did more workers not help the noisy neighbour, and why didn't 309 successes prove the bucket was shared?

## D. Webhooks and SSRF

22. What does a webhook signature cover, and what attack does each part stop?
23. Why does a duplicate get `200`? Why is an ID remembered only after the work succeeds?
24. What is DNS rebinding, and why is the dial-time check the real guard?
25. Predict: the notifier is stopped and 150 jobs are sent. With one outbox relay for all destinations, what happens to the jobs?

## E. TLS, sidecars and secrets

26. What does mutual TLS prove, and what doesn't it?
27. What is a SPIFFE identity, and why does a certificate name a service rather than an address?
28. Why does `ClientConfig` set `InsecureSkipVerify`, and why is that safe there?
29. Why did the busy gateway never reload its certificate in the first version? What fixed it?
30. Describe the three phases of a CA rotation. Predict: you skip straight to the new CA. What fails, for how long, and why does `metad` survive?
31. What can a layer-4 proxy not see? What did the sidecar's cost come from, measured?
32. Why does a native sidecar matter more at shutdown than at start?
33. How does a Pod log in to OpenBao? What is a TokenReview?
34. Why does each database login come with a fresh OpenBao token? Predict: the token lasts one minute and the login two.
35. What does `INHERIT FALSE` change? Why did a test server hide its removal?
36. Why can the API seal a webhook secret but not open it?
37. Predict: OpenBao is sealed for three minutes. What do the running API Pods do, what does a new one do, and what happens at the moment of unsealing?

## F. Audit and privacy

38. Why can't a checksum, or a hash chain, stop someone who can rewrite the file?
39. What does a Merkle tree's root commit to? What do inclusion and consistency proofs show?
40. What does the witness check, and why must it be run by someone else?
41. What is a canary, and what did Runway's inventory find that nobody had written?
42. Why does redaction come second to not logging? What can't redaction by shape catch?
43. Explain the `search_path` attack on a `SECURITY DEFINER` function, and its fix.
44. Why is retention only as short as the longest-lived copy? Name Runway's.
45. Explain the differencing attack, why a threshold doesn't stop it, and what the noise cost on four tenants.
46. Why is each day's statistic published once?

## G. The cluster and the game day

47. What does a default-deny NetworkPolicy do, and why must DNS have its own?
48. Why did an egress rule to the API server's Service address match nothing on kind?
49. What does Pod Security's `restricted` level require?
50. Why remove a token from a Pod whose account can do almost nothing?
51. What did fuzzing find in this phase, and what did it miss that a direct test found?
52. Why does a game-day check need a control? What did the first T16 prove?
53. Name the three open findings, and the smallest fix for each.
