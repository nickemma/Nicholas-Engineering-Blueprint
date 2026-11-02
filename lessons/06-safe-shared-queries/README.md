# Phase 6: secure it

**Question:** who may do what in Runway, how does each service know who it's talking to, how do you keep one customer's data and capacity away from another's, and how would you know if any of it failed?

**Time:** about 10 weeks. **Prerequisites:** [Phase 5](../05-constrained-operations/README.md), with its kind cluster; `openssl`, `jq`, `curl`; the Rust toolchain from the [Rust Bridge](../rust-bridge/README.md); `uv` for kload. Everything runs locally: OpenBao runs in Compose and on kind.

## Syllabus

| Step | Topic | You'll learn |
|---|---|---|
| 1 | A threat model | Shostack's four questions; data-flow diagrams and trust boundaries; assets and actors; STRIDE; evidence for every threat; non-goals |
| 2 | Tokens | Authentication vs authorization; bearer tokens; OAuth 2.0 client credentials; OIDC discovery; JWTs and Ed25519; JWKS, key IDs and rotation; the five checks a verifier makes and the attack each stops; failing closed |
| 3 | Authorization | Policy decision and enforcement points; RBAC, ABAC, ReBAC; deny by default; least privilege; 401 vs 403; testing every route from the other side |
| 4 | Tenants | BOLA; tenant context propagation through requests, transactions, messages, workers and caches; 404 not 403; PostgreSQL row-level security and the roles it skips; fail-quiet vs fail-closed |
| 5 | Rate limiting | Token buckets; 429 and `Retry-After`; local vs shared buckets; atomic Lua in Redis; fail open, not wide open; the noisy-neighbour experiment, and why kload's pooled connections hid a question |
| 6 | Signed webhooks | HMAC over ID, timestamp and body; replay windows; secret rotation with two signatures; Standard Webhooks; SSRF and DNS rebinding; checking the dialled address; head-of-line blocking in an outbox |
| 7 | TLS and your own CA | TLS and mutual TLS; certificate authorities and name constraints; SPIFFE identities; checking identity, not host names; certificates reloaded without restarts; connections recycled; CA rotation in three phases |
| 8 | A sidecar proxy | Sidecars and service meshes; a layer-4 TLS proxy; half-close; native sidecars and shutdown order; the cost of a hop, measured; CPU limits and CFS throttling |
| 9 | Secrets | Secrets managers; workload identity and TokenReview; dynamic database logins and leases; least privilege in PostgreSQL (`INHERIT FALSE`); encryption as a service; sealing and unsealing; encryption at rest |
| 10 | A tamper-evident audit log | Why checksums and hash chains aren't enough; Merkle trees, inclusion and consistency proofs; signed checkpoints; witnesses; two implementations that check each other |
| 11 | Privacy | Data inventories with canaries; minimisation; redaction by name and by shape; retention for every copy; `SECURITY DEFINER` and `search_path`; k-thresholds, differencing, and differential privacy's noise |
| 12 | Cluster hardening | Default-deny NetworkPolicy and DNS; post-DNAT policy matching; Pod Security Standards; service-account tokens; fuzzing parsers, and what it misses |
| 13 | A security game day | Checking every row of the threat model on the running system; controls for the checks; a findings report; accepted risks; the OWASP API Top 10 |

## What you'll be able to do

- Write a threat model with evidence, and use it to order the work.
- Issue and verify tokens, rotate signing keys, and explain every check a verifier makes.
- Put authorization in one place, test it from the side of what it refuses, and keep tenants apart down to the database rows and the cache keys.
- Stop one tenant from starving the rest, and prove the limit is shared.
- Sign outgoing webhooks, defeat replays, and send requests to user-chosen addresses safely.
- Run a certificate authority, give every service an identity, and rotate certificates and the CA itself without an outage.
- Give mutual TLS to software you can't change, and measure what it costs.
- Replace stored passwords with short-lived, per-Pod logins, and encrypt data with keys the database never sees.
- Make an audit log whose rewriting is detectable by someone who doesn't trust its operator.
- Find where personal data goes, keep it out of telemetry, end its life, and publish statistics that don't give individuals away.
- Lock a namespace down, and fuzz the parsers that read hostile input.
- Run a security game day and write the findings report.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md), typing every piece of code yourself, starting from your Phase 5 code.
2. Do every "Run it" and every "Break it" on your own cluster. A control you've never seen fail is a control you're taking on trust. Your names, keys and timings will differ; the shapes shouldn't.
3. Answer [learned.md](learned.md).
4. Build the exercise project, **[flagpole](exercises.md)**, a multi-tenant feature-flag service, on your own, and secure it the same way. The exercise page shows exactly what finished looks like.
5. Take the [self-test](../../notes/learned/06-safe-shared-queries.md).

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where | Evidence |
|---|---|---|
| Authentication, authorization, multi-tenancy (row 28) | Steps 2–4 | Forged, expired and cross-audience tokens refused; every route checked; cross-tenant reads `404` in the API, the cache and the database |
| TLS, PKI, mTLS, secrets (row 29) | Steps 7–9 | A CA with name constraints; mTLS everywhere; renewals and a CA rotation under load with zero errors; per-Pod database logins |
| API security and rate limiting (row 30) | Steps 2–6, 12, 13 | The OWASP API Top 10 table; the noisy-neighbour experiment; SSRF refused at dial time; fuzzing findings |
| Testing and TDD (row 5) | Every step | Negative tests that failed when their control was removed; differential fuzzing of Go against Rust |
| Sockets, TCP/UDP, DNS (row 11) | Steps 7, 8, 12 | TLS handshakes; half-close; default-deny with DNS |
| SQL (row 15) | Steps 4, 9, 11 | Row-level security; least-privilege roles; a `SECURITY DEFINER` function made safe |
| Caching (row 18) | Steps 4, 5 | Tenant-scoped cache keys; a shared rate limiter in Redis |
| Incident response (row 27) | Step 13 | A security game day and its findings report |

## Patterns introduced

These link to the [patterns ledger](../../JOURNEY.md#6-patterns-ledger):
- policy decision and enforcement points;
- token-bucket rate limiting;
- tenant isolation and tenant context propagation;
- defence in depth and zero trust;
- sidecar;
- signed, replay-protected messages;
- dynamic secrets;
- transparency log (Merkle tree with a witness).

## Next

Runway is now something strangers could use and customers could share. Is it any good? [Phase 7](../07-utility-evaluation/README.md) measures it, and learns from its own data.
