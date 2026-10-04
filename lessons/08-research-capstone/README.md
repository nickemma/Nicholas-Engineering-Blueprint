# Phase 8: defend the design and publish reproducible evidence

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: a type-along guide with the code inline, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This page previews the concepts, tools, readings, and exit evidence. The capstone uses the claims and limits supported by the completed phases; it remains useful when a result is negative or a domain assumption changes. Follow the full [self-study teaching guide](TEACHING.md) and record your work in [learned.md](learned.md).

The capstone's required security, supply-chain, and evaluation readings are embedded at the end of [TEACHING.md](TEACHING.md), beside the matching review steps.

## Question and build

Can another person reproduce the system's important results, understand its threat model, and judge its claims?

Review the prototype and its evidence, resolve any security gaps that should block publication, then publish a technical report describing the user need, question, architecture, baseline, guarantees, failures, measurements, privacy boundaries, limitations, and open questions.

## Teach in this order

1. **Freeze claims and scope.** List what the prototype does, what it does not do, and which evidence supports each statement.
2. **Complete the threat model.** Name assets, actors, trust boundaries, attacker capabilities, failure assumptions, and residual risks.
3. **Review system controls.** Check least privilege, TLS 1.3/mTLS, secrets handling, safe defaults, and explicit failure behavior against the Phase 5/6 implementation; fix blocking issues in the relevant phase and preserve evidence.
4. **Review the supply chain.** Record dependencies, scan components, create an SBOM, and preserve build provenance. Artifact signing is optional; if you sign, verify the signature from a clean environment and describe key custody.
5. **Attack and fail it.** Fuzz parsers, attempt policy bypass, inject node/network failures, and follow the recovery runbook. Do not claim a tool's result proves complete security.
6. **Reproduce the evaluation.** Run from a clean checkout with documented environment and data; regenerate reported measurements.
7. **Write and defend.** Explain design decisions, failed approaches, negative results, privacy limits, and questions not answered.

## Foundations closed

TLS/PKI review, least-privilege review, dependency/supply-chain controls, fuzzing and fault review, secure operations, and clear research claims. Revisit the non-root/capability/seccomp settings from Phase 5 and mark each one verified or unverified. This consolidates earlier topics; it does not make the prototype legally compliant or production-ready.

## Reading placement

Read Anderson's *Security Engineering* and van Steen & Tanenbaum security sections beside threat modeling and controls. Read TLS/firewall material during protected transport. Use in-toto and other supply-chain work when recording artifact provenance. Select primary papers in the capstone's exact area.

## Exit evidence and career signal

Reproduce the build and evaluation; demonstrate a failure and attempted bypass; present the report and explain guarantees, evidence, limitations, and unresolved risks.

This capstone consolidates distributed systems, SRE/platform, infrastructure security, and research evidence. It does not replace deeper kernel, security-specialist, or real on-call experience.
