# MERIDIAN — Distributed Secrets Manager

*Organization-grade project charter (24-point standard).*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../../README.md) — v1.1*

---

# Chapter 43 · MERIDIAN — Distributed Secrets Manager

**Existing flagship, re-examined in Level II · Provides: secrets, policy, lease, and audit engines to VEYRONIX and SYNAPSE-AI**

### 1–2 · Vision & problem

Secrets are the highest-value data in any infrastructure, and managing them under distribution — replication, leases, revocation, audit — is genuinely hard. MERIDIAN is your existing consensus-based secrets manager; in this blueprint it is re-examined with Level II’s theory and elevated to the interconnection hub whose policy, lease, and audit engines are reused by VEYRONIX and SYNAPSE-AI.

### Its role in the blueprint

- **Re-examination task (Level II):** revisit the Raft implementation, the WAL, and the linearizability story with fresh academic rigor; upgrade the README to the Meridian Standard it already defines; add or sharpen the TRADEOFFS and THREAT_MODEL.
- **Provides to VEYRONIX:** secret injection during deployment (the platform-eats-platform story).
- **Provides to SYNAPSE-AI:** the WASM policy engine, the TTL-lease semantics, and the append-only audit lineage — SYNAPSE’s planes are MERIDIAN’s ideas, extended with AI context.

### Charter highlights (already built — documented to standard)

- **Functional:** store/retrieve secrets; dynamic short-lived credentials via leases; deny-by-default policy in a WASM sandbox; tamper-evident audit; consensus-replicated state.
- **Non-functional:** linearizable secret reads on the strong path; lease revocation propagates cluster-consistently; survives node loss with quorum.
- **Trade-offs:** consensus on the critical path (consistency over raw latency) — correct for secrets; WASM policy (safety + hot-reload) over native (speed). Documented.
- **Security:** encryption at rest and in transit, mTLS between nodes, least-privilege leases, full audit — the model SYNAPSE inherits.

Because MERIDIAN predates the blueprint, its Level II work is *documentation and re-examination*, not a rebuild — but it is held to the identical charter standard so it sits beside the other five as an equal. It is, in many ways, the seed the whole identity grew from.
