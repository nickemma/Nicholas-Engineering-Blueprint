# Phase 6 exercise: flagpole, multi-tenant feature flags

Build this **on your own**, in a new repository, after the [checkpoint](TEACHING.md#checkpoint). It's a different service from Runway, so you can't copy the guide's code. But to build it and secure it well, you need every Phase 6 idea:
- a threat model first, with evidence, and a game day last;
- tokens, one policy decision point, and tenants kept apart down to the rows;
- per-tenant rate limits, shared across instances;
- signed, replay-protected webhooks to addresses tenants choose;
- mutual TLS between its services, from a CA of your own;
- secrets from OpenBao, and least-privilege database roles;
- a tamper-evident audit log with a witness;
- redaction, retention, and statistics that don't give tenants away;
- default-deny network policy, `restricted` Pods, and fuzzed parsers.

There's no solution in this repository. This page shows exactly what the finished system does.

## What you're building

**Feature flags** let a team turn a feature on for some users without a deploy: "new checkout, for 10% of users, and everyone at acme.example". Real products (LaunchDarkly, Unleash, Flagsmith) do this. `flagpole` does it for many organisations at once, and each organisation's flags, and its users, must be invisible to every other.

Two services:
- **`flagpole-admin`**: an HTTP API where an organisation's people create and change flags. Every change is recorded in an audit log, and pushed to the organisation's webhook.
- **`flagpole-eval`**: answers "is flag F on for this user?" for an organisation's applications, at high rate. It reads flags from PostgreSQL through a cache, and calls `flagpole-admin` only to fetch the issuer's keys and flag changes.

A flag:

~~~json
{"key": "new-checkout", "enabled": true,
 "rules": [{"attribute": "email", "endsWith": "@acme.example"}],
 "percentage": 10}
~~~

An evaluation request carries the user's attributes, which are personal data:

~~~bash
curl -s https://eval.flagpole.local/v1/evaluate -H "Authorization: Bearer $APP_TOKEN" \
  -d '{"flag":"new-checkout","user":{"id":"u-81","email":"dana@acme.example","country":"GB"}}'
~~~

~~~json
{"flag":"new-checkout","on":true,"reason":"rule 0 matched"}
~~~

## Requirements

**Model first.**
1. A threat model in `docs/security/threat-model.md`, written before any control: a data-flow diagram with trust boundaries, assets, actors, a STRIDE table with one command of evidence per threat, and non-goals. Every requirement below must point to a row.

**Identity and access.**
2. Tokens from an issuer (yours, or Dex), verified with every check from step 2. Roles: `viewer` (read flags), `editor` (change flags), `admin` (manage webhooks and members), and `app` (evaluate only). One decision point; a test that runs every route with a deny-all authorizer.
3. Organisations are tenants: from the token only; in every query, cache key and message; `404` for another organisation's flag; row-level security that a query with no `WHERE` can't get round, tested.
4. Per-organisation rate limits on evaluation (default 200 a second, burst 400), shared through Redis, failing open to local buckets, `429` with `Retry-After`. **And a limit per client address on requests with no valid token** (Runway's open T19).

**Between services.**
5. Mutual TLS between `flagpole-eval`, `flagpole-admin`, and the issuer, with SPIFFE-style identities, certificates that last a day, and renewal without restarts. Show a CA rotation under load with no errors.
6. Webhooks on every flag change: Standard Webhooks signatures, a replay window, rotation with two signatures, SSRF checks at dial time, and a delivery worker that can't hold back anything else.

**Secrets and data.**
7. Database logins from OpenBao, per Pod, rotating; no service is the tables' owner. Webhook secrets sealed with a transit key the database never sees; a different service seals and opens them.
8. The audit log of flag changes is a Merkle tree with signed checkpoints, and a witness that runs in a different namespace with its own key. `flagctl audit verify` says `OK` or `TAMPERED`.
9. Evaluation requests' user attributes never reach a log, a trace, or the database. Evaluation counts are kept per flag per hour, and deleted after 30 days.
10. `GET /v1/stats/flags`: across all organisations, how many flags use percentage rollouts, published per day, with a threshold of 5 organisations, a clamp, and noise. Show the differencing attack failing.

**The cluster.**
11. Default-deny network policy with DNS; each component reachable only by what uses it; `flagpole-eval` can't reach the internet. Every Pod `restricted`. No Kubernetes API token in any Pod that doesn't call the API.
12. A fuzz test for every parser of untrusted input: tokens, rule expressions, webhook headers, checkpoints.

**Operations.**
13. A game-day script that checks every row of your threat model, with controls, and a findings report with what's open and what's accepted.

## What finished looks like

Two organisations, a flag in each:

~~~bash
flagctl --org acme flag set new-checkout --enabled --rule 'email endsWith @acme.example' --percentage 10
flagctl --org globex flag set dark-mode --enabled
curl -s https://eval.flagpole.local/v1/evaluate -H "Authorization: Bearer $GLOBEX_APP" -d '{"flag":"new-checkout","user":{"id":"u-1"}}'
~~~

~~~json
{"error":"flag not found"}
~~~

Globex can't see acme's flag, even by its exact key. Now push a flag change and catch the webhook:

~~~text
POST /hooks HTTP/1.1
webhook-id: 01JC8...
webhook-timestamp: 1792...
webhook-signature: v1,K3x...
{"type":"flag.changed","flag":"new-checkout","by":"editor@acme","at":"2026-..."}
~~~

Replay it: `duplicate`. Change its body: `401`. Wait six minutes and replay: `401`, timestamp outside the tolerance. Point acme's webhook at `http://169.254.169.254/`: refused at registration; insert it straight into the database: refused when dialling, dead-lettered, and every other delivery unaffected.

Edit a record in the audit log, CRC and all:

~~~text
$ flagctl audit verify
checkpoint: 412 records, signed by the log and the witness
TAMPERED: the log's first 412 records have a different root: history was changed
~~~

From a Pod in another namespace, every port but the front door is closed; from inside `flagpole-eval`, so is the internet. A Pod that asks to run as root is refused. The game day prints something like:

~~~text
T1   evaluate with no token                                   want 401  got 401  HELD
T2   globex reads acme's flag by key                          want 404  got 404  HELD
     control: a Pod in another namespace reaches the front    want open got open SEES
T6   a Pod in another namespace reaches PostgreSQL            want closed got closed HELD
...
~~~

## How it will be checked

Your repository's CI runs the tests (with the race detector), the fuzz targets for a minute each, `helm lint`, and a kind smoke test. Then a reviewer (or you, honestly) reads the threat model, runs the game day on a fresh kind cluster from your README, and tries three attacks of their own choosing from your STRIDE table. Every "Break it" in your README must show the failing test or the refused request, not just the passing one.

## Stretch goals

- **Sender-constrained tokens** (RFC 8705): bind each `app` token to its client certificate, so a stolen token is useless without the key.
- **Per-service broker logins** from OpenBao's RabbitMQ engine (Runway's open T8), if you use a broker.
- **Certificate expiry metrics and an alert** a few hours ahead (Runway's open T20), and renewal by a CronJob or cert-manager.
- **Crypto-shredding**: encrypt each organisation's audit records under its own key, and delete the key when the organisation leaves. What happens to the Merkle tree?
- **A second witness**, run by someone else, and checkpoints that need both signatures.
