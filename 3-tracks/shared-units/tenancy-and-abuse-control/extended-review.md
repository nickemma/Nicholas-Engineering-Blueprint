# Extended review

Related modules for this review are [Core shipping controls](../../../2-core/08-shipping-safely/README.md), [Proxy control plane](../../cloud-and-network/03-proxy-control-plane/README.md), [Audit and integrity](../../storage-engines/04-integrity-and-encryption/README.md).

Answer from memory, then check yourself against [the lesson](README.md). Write each "predict" answer before running anything.

## A. Threat modelling

1. What are Shostack's four questions? Which step of the phase answers each?
2. What is a trust boundary? Name three in Switchyard, including one the step 1 diagram doesn't draw.
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
12. Policy decision point vs enforcement point: give Switchyard's, and say why there's one decision point.
13. Predict: a new route is added without asking the policy. Which test catches it, and how?

## C. Tenants and capacity

14. What is BOLA? Why is `404` the right answer for another tenant's job?
15. Name every place Switchyard uses a job's ID as a key, and how each is scoped to a tenant.
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
41. What is a canary, and what did Switchyard's inventory find that nobody had written?
42. Why does redaction come second to not logging? What can't redaction by shape catch?
43. Explain the `search_path` attack on a `SECURITY DEFINER` function, and its fix.
44. Why is retention only as short as the longest-lived copy? Name Switchyard's.
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

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, the failing output of each "Break it", log lines, captures. Keep your filled-in copy in your own repository.

### Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | What are Shostack's four questions, and where does Switchyard answer each? | | |
| 1 | Why must identity come before authorization, tenants and rate limits? | | |
| 1 | Pick three threats: which property does each violate, and what would an attacker do? | | |
| 2 | Why does the API verify with a public key, and what would a shared HMAC secret allow? | | |
| 2 | What does each of the five checks in `Verify` stop? | | |
| 2 | Why did removing the algorithm check not let `alg: none` through, and why keep it? | | |
| 2 | Why does `RemoteJWKS` limit refetches? | | |
| 3 | Decision point vs enforcement point: why one decision point? | | |
| 3 | Why must authorization come before the idempotency middleware? | | |
| 4 | Why does the tenant come from the token, and why `404` rather than `403`? | | |
| 4 | List every place Switchyard keys data by job ID, and how each is scoped to a tenant | | |
| 4 | Why was the first `current_tenant()` fail-quiet, and why is that worse than an error? | | |
| 5 | Why did more workers not fix the noisy neighbour? | | |
| 5 | Why didn't 309 successes prove the bucket was shared, and what did? | | |
| 6 | What does each signed part of a webhook (ID, timestamp, body) protect against? | | |
| 6 | Why is the registration check a courtesy and the dial-time check the guard? | | |
| 6 | Why did a stopped notifier stop jobs from running? | | |
| 7 | What does mutual TLS prove that a token doesn't, and the other way round? | | |
| 7 | Why is `InsecureSkipVerify` safe in `ClientConfig`? | | |
| 7 | Why did the gateway never reload its certificate at first? | | |
| 7 | Why does replacing a CA take three phases? | | |
| 8 | Where did the sidecar's cost come from, and how did the plain relays show it? | | |
| 8 | Why did a stolen API certificate get into Redis, and why did removing `--bind` go unnoticed? | | |
| 9 | How does a Pod prove who it is to OpenBao without a secret? | | |
| 9 | Why does each login fetch log in afresh? What happened when the token was shorter than the login? | | |
| 9 | What does `INHERIT FALSE` change, and why did the shared test server hide its removal? | | |
| 9 | Describe each stage of the sealed-OpenBao experiment | | |
| 10 | Why isn't a hash chain enough, and what does a witness add? | | |
| 10 | What can an attacker still do after this step? | | |
| 11 | Which personal-data findings came from code nobody wrote? | | |
| 11 | What's the `search_path` attack on a `SECURITY DEFINER` function? | | |
| 11 | Why does a threshold fail against differencing, and what did the noise cost? | | |
| 12 | Why must DNS be allowed separately, and why did a rule for `10.96.0.1:443` not work? | | |
| 12 | What did fuzzing find, and what did it miss? | | |
| 13 | Why does a check need a control? What did the first T16 prove? | | |
| 13 | For each open finding, what's the smallest change that closes it? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| Step 1's posture: `201` with no credentials, a superuser login, no policies | | |
| A token for another audience refused; the test that fails without the check | | |
| A rotated signing key: old and new tokens both accepted | | |
| A reader refused a write; the denial logged with its reason | | |
| Another tenant's job: `404` from the API; refused by RLS with no `WHERE` | | |
| The cache-key and idempotency-key breaks, each caught by a test | | |
| The noisy neighbour: waits with and without the limit | | |
| One shared bucket shown with a new connection per request | | |
| A replayed webhook, a changed body, a stale timestamp: each refused | | |
| SSRF refused at registration and at dial time | | |
| Jobs still run with the notifier stopped | | |
| A forged Raft vote demoting the leader, then refused | | |
| Certificates renewed under load with no errors; a CA rotated with none | | |
| Redis unreachable without the API's certificate | | |
| The sidecar's cost: throughput, latency, CPU | | |
| Per-Pod database logins rotating under load | | |
| A leaked login: what it can't do; revoked mid-session | | |
| An edited audit log refused by the witness and flagged by `auditctl` | | |
| The canary inventory, before and after | | |
| Descriptions blanked; dead letters expired | | |
| The differencing attack, with and without noise | | |
| Ports from another namespace, before and after network policy | | |
| A root Pod refused by Pod Security | | |
| A fuzzer's find, and its test in `testdata` | | |
| The game day: held, open, and the controls | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the guide, and why:
- What is still unclear:
