# Tenancy and abuse control

> Shared unit · Time: 3 weeks at 12–15 hours a week · Builds on [Core 03 Docker and Postgres](../../../2-core/03-docker-and-postgres/README.md) and [Core 08 Shipping safely](../../../2-core/08-shipping-safely/README.md) · Used by all three tracks · Status: ready

Build a shared Switchyard jobs API for two tenant fixtures. Issue short-lived tokens and publish public keys, then verify tokens and enforce an explicit route policy. Bind tenant context to a PostgreSQL transaction and enforce it with row-level security. Start with an in-process token bucket and move its state to Redis so API instances share the same allowance.

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Issue a tenant access token](lessons/01-issue-a-tenant-access-token.md) | Bind a provisioned client to its tenant and role. Mint an Ed25519 JWT and expose public keys through JWKS. |
| 1 | 02 | [Verify the token at the API boundary](lessons/02-verify-the-token-at-the-api.md) | Pin the algorithm, issuer, audience, and trusted key set. |
| 1 | 03 | [Rotate signing keys with overlap](lessons/03-rotate-signing-keys-with-overlap.md) | Publish the next key before signing with it and keep the previous key until outstanding tokens expire. |
| 2 | 04 | [Scope PostgreSQL to the tenant](lessons/04-scope-postgresql-to-the-tenant.md) | Separate the runtime login from the table owner. Apply a row policy with transaction-local tenant context. |
| 2 | 05 | [Authorize routes and budget each tenant](lessons/05-authorize-routes-and-budget-each-tenant.md) | Separate reader and writer permissions. Give each tenant a local token bucket. |
| 3 | 06 | [Share a bucket across API instances](lessons/06-share-a-bucket-across-api-instances.md) | Make refill and debit atomic in Redis. Send a retry delay when capacity runs out. |
| 3 | 07 | [Wire and run the lab](lessons/07-wire-and-run-the-lab.md) | Use the issuer, verifier, policy, quota, and database through one loopback CLI. |
| 3 | 08 | [Verify the tenant and quota boundaries](lessons/08-verify-the-tenant-and-quota-boundaries.md) | Prove isolation on a reused connection and catch doubled allowance when each replica has a separate bucket. |

This unit reworks the token, authorization, tenant, and rate-limit steps from [Safe shared queries](README.md).

## The gate

The [gate](gate/README.md) checks token validation and rotation, the reader/writer permission matrix, transaction-local row visibility, and the distributed token bucket. Two API instances must admit only two of sixteen concurrent reads for one tenant while an unrelated tenant still succeeds. A paused Redis server must cause a bounded 503. The negative control uses independent local buckets and must report four admissions.

The CLI runs on loopback with generated fixture credentials and an in-memory signing key. The rotation test coordinates overlap and refresh explicitly. Redis loss makes protected routes temporarily unavailable in shared quota mode so the service keeps its admission cap.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Explain a token refusal, a role refusal, a hidden job row, and a quota refusal. |
| Intermediate | Scope a database transaction to one tenant and show that a pooled connection carries no tenant state into the next transaction. |
| Senior | Use evidence to defend the key-overlap window, the runtime role grants, and the availability trade-off of the shared quota. |

## Practice

- [Exercises](exercises.md). Build a shared workspace reservation API with scoped data and limits.
- [Self-check](self-check.md). Evaluate each decision point from memory.
- [Evidence](evidence/README.md). Inspect the live gate, negative control, and clean replay.

Continue with the [retention and aggregate privacy exercise](retention-and-aggregate-privacy.md) after the tenant and quota gate.
