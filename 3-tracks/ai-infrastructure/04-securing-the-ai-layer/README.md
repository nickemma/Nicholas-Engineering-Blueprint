# 04 Securing the AI layer

> AI infrastructure track · Time 9 weeks at 12–15 hours a week, plus an optional red team · Builds on [Serving and scaling models](../02-serving-and-scaling-models/README.md), [Tenancy and abuse control](../../shared-units/tenancy-and-abuse-control/README.md) and [Core 08 Shipping safely](../../../2-core/08-shipping-safely/README.md) · Status ready

Give Switchyard an **operations assistant**: an agent that answers a tenant's questions from its own runbooks and job history, and acts on request: it retries or cancels a job, adds a note, or sends a notification. Then attack it the way a real attacker would, and make it hold. One rule runs through the whole module: **the model's output is untrusted input.** A language model can't reliably tell instructions from data, so no security decision may depend on it behaving. Identity, permissions, limits and audit are enforced in code the model can't talk to.

Every lesson that builds something attacks it next: build it, attack it until the attack works, fix it, and keep the attack as a regression test that must go on failing. Each finding is written up as a seven-part record: the threat, the security assumption, the test, what happened, the vulnerability, the mitigation, and the regression test.

Start with [Before you start](lessons/00-before-you-start.md). Everything runs on a laptop's CPUs, in your lab from Serving and scaling models. **Only attack what you own.** The same techniques against someone else's system, without written permission, are illegal in most countries.

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [A threat model for the AI layer](lessons/01-a-threat-model-for-the-ai-layer.md) | Assets, actors, trust boundaries, STRIDE and the OWASP Top 10 for LLM applications, for a system that doesn't exist yet. |
| 1 | 02 | [How to attack a system](lessons/02-how-to-attack-a-system.md) | Scope and rules, the attack surface, hypotheses, payloads and evidence, and a vulnerability report. First target: your inference gateway. |
| 2–3 | 03 | [Retrieval over the tenant's runbooks and jobs](lessons/03-retrieval-over-the-tenants-runbooks-and-jobs.md) | Embeddings on CPU, pgvector in PostgreSQL, tenant scoping with row-level security, and retrieval quality measured. |
| 4 | 04 | [A tool-using agent](lessons/04-a-tool-using-agent.md) | The agent loop in Python, a tool server in Go, and step, token and time budgets. |
| 5 | 05 | [Authorization outside the model](lessons/05-authorization-outside-the-model.md) | Identity on every call, narrowed tokens, deny by default, and the confused deputy. |
| 5 | 06 | [Direct prompt injection](lessons/06-direct-prompt-injection.md) | An attack harness against the real model: what prompt defences buy, and what enforcement buys. |
| 6 | 07 | [Indirect injection and approval for side effects](lessons/07-indirect-injection-and-approval-for-side-effects.md) | Poisoned runbooks, job output and tool results; egress allow-lists; human approval for changes. |
| 7 | 08 | [Unsafe model output](lessons/08-unsafe-model-output.md) | SQL, HTML and Markdown, including data leaking through image links; validated structured output. |
| 7 | 09 | [Leaks between tenants](lessons/09-leaks-between-tenants.md) | A missing filter, the shared prompt cache as a timing side channel, and prompts in logs. |
| 8 | 10 | [Secrets and canary tokens](lessons/10-secrets-and-canary-tokens.md) | No credentials in prompts, and canaries that detect a leak. |
| 8 | 11 | [Resource abuse and per-tenant limits](lessons/11-resource-abuse-and-per-tenant-limits.md) | Token-cost attacks, runaway agent loops, padded context, and per-tenant agent budgets. |
| 9 | 12 | [The AI supply chain](lessons/12-the-ai-supply-chain.md) | Model files that run code (pickle versus safetensors, in a sandbox), poisoned tool descriptions, signed releases. |
| 9 | 13 | [The adversarial suite](lessons/13-the-adversarial-suite.md) | The attacks as a suite: in CI against a scripted model, live against the real one, with intervals. Run the gate. |
| Optional | 14 | [Red team, then the report](lessons/14-red-team-then-the-report.md) | Attack the finished system as an outsider, chain findings, fix, re-attack, and check every threat-model row. |

## The gate

The [gate](gate/README.md) runs every test, including the adversarial suite against a scripted model, and the tool server's race tests. Then it removes six defences one at a time, in a disposable copy: approval before a change, escaping the model's answer, the tenant in the cache key, the canary check, the release signature check, and the tool server's tenant check. Each removal must be caught by the test that covers it. You haven't finished the module until it passes.

Every result in the lessons was measured on one laptop against a real model, Qwen2.5-1.5B-Instruct, with a few dozen payloads per experiment at temperature 0. The gate checks the controls that hold whatever the model does; the live attack rates are evidence about this model, not guarantees.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Explain why a model's output is untrusted input, and point to where each decision is enforced. |
| Intermediate | Reproduce an injection, fix it in code the model can't influence, and keep the attack as a test that must go on failing. |
| Senior | Map every threat-model row to evidence, say which rows held only with limits, and name the experiment that would change each verdict. |

## Practice

- [Exercises](exercises.md). Build incidentdesk, an incident assistant for two organizations sharing a support platform.
- [Self-check](self-check.md). Explain each result from your own evidence, then answer from memory.

Then build the track's [capstone](../05-capstone-inference-gateway/README.md).

---

<sub>The raw runs behind this module's outputs and its gate are in [evidence/](evidence/README.md), with the [completion report](evidence/completion/report.md) that maps every threat-model row to them. You don't need them to follow the lessons.</sub>
