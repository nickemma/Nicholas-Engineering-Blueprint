# Evidence: Securing the AI layer

The raw runs behind this module's outputs. You don't need them to follow the lessons. Every result was measured on one laptop against a real model, Qwen2.5-1.5B-Instruct, behind the gateway from Serving and scaling models.

## The gate

[gate/](gate/) holds the gate's runs on the reference lab, rebuilt from the lessons: [a pass](gate/pass.txt), [an agent that skips approval](gate/broken-no-approval.txt), and [a tool-server test weakened so no case crosses tenants](gate/broken-tenant-cases-weakened.txt). Paths are shortened to `~/lab`.

## By lesson

The folders keep the old step numbers, which match the lesson numbers.

| Lesson | Evidence |
|---|---|
| 02 | [gateway-assessment](gateway-assessment/) |
| 03 | [retrieval](retrieval/) |
| 04 | [step04-agent-loop](step04-agent-loop/) |
| 05 | [step05-confused-deputy](step05-confused-deputy/) |
| 06 | [step06-direct-injection](step06-direct-injection/) |
| 07 | [step07-indirect-injection](step07-indirect-injection/) |
| 08 | [step08-unsafe-output](step08-unsafe-output/) |
| 09 | [step09-tenant-leaks](step09-tenant-leaks/) |
| 10 | [step10-secrets](step10-secrets/) |
| 11 | [step11-resource-abuse](step11-resource-abuse/) |
| 12 | [step12-supply-chain](step12-supply-chain/) |
| 13 | [step13-adversarial-suite](step13-adversarial-suite/) |
| 14 | [step14-red-team](step14-red-team/) |

The [completion report](completion/report.md) maps every threat-model row to this evidence.

## Limits

- **Small samples:** a few dozen payloads per experiment, one run each at temperature 0. The intervals say how little a count of zero proves.
- **Measured, including what didn't work:** most of lesson 07's planted instructions, and both of lesson 08's deliveries, didn't fool this model; the lessons test those controls without it.
- **A lab, not a deployment:** the tool server keeps jobs in memory, the user tokens are a minimal Ed25519 format rather than Tenancy and abuse control's JWTs, and approvals happen at a command prompt. The completion report lists what a deployment would still need to show.
