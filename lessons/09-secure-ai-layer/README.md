# Phase 9: secure the AI layer

**Practice:** build the phase, complete one independent exercise, explain it, and test it.

**Question:** what can an AI agent on your platform be tricked into doing, and how do you make sure it can't?

**Time:** about 11 weeks. **Prerequisites:** Phases 0–8, especially [Phase 6](../06-safe-shared-queries/README.md) (threat modelling, tokens, authorization, tenants, signed webhooks and SSRF, secrets, privacy) and [Phase 8](../08-ai-infrastructure/README.md) (the model server and the gateway). Everything runs on a laptop's CPUs.

You give Runway an **operations assistant**: an agent that answers a tenant's questions from its own runbooks and job history, and can act on request: retry or cancel a job, add a note, send a notification. Then you attack it, the way a real attacker would, and make it hold.

One rule runs through the whole phase: **the model's output is untrusted input.** A language model can't reliably tell instructions from data, so no security decision may depend on it behaving. Identity, permissions, limits and audit are enforced in code the model can't talk to.

Every step follows the same order: build it, attack it until the attack works, fix it, and keep the attack as a regression test that must go on failing. Each finding is written up as a seven-part record: the threat, the security assumption, the test, what happened, the vulnerability, the mitigation, and the regression test.

## Syllabus

| Step | Build, attack and learn |
|---|---|
| 1 | A threat model for the AI layer: what we're building, assets, actors, trust boundaries, STRIDE and the OWASP Top 10 for LLM applications |
| 2 | How to attack a system: scope and rules, mapping the attack surface, hypotheses, payloads and evidence; an intercepting proxy; a vulnerability report. First target: the Phase 8 gateway |
| 3 | Retrieval over Runway's own data: embeddings on CPU, pgvector in Phase 3's PostgreSQL, tenant scoping with row-level security, retrieval quality measured |
| 4 | A tool-using agent: the agent loop in Python, a tool server in Go, step, token and time budgets |
| 5 | Tool authorization outside the model: identity on every call, narrowed tokens, deny by default, the confused deputy |
| 6 | Direct prompt injection: an attack harness against the real model; what prompt defences buy, and what enforcement buys |
| 7 | Indirect prompt injection: poisoned runbooks, job output and tool results; egress allow-lists; human approval for side effects |
| 8 | Unsafe use of model output: SQL, HTML and Markdown (data leaking through image links); validating structured output |
| 9 | Leaks between tenants: a missing filter, the shared prompt cache as a timing side channel, prompts in logs |
| 10 | Secrets and the model: no credentials in prompts, canary tokens that detect leaks |
| 11 | Resource abuse: token-cost attacks, runaway agent loops, padded context, per-tenant agent budgets |
| 12 | AI supply chain: model files that run code (pickle versus safetensors, in a sandbox), poisoned tool descriptions, signed weights |
| 13 | An adversarial test suite: in CI against a scripted fake model, live against the real one, attack success rates with intervals |
| 14 | Red team, then the report: attack the finished system as an outsider, chain findings, fix, re-attack, check every threat-model row |

## How to work through it

1. Follow [TEACHING.md](TEACHING.md) in your Phase 8 lab directory, beside your Runway checkout.
2. Run every attack yourself, against your own system, before reading the fix. Keep the raw evidence.
3. Answer [learned.md](learned.md), build [incidentdesk](exercises.md) independently, and take the [self-test](../../notes/learned/09-secure-ai-layer.md).
4. Read the [completion evidence](evidence/completion/report.md): passing component tests and deployed guarantees have different limits.

**Only attack what you own.** Every attack here targets your own lab. The same techniques against someone else's system, without written permission, are illegal in most countries.

## Status

All fourteen steps are written, and every result in them was measured on one laptop against a real model: Qwen2.5-1.5B-Instruct behind the Phase 8 gateway. Each step's raw outputs and rows are kept under `evidence/`, and the [completion report](evidence/completion/report.md) maps every threat-model row to them.

What that does and doesn't cover:

- **Measured:** the attacks and fixes in each step, with the model's actual replies, including the attacks that *didn't* work on this model (most of Step 7's planted instructions, and both of Step 8's deliveries) and how the guide tested those controls without the model.
- **Small samples:** a few dozen payloads per experiment, one run each at temperature 0. The intervals say how little a count of zero proves.
- **A lab, not a deployment:** the tool server keeps jobs in memory, the user tokens are a minimal Ed25519 format rather than the Phase 6 issuer's JWTs, and approvals happen at a command prompt. The completion report lists what a deployment would still need to show.
