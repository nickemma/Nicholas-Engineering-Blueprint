# Phase 6: what I learned

Fill this in as you go, with evidence: commands and their output, test names, the failing output of each "Break it", log lines, captures. Keep your filled-in copy in your own repository.

## Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | What are Shostack's four questions, and where does Runway answer each? | | |
| 1 | Why must identity come before authorization, tenants and rate limits? | | |
| 1 | Pick three threats: which property does each violate, and what would an attacker do? | | |
| 2 | Why does the API verify with a public key, and what would a shared HMAC secret allow? | | |
| 2 | What does each of the five checks in `Verify` stop? | | |
| 2 | Why did removing the algorithm check not let `alg: none` through, and why keep it? | | |
| 2 | Why does `RemoteJWKS` limit refetches? | | |
| 3 | Decision point vs enforcement point: why one decision point? | | |
| 3 | Why must authorization come before the idempotency middleware? | | |
| 4 | Why does the tenant come from the token, and why `404` rather than `403`? | | |
| 4 | List every place Runway keys data by job ID, and how each is scoped to a tenant | | |
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

## Evidence checklist

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

## Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the guide, and why:
- What is still unclear:
