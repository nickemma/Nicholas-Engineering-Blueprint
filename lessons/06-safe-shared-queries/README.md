# Phase 6: enforce safe cross-site queries

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: full code in `steps/`, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This page previews the concepts, tools, readings, and exit evidence. The base lesson uses a fixed synthetic query so it can be completed without partner access; domain-specific extensions come only after a real query is validated. Follow the full [self-study teaching guide](TEACHING.md) and record your work in [learned.md](learned.md).

The guide embeds the security reading alongside identity and abuse testing. Select privacy papers only after the query and threat model are defined; the guide gives the selection criteria and records that decision.

## Question and build

What may one site learn from another, who may ask, and what should happen when identity or policy cannot be checked?

Build one narrow query over synthetic records. The practice harness uses site IDs in one disposable database so the policy and audit path can be exercised locally; it does not prove separate organizations control separate database servers. In the Kestrel transfer, preserve local site custody, approve or reject at each site, release only the minimum summary, and record an audit event.

## Teach in this order

1. **Name the actors and data.** Draw requester, site, data steward, operator, source record, summary, and audit event. Classify what each may see.
2. **Write the threat model.** Define attacker capabilities, protected assets, trust boundaries, and explicit non-goals before adding a policy engine.
3. **Authenticate before authorizing.** Explain user identity versus site/workload identity. The core local exercise uses explicit user-claim fixtures and test mTLS certificates for service identity; OIDC verification is a separately documented follow-up.
4. **Implement a policy decision.** Define purpose, role, site, and query constraints. Fail closed if identity or policy is unavailable.
5. **Release the minimum answer.** Query locally and expose only approved fields/aggregates. Log who asked what, which rule applied, what was released, and when.
6. **Test misuse.** Try denied, expired, replayed, combined, and repeated queries. Analyze inference/leakage; do not call an aggregate harmless by default.
7. **Decide whether privacy technology is needed.** Consider differential privacy or secure multi-party computation only if the query/threat model justifies the added complexity. Compare to a simpler summary.

## Foundations closed

TLS/PKI, service identity, trusted user claims, least privilege, authorization, purpose limitation, auditability, and privacy leakage analysis. The local harness tests site-scoped policy; the Kestrel transfer is where separate site custody is preserved and reviewed.

The prototype is not a legal compliance claim and does not prove an aggregate cannot reveal sensitive information.

## Reading placement

Define the query and threat model first. Then read access-control/distributed-system security material and primary privacy-preserving analysis papers that match the chosen query. Read TLS/network authentication sections beside the site-identity implementation. Select sources with a domain/security collaborator once scope is known.

## Exit evidence and career signal

Show allowed, denied, expired, replayed, and repeated-query behavior. Trace each result to its policy and audit event. Explain residual leakage and unavailable-policy behavior.

This strengthens infrastructure security and privacy engineering profiles. Specialist security/privacy research requires deeper dedicated work.
