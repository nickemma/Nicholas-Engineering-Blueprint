# 00 Before you start

<!-- continue: ../../02-serving-and-scaling-models -->

This module gives Switchyard an **operations assistant**, then attacks it. A tenant's staff ask it questions ("why did job 4182 fail?", "what does the runbook say about stuck exports?"), and it answers from that tenant's own runbooks and job history. Asked to, it acts: it retries or cancels a job, adds a note, or sends a notification to the tenant's webhook.

That's useful, and it's dangerous in a new way. The assistant reads text other people wrote: runbooks, job descriptions, failure messages. A language model can't reliably tell an instruction from data, so any of that text can try to steer it. [Core 08](../../../../2-core/08-shipping-safely/README.md) and [Tenancy and abuse control](../../../shared-units/tenancy-and-abuse-control/README.md) secured services that do what their code says. This module secures one that does what its *input* says.

**Time:** about 9 weeks for the required lessons; lesson 14, the red team, is optional. **Before you start:** finish [Serving and scaling models](../../02-serving-and-scaling-models/README.md); this module works in its lab directory and attacks its gateway.

## How this module works

Type everything, run every check, and work in your lab directory from Serving and scaling models. The new Python code goes in `serve`, the new Go tool server in its own module, and the security documents in `docs/security`. When you finish, run [the gate](../gate/README.md) on that lab directory.

Every lesson that builds something then attacks it, in this order:

1. **Build** the feature.
2. **Attack** it until the attack works, and keep the evidence.
3. **Fix** it, in code the model can't influence.
4. **Keep the attack** as a regression test that must go on failing.

Each finding is written up as a **seven-part record**: the threat, the security assumption, the test, what happened, the vulnerability, the mitigation, and the regression test. Lesson 02 shows how.

**Only attack what you own.** Everything here targets your own lab. The same techniques against someone else's system, without written permission, are illegal in most countries.

**Names in the code:** the assistant's system prompt, the attack payloads and the recorded replies say "Runway", the platform's earlier name. They're kept word for word, because the measured results came from those exact strings.

| Lesson | What you add |
|---|---|
| 01 | The threat model for the AI layer |
| 02 | How to attack a system, starting with the gateway from Serving and scaling models |
| 03 | Retrieval over the tenant's runbooks and jobs |
| 04 | The agent and its tool server |
| 05 | Tool authorization outside the model |
| 06 | Direct prompt injection |
| 07 | Indirect prompt injection |
| 08 | Unsafe use of model output |
| 09 | Leaks between tenants |
| 10 | Secrets and canaries |
| 11 | Resource abuse |
| 12 | The AI supply chain |
| 13 | The adversarial test suite |
| 14 | *Optional:* red team, then the report |

---
