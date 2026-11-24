# 00 Before you start

<!-- continue: ../../02-serving-and-scaling-models -->

This phase gives Switchyard an **operations assistant**, then attacks it. A tenant's staff ask it questions ("why did job 4182 fail?", "what does the runbook say about stuck exports?"), and it answers from that tenant's own runbooks and job history. Asked to, it acts: it retries or cancels a job, adds a note, or sends a notification to the tenant's webhook.

That's useful, and it's dangerous in a new way. The assistant reads text other people wrote: runbooks, job descriptions, failure messages. A language model can't reliably tell an instruction from data, so any of that text can try to steer it. Phase 6 secured services that do what their code says. This phase secures one that does what its *input* says.

## How this guide works

The same as Phase 8: type everything, run every check, and work in your Phase 8 lab directory. The new Python code goes in `serve`, the new Go tool server in its own module, and the security documents in `docs/security`.

Every step that builds something then attacks it, in this order:

1. **Build** the feature.
2. **Attack** it until the attack works, and keep the evidence.
3. **Fix** it, in code the model can't influence.
4. **Keep the attack** as a regression test that must go on failing.

Each finding is written up as a **seven-part record**: the threat, the security assumption, the test, what happened, the vulnerability, the mitigation, and the regression test. Step 2 shows how.

**Only attack what you own.** Everything here targets your own lab. The same techniques against someone else's system, without written permission, are illegal in most countries.

| Step | What you add |
|---|---|
| 1 | The threat model for the AI layer |
| 2 | How to attack a system, starting with the Phase 8 gateway |
| 3 | Retrieval over the tenant's runbooks and jobs |
| 4 | The agent and its tool server |
| 5 | Tool authorization outside the model |
| 6 | Direct prompt injection |
| 7 | Indirect prompt injection |
| 8 | Unsafe use of model output |
| 9 | Leaks between tenants |
| 10 | Secrets and canaries |
| 11 | Resource abuse |
| 12 | The AI supply chain |
| 13 | The adversarial test suite |
| 14 | Red team, then the report |

---
