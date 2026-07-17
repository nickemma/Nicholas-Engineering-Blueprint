# Level V — Security Engineering & Governance

*A full mini-course: theory → labs → production flagship → exit criteria.*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../../README.md) — v1.1*

---

# Chapter 23 · Level V — Security Engineering & Governance

**Weeks 33–38 · Flagship: SYNAPSE-AI (core) · Cloud: AWS · Pre-covers: CIS 5510, CIS 5580, CIS 5560 (with the Crypto Thread)**

### Overview & why it matters

Penn’s thesis is that AI can write code but can’t design secure systems. This level is you proving you can design the secure system that governs the AI — and it is concentrated (six weeks) because you arrive with real security instincts (Meridian’s policy/lease/audit engines, the Google Cybersecurity cert). It formalizes and extends rather than teaching from zero, and it builds the core of SYNAPSE-AI, the flagship your portfolio already promises.

### Objectives / Learning outcomes

- Threat-model first: STRIDE, attack trees, risk economics, communicating tradeoffs to stakeholders (the CIS 5580 skill).
- Command applied cryptography: PKI, TLS/mTLS internals, an internal CA, hash-chained audit — the Crypto Thread’s payoff.
- Give AI agents first-class identity, least privilege, TTL-bound credentials, and behavioral monitoring — governing a model the way an enterprise governs a person.
- Map every control to a governance framework: NIST AI RMF, OWASP LLM Top 10, EU AI Act.

### Prerequisites

Levels I–IV — SYNAPSE governs TESSERA-served agents through an EMBER-based gateway, reusing MERIDIAN’s policy/lease/audit lineage. Crypto Thread Sets 1–5 done coming in.

### Timeline

Six weeks: security foundations + internal CA (33) → threat model, the gate (34) → identity plane (35) → policy plane & LLM threats (36) → audit, provenance & compliance (37) → behavioral security (38). Integration and red-team land in Level VI (39–40).

### Theory

- Security foundations: authn/authz, PKI & certificate chains, TLS/mTLS deep pass, OWASP Top 10, DDoS.
- Threat modeling & secure SDLC: STRIDE, attack trees, security economics, risk communication.
- Identity for non-humans: workload identity (SPIFFE/SVID), delegation, capability tokens (Macaroons), Zanzibar-style relationship auth.
- LLM threatscape: prompt-injection taxonomy, the lethal trifecta, tool-use risks, exfiltration channels, output handling.
- Audit, provenance & compliance: tamper-evident logs, model/data provenance, NIST AI RMF, EU AI Act, SOC 2 mapping.
- Behavioral security: per-identity baselines, deviation scoring, runtime enforcement, kill switches.

### Architecture concepts

- The core thesis engineered: enterprises govern humans with identity, least privilege, leases, audit, and monitoring — then hand AI agents god-mode keys. SYNAPSE closes that asymmetry.
- Where the enforcement point goes: proxy (data plane) vs SDK vs model-side — and why the proxy wins for untrusted agents.
- Zero-trust for machine principals: never trust the prompt, verify the identity, scope the credential, bound the time, audit the action.

### Hands-on labs & assignments

- Labs: synapse-ca issuing short-lived SVID-style workload certs; the full STRIDE threat model (the deliverable that gates the build); deny-by-default WASM tool policies (Meridian’s engine, extended with AI context); a hash-chained audit log + verifier CLI; a per-agent anomaly baseline with auto-quarantine.
- Assignments: give every agent an SVID with recorded delegation chains (no shared keys anywhere); generate a control-to-evidence compliance matrix automatically; wire the policy engine to gate a live agent.

### Production project — SYNAPSE-AI (core)

“Treating AI Like a User”: an AI governance plane giving every model/agent a cryptographic identity (synapse-ca), TTL-bound scoped credentials (lease service), deny-by-default tool/data policies (WASM engine), a tamper-evident audit chain, and behavioral anomaly detection — with an EMBER-based data-plane gateway between agents and everything they touch, and a governance console mapping controls to NIST AI RMF / OWASP LLM Top 10 / EU AI Act. The core ships this level; integration + red-team complete it in Level VI. Full charter in Part VI.

### Reading — tiered

- **Required:** Security Engineering 3e (Anderson, free) ch. 1–5, 9, 21 · Threat Modeling (Shostack) · NIST AI RMF core · OWASP LLM Top 10.
- **Recommended:** Serious Cryptography 2e (Aumasson) · Katz & Lindell (problem sets, for CIS 5560 math).
- **Papers/frameworks:** Zanzibar · Macaroons · BeyondCorp · Google SAIF · “Model Cards” · SPIFFE/SPIRE docs · the EU AI Act obligations summary.
- **Blogs:** Simon Willison’s prompt-injection series (essential). **RFCs/specs:** X.509 basics; the SPIFFE spec. **Repos:** SPIRE; Open Policy Agent.

### Open source tasks

Ladder Stage 8–9 (design discussions → maintainer collaboration): review others’ PRs in your subsystem; contribute to a security-adjacent discussion. Quality over quantity now — you are becoming a known name.

### Deliverables

- **GitHub:** THREAT_MODEL.md public Wk34 (a rare, high-signal artifact); synapse-ai core public as it builds.
- **Portfolio:** SYNAPSE-AI featured; the compliance console screenshotted.
- **Blog:** the technical/architecture/reflection pieces this level (the flagship essay lands in Level VI with the finished system).

### Interview topics unlocked

Threat modeling a system live; PKI and mTLS; prompt injection and the lethal trifecta; zero-trust for machine identities; “design a secrets manager / an authz system / a secure API gateway / an AI-agent sandbox”; communicating security tradeoffs to non-security stakeholders.

### Weekly schedule

Chapter 14 default; interview season continuing; the threat model (Wk34) takes a full morning-block sequence before any security-relevant code.

### Exit criteria

- SYNAPSE-AI core: identity, policy, lease, and audit planes each demonstrable in isolation.
- THREAT_MODEL.md public; internal CA issuing and rotating certs; compliance matrix auto-generating.
- Crypto Thread Sets 1–6 complete; Meridian-Standard docs in progress.

### Reflection questions

What did threat-modeling-first change versus building-then-securing? Where is the AI-agent security problem genuinely new, and where is it old security wearing new clothes? Which control would you least want to defend in a red-team — and why?
