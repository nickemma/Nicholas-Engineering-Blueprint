# SYNAPSE-AI — the journey

The system lives at **https://github.com/nickemma/synapse**. Threat model is the **first commit**, tagged `v0.0.1-threat-model` before any code.
Its architecture, API, threat model, runbook, and benchmark results live there, current
as of `main`. This directory holds what the code cannot: intent, prediction, surprise,
and judgment.

- Charter (frozen intent) — [/docs/part-6-flagships/synapse-ai.md](../../docs/part-6-flagships/synapse-ai.md)
- Repository standard — [Chapter 40b](../../docs/part-6-flagships/repo-standard.md)
- [calibration.md](calibration.md) — every prediction, predicted beside actual
- [as-built.md](as-built.md) — written at level exit, never before
- Detours triggered by this build — [/detours](../../detours)

**Status:** ○ not started

## Behavior ladder (Modules 5–6)

Charter point 3 decomposed into shippable increments. Written at kickoff; see
[Chapter 40b §5](../../docs/part-6-flagships/repo-standard.md).

| | Behavior | Satisfies charter point 3 |
|---|---|---|
| B1 | threat model exists before any code, and gates it | constraint 5 — STRIDE gates the build |
| B2 | a CA issues short-lived workload certs; rotation causes no outage | internal CA, SVID-style certs |
| B3 | every agent has identity; agent-spawns-agent is a delegation chain | delegation chains, zero shared keys |
| B4 | policy engine denies a tool call by default; decision trace shown | deny-by-default WASM policy per call |
| B5 | an injection attempting exfiltration is stopped at the tool boundary | data-plane gateway, policy inline |
| B6 | audit log hash-chained; verifier CLI catches tampering | tamper-evident audit |
| B7 | anomaly engine quarantines an agent that deviates from baseline | anomaly detection + auto-quarantine |
| B8 | compliance matrix generates from real controls, not prose | NIST AI RMF / OWASP LLM / EU AI Act |
| B9 | capstone: agent → lease → EMBER → policy → audit, six systems | the signature flow (point 8) |
| B10 | you red-team it and publish findings, including unfixed ones | the red-team suite (point 19) |


## Session log

| # | Date | Shipped | Tag | Detours | Loose end |
|---|---|---|---|---|---|
