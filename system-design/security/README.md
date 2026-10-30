# Security

For infrastructure security, platform and SRE roles, and for every senior loop that asks "and how would you secure it?". These designs put the controls you built in [Phase 6](../../lessons/06-safe-shared-queries/README.md) at system scale.

**Worked design:** [an authorization service for sharing](authorization-service.md). Do it yourself first, then compare.

**How to use the prompts:**
1. Set a 45-minute timer and design with the [template](../_template.md). Add a short **threat model** (what you protect, from whom) to the requirements.
2. Open **the crux** only if you haven't named one by minute 10.
3. Open **what a strong answer covers** only after the timer, then score yourself with the [scorecard](../scorecard.md).

## 1. Secrets distribution

Deliver database passwords, API keys and certificates to 5,000 services: no secret in code or images, short-lived credentials where possible, rotation without restarts, and an audit trail of every access.

<details><summary>The crux</summary>Identity first: before handing out a secret, the system must know which workload is asking, without a secret to prove it (the "secret zero" problem). Then short lifetimes and rotation, so a leak expires by itself.</details>

<details><summary>What a strong answer covers</summary>

- Workload identity from the platform (Kubernetes service account tokens, cloud instance identity).
- A secrets manager with policies per identity; dynamic secrets (per-workload database logins).
- Short TTLs with renewal; rotation without restarts (reload, or a connection pool refresh).
- Encryption as a service (transit) instead of handing out keys.
- Audit of every read; break-glass access.
- Failure: the secrets manager is down. What do running services do?
</details>

**Built in:** [Phase 6, step 9](../../lessons/06-safe-shared-queries/TEACHING.md#step-9-secrets) (OpenBao, per-Pod database logins, transit encryption, a sealed vault).

## 2. A tamper-evident audit log

Record every security-relevant action for 300 services: 50,000 events a second, kept for 7 years, such that nobody, including administrators, can change or delete history without it being detected.

<details><summary>The crux</summary>Making tampering detectable, not just forbidden: a Merkle tree over the log, signed checkpoints, and an independent witness, so even the operator can't rewrite history quietly.</details>

<details><summary>What a strong answer covers</summary>

- Append-only ingestion; ordering; durable storage (object storage with retention locks).
- A Merkle tree; inclusion proofs (this event is in the log) and consistency proofs (the log only grew).
- Signed checkpoints; external witnesses that refuse inconsistent ones.
- Searching seven years of events; privacy of the events themselves.
- What the design does not prevent (a compromised source writing lies).
</details>

**Built in:** [Phase 6, step 10](../../lessons/06-safe-shared-queries/TEACHING.md#step-10-a-tamper-evident-audit-log) (a Merkle-tree log, signed checkpoints, a witness), the [Rust Bridge](../../lessons/rust-bridge/README.md).

## 3. Certificates for a fleet

Issue and rotate TLS certificates for 50,000 workloads: mutual TLS between all services, certificates valid for 24 hours, rotation with zero downtime, and the ability to rotate the root of trust itself.

<details><summary>The crux</summary>Rotation at scale without outages: every workload must pick up new certificates before the old ones expire, and changing the CA means a period where both old and new must be trusted.</details>

<details><summary>What a strong answer covers</summary>

- An internal CA hierarchy (offline root, online intermediates).
- Identity in certificates (SPIFFE IDs); issuance tied to workload identity.
- Short lifetimes; renewal at two-thirds of the lifetime; reload without restarts.
- Long-lived connections must be recycled to pick up new certificates.
- CA rotation in phases: trust both, issue from new, stop trusting old.
- Monitoring: expiry metrics, rotation failures.
</details>

**Built in:** [Phase 6, step 7](../../lessons/06-safe-shared-queries/TEACHING.md#step-7-tls-and-your-own-certificate-authority) (your own CA, rotation in three phases, the connection-age finding).

## 4. Tenant isolation for a SaaS

A SaaS with 10,000 business customers on shared infrastructure: no customer can read another's data, no customer can starve others, and a large customer can buy dedicated resources.

<details><summary>The crux</summary>Isolation in every layer at once: data (queries, caches, search indexes, backups), compute (noisy neighbours), and identity, with the tenant carried through every hop so nothing can forget it.</details>

<details><summary>What a strong answer covers</summary>

- Tenant context from authentication, propagated everywhere (request context, messages, jobs).
- Data isolation options: a schema or database per tenant, against shared tables with row-level security.
- Caches, idempotency keys and search indexes keyed by tenant.
- Per-tenant rate limits and quotas; fair scheduling.
- Cells: groups of tenants on separate stacks, to limit blast radius; dedicated cells for big customers.
- Tests that try cross-tenant access on every endpoint.
</details>

**Built in:** [Phase 6, step 4](../../lessons/06-safe-shared-queries/TEACHING.md#step-4-tenants) (tenants down to row-level security, cache keys, idempotency keys).

## 5. API abuse protection

Protect a public API (login, sign-up, search) from credential stuffing, scraping and bots: 100,000 requests a second, without hurting real users.

<details><summary>The crux</summary>Telling abuse from real traffic cheaply, in layers, and responding proportionately (slow down, challenge, block), with signals beyond the IP address, because attackers rotate IPs.</details>

<details><summary>What a strong answer covers</summary>

- Layers: edge rate limits, per-account limits, per-endpoint cost.
- Signals: IP reputation, device fingerprints, behaviour, failed-login patterns across accounts.
- Responses: delays, challenges, temporary blocks, step-up authentication.
- Credential stuffing: breached-password checks, login rate limits per account and per source.
- Measuring false positives on real users.
- The OWASP API Security Top 10 as a checklist.
</details>

**Built in:** [Phase 6](../../lessons/06-safe-shared-queries/README.md) (rate limiting, the OWASP tests in the game day, signed webhooks safe from SSRF).
