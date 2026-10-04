# Phase 6: Enforce safe cross-site queries

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: full code in `steps/`, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This self-study lesson adds a narrow, policy-checked query for synthetic records assigned to two site IDs. Its local practice harness uses one PostgreSQL instance with site-scoped rows so the policy and audit behavior can be tested on one computer; the Kestrel transfer preserves separate site custody. It begins by stating who can ask what, then implements trusted identity context, authorization, minimal disclosure, and auditable decisions. It does not use clinical records.

## The goal

For each request, the system should identify the caller, check the caller's purpose and explicit grant for the requested target site, return only approved fields, reject an unavailable or invalid policy check, and record an audit event. The test analyst belongs to site-a and has a written partner grant for site-b; site-c is outside that grant. This makes both an allowed cross-site query and a denied unapproved-site query visible. You will test repeated-query leakage rather than assuming that an aggregate is automatically safe.

The executable exercise uses one disposable PostgreSQL instance with synthetic `site_id` values so the policy, query, and audit path can be tested locally. That tests site scoping in the application; it does not prove separate organizations control separate database servers. The Phase 6 Kestrel transfer must preserve the site boundary in its own deployment/data-flow design and state this limitation in its evidence.

## Before you start

Finish Phases 0–5. You should have two site services, a request/worker path, durable local records, replicated metadata, and enough operational signals to diagnose a denied request. Create a synthetic dataset with invented records and document its fields.

Work from `lessons/06-safe-shared-queries`. Create a separate practice folder. The API uses Go's standard library for HTTP and policy checks, pgx for the local synthetic database, and test fixtures instead of a live identity provider:

~~~bash
mkdir -p practice
cd practice
go mod init kestrel-phase6
go get github.com/jackc/pgx/v5
go mod tidy
~~~

Start the same disposable PostgreSQL database used in Phase 3, and set the connection string in this Phase 6 practice shell:

~~~bash
export DATABASE_URL='postgres://kestrel:lesson-only@127.0.0.1:55432/kestrel?sslmode=disable'
docker compose -f ../../03-durable-auditable-data/practice/compose.yaml up -d --wait db
export PATH="$(go env GOPATH)/bin:$PATH"
goose -version
~~~

Run the Phase 6 migration with `goose -dir migrations postgres "$DATABASE_URL" up` from the Phase 6 practice folder. The trusted identity in unit tests is injected by a test fixture. Later, the same claims structure can be populated by a maintained OIDC verifier. Never make a client-supplied JSON field a trusted claim.

Implement one site API with this file layout:

~~~text
go.mod
cmd/siteapi/main.go
migrations/<generated-version>_query_policy_tables.sql
internal/identity/claims.go       verified test identity
internal/policy/decision.go      pure allow/deny function
internal/query/request.go        request validation
internal/query/summary.go        local aggregate
internal/query/postgres.go       parameterized local aggregate
internal/query/nonce_store.go    atomic one-use nonce
internal/audit/event.go          append-only decision event
internal/audit/postgres.go       append-only insert
internal/httpapi/query.go        HTTP handler
internal/httpapi/health.go       GET /health for the local mTLS check
internal/httpapi/query_test.go   policy and handler tests
~~~

Create the timestamped migration file with these commands:

~~~bash
mkdir -p migrations
goose -dir migrations create query_policy_tables sql
~~~

Open the generated file and replace its contents with:

~~~sql
-- +goose Up
CREATE TABLE synthetic_records (
    record_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_id TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('capacity', 'access')),
    occurred_at DATE NOT NULL
);

CREATE INDEX synthetic_records_site_date_idx
    ON synthetic_records (site_id, occurred_at);

CREATE TABLE consumed_nonces (
    subject TEXT NOT NULL,
    nonce_hash BYTEA NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (subject, nonce_hash)
);

CREATE TABLE query_audit (
    audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id TEXT NOT NULL UNIQUE,
    verified_subject TEXT NOT NULL,
    service_id TEXT NOT NULL,
    target_site TEXT NOT NULL,
    purpose TEXT NOT NULL,
    query_type TEXT NOT NULL,
    policy_version TEXT NOT NULL,
    decision TEXT NOT NULL CHECK (decision IN ('allow', 'deny')),
    reason_code TEXT NOT NULL,
    event_time TIMESTAMPTZ NOT NULL,
    aggregate_released BOOLEAN NOT NULL
);

INSERT INTO synthetic_records (site_id, category, occurred_at)
SELECT 'site-a', 'capacity', DATE '2026-01-15' FROM generate_series(1, 12);
INSERT INTO synthetic_records (site_id, category, occurred_at)
SELECT 'site-a', 'access', DATE '2026-01-15' FROM generate_series(1, 9);
INSERT INTO synthetic_records (site_id, category, occurred_at)
SELECT 'site-b', 'capacity', DATE '2026-01-15' FROM generate_series(1, 20);
INSERT INTO synthetic_records (site_id, category, occurred_at)
SELECT 'site-b', 'access', DATE '2026-01-15' FROM generate_series(1, 14);

-- +goose Down
DROP TABLE query_audit;
DROP TABLE consumed_nonces;
DROP TABLE synthetic_records;
~~~

Apply it from the Phase 6 practice folder with `goose -dir migrations postgres "$DATABASE_URL" up`. It adds only synthetic records to the disposable Phase 3 database. The application appends audit rows with `INSERT`; this demonstrates the append-only application pattern, not tamper-proof storage. The database owner can still alter the table, so do not claim cryptographic tamper evidence.

Use this synthetic record model in the repository: `record_id` is a synthetic integer key, `site_id` is a string, `category` is one of `capacity` or `access`, and `occurred_at` is a UTC date. Create test data with 12 `capacity` rows and 9 `access` rows for the selected interval at site-a. This makes the threshold behavior visible: one category is returned and one is suppressed. Add equivalent site-b records with different counts. Never use real or re-identifiable data.

In `internal/query/request.go`, define `QueryRequest` and factor bounded JSON decoding into `decodeQueryJSON([]byte) (QueryRequest, error)`. It must reject input larger than 1 KiB, unknown fields, malformed JSON, and a second trailing JSON value. The HTTP handler calls this helper after reading a body capped at 1 KiB; the helper is also the target for Phase 8's Go fuzz test.

For the guided lesson, the identity verifier is a test fixture that creates trusted claims directly. The handler must never treat requester_id from the JSON body as verified identity. The end-to-end TLS check below calls `/health`; query authorization is tested with handler tests that inject those trusted claims. Integrating an OIDC provider is a follow-up; it will use the same trusted-claims interface after token verification.

## 1. Draw the data and trust boundaries

Use these actors: requester, site operator, data steward, site API, local database, policy service, and audit store. A trust boundary is a place where data or control passes to a component that must not automatically be trusted.

Draw which actor can see each of: raw local record, query text, approved aggregate, identity claims, policy result, and audit entry. Mark where information crosses the network. If a component receives more information than it needs, change the design before coding.

## 2. Define one query contract

Use one exact query for the exercise: count synthetic records by a broad category for one named time window. Identity comes from verified claims and is deliberately not accepted in the JSON body. The request contains:

~~~text
request_id: unique random identifier
site_id: target site
purpose: one value from the approved purpose list
query_type: count_by_category
window_start: UTC date, inclusive
window_end: UTC date, exclusive
expires_at: short deadline
nonce: one-use random value
~~~

Example request:

~~~json
{"request_id":"req-7f1","site_id":"site-a","purpose":"service-planning","query_type":"count_by_category","window_start":"2026-01-01","window_end":"2026-02-01","expires_at":"2026-01-01T12:01:00Z","nonce":"one-use-random-value"}
~~~

For this example, inject a fixed clock in tests set to `2026-01-01T12:00:00Z`; for a live request, set expiry to one minute after the current UTC time and generate a fresh nonce.

The response contains only the site ID, requested window, category, and count. It never returns a source record or a row-level identifier. For the example request, return `capacity: 12` and omit `access: 9`:

~~~json
{"site_id":"site-a","window_start":"2026-01-01","window_end":"2026-02-01","counts":[{"category":"capacity","count":12}]}
~~~

Suppression reduces some disclosure risk but is not a complete privacy guarantee.

The HTTP endpoint is `POST /v1/sites/{site_id}/summary`. Follow this exact order: verify caller claims; decode one bounded JSON request; compare the path site with the requested site; validate the date range and expiry; atomically consume the nonce for this verified subject; load the policy; call the pure policy function; run the aggregate query only after allow; suppress groups below 10; append the audit event; return the allowed response only if the audit write succeeds. A denial must not execute the aggregate query. If the audit store is unavailable, return 503 and release no aggregate.

## 3. Write a small threat model

For each asset, list who could misuse it, the boundary they could cross, and the control you will test. Include a curious authorized user, stolen credentials, a compromised site API, repeated overlapping queries, an unavailable policy service, and a malicious request with an invalid site or purpose.

Write non-goals too: this lab does not prove legal compliance, prevent every inference, or defend a compromised operating system. Use the OWASP API Security Top 10 as a list of test prompts, not as a security certificate.

## 4. Separate authentication from authorization

Authentication asks “which identity presented this request?” Authorization asks “may that identity perform this action on this resource for this purpose?” A site identity identifies a service; a user identity identifies a person. TLS protects a connection in transit; mTLS also authenticates both endpoints using certificates. Neither decision replaces query authorization.

For unit tests, create explicit test identities as fixtures. Do not accept a requester_id supplied only in the JSON body as proof of identity. For this lesson's local integration exercise, add a test-only claims middleware to the query route. It is disabled unless `KESTREL_ENABLE_TEST_IDENTITY=1`, requires the verified mTLS client certificate mapped to service `site-a`, and injects the fixed synthetic analyst with grants for `site-a` and partner `site-b`. The request body never supplies the analyst identity. Keep the server bound to loopback or the disposable Phase 7 veth address; never enable this fixture on a public or production listener. Do not add a live OIDC dependency to the core path. As a separate follow-up, an OIDC integration must validate issuer, audience, expiry, and signature with a maintained library; never write JWT cryptography yourself.

Give `Claims` a private-key context helper in `internal/identity/claims.go`: `WithClaims(ctx, claims)` stores the claims under an unexported key, and `FromContext(ctx)` retrieves them. The local middleware should follow this exact decision order:

~~~go
func localTestClaims(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if os.Getenv("KESTREL_ENABLE_TEST_IDENTITY") != "1" {
			http.Error(w, "identity required", http.StatusUnauthorized)
			return
		}
		if r.TLS == nil || len(r.TLS.PeerCertificates) == 0 || r.TLS.PeerCertificates[0].Subject.CommonName != "site-a" {
			http.Error(w, "identity required", http.StatusUnauthorized)
			return
		}
		claims := identity.Claims{
			Subject:      "test-analyst",
			HomeSite:     "site-a",
			AllowedSites: map[string]struct{}{"site-a": {}, "site-b": {}},
		}
		next.ServeHTTP(w, r.WithContext(identity.WithClaims(r.Context(), claims)))
	})
}
~~~

Import `net/http`, `os`, and the local identity package where needed. Register this wrapper only on the query route. Tests still inject claims directly and must also prove that `site-c` is denied.

For site-to-site transport, configure mTLS with a local test CA and short-lived test certificates. This checks service identity in the transport; it does not authorize the query. Work from the Phase 6 practice folder and make a local certificate directory:

~~~bash
mkdir -p certs
cd certs
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout ca.key -out ca.crt -nodes -days 2 -subj "/CN=Kestrel Phase 6 Test CA" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout server.key -out server.csr -nodes -subj "/CN=localhost"
printf '%s\n' 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:10.203.0.1' 'extendedKeyUsage=serverAuth' 'keyUsage=digitalSignature' > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 2 -extfile server.ext
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout client.key -out client.csr -nodes -subj "/CN=site-a"
printf '%s\n' 'extendedKeyUsage=clientAuth' 'keyUsage=digitalSignature' > client.ext
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAserial ca.srl -out client.crt -days 2 -extfile client.ext
chmod 600 *.key
cd ..
~~~

The CA signs one server certificate and one client certificate. `-days 2` makes the test certificates expire quickly. The final `cd ..` returns to the practice root. Add `/certs/` to the practice `.gitignore`; never commit the CA private key, client private key, or generated certificates.

In `cmd/siteapi/main.go`, register `GET /health` with the `health.go` handler and `POST /v1/sites/{site_id}/summary` with the query handler on a `http.NewServeMux`. Wrap only the query handler with the test-only claims middleware described above. Construct `http.Server{Addr: listenAddress, Handler: mux, TLSConfig: ...}`. Set `listenAddress` from `LISTEN_ADDR`, defaulting to `127.0.0.1:8443`; Phase 7 changes it to the isolated host-veth address during its experiment. Load `ca.crt` with `x509.NewCertPool()` and set TLSConfig to `&tls.Config{MinVersion: tls.VersionTLS13, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: clientCAs}`. Start it with `server.ListenAndServeTLS("certs/server.crt", "certs/server.key")`. Check that loading the CA succeeded before starting. In the handler, read `r.TLS.PeerCertificates[0].Subject.CommonName` only after checking that `r.TLS` and the certificate list are present. Map the test CA's `site-a` certificate to a test service identity; do not treat an arbitrary Common Name as a production identity. The fixed test claims are attached by the local middleware only after this certificate check and only when the environment flag is enabled.

From the Phase 6 practice root, call the service:

~~~bash
curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key https://localhost:8443/health
~~~

Expect the health response. Repeat without `--cert` and `--key`; TLS should reject the connection before the request handler runs. In learned.md, explain why a successful TLS handshake still does not prove that the caller may query the selected site. The [Go crypto/tls documentation](https://pkg.go.dev/crypto/tls) describes the server fields used here.

## 5. Implement the local authorization decision

Create a written policy table before code:

| Caller role | Site scope | Purpose | Query | Minimum group | Result |
|---|---|---|---|---|---|
| analyst from site-a | site-a or explicitly granted partner site-b | approved service planning | count by broad category | 10 | allow |
| analyst from site-a | unapproved site-c | approved service planning | count by broad category | 10 | deny |
| any caller | any site | unlisted purpose | any | any | deny |
| any caller | any site | approved purpose | row-level records | any | deny |

Implement the policy as a pure function that receives verified identity claims, their explicit set of permitted target sites, and a validated query, then returns allow or a reasoned denial. In the test fixture, site-a's analyst is granted `site-a` and partner `site-b`, but not `site-c`. Check expiry and consume the nonce in the handler before calling this pure function; those checks use the current clock and replay store and therefore are not part of a pure policy decision. Load the policy through a `PolicyProvider`; if it returns an error or no current version, fail closed. Keep the policy decision separate from the SQL query so it can be tested without a database.

Use the signature `Decide(claims, request, policy) Decision`, where claims contain the verified subject, home site, and permitted target-site set, and `Decision` contains `Allowed`, `ReasonCode`, and `PolicyVersion`. The pure function returns `allowed`, `wrong_site`, `wrong_purpose`, or `query_not_allowed`. The handler/audit layer also uses reason categories `expired`, `replayed`, `identity_missing`, `policy_unavailable`, `cohort_suppressed`, and `audit_unavailable`. Map missing/invalid authentication to 401, malformed input to 400, an authenticated policy denial to 403, and unavailable policy/audit dependencies to 503. Do not return internal stack traces.

Use a parameterized aggregate query equivalent to `SELECT category, COUNT(*) FROM synthetic_records WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3 GROUP BY category`. The path/request site comparison and policy check happen before this query. Your repository test fake should count calls so tests can prove denied requests never query data.

For the nonce store, compute `sha256.Sum256([]byte(nonce))` and run `INSERT INTO consumed_nonces (subject, nonce_hash, expires_at) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING RETURNING subject`. One returned row means the nonce was new; no row means it has already been used. Treat a database error as unavailable and fail closed. Expired rows may be deleted during cleanup because their expiry has passed.

When allowed, query the local database, apply the minimum-group rule, and return only the aggregate fields. When denied, return a consistent error and write an audit entry. Do not expose detailed internal policy rules to an untrusted caller.

OPA/Rego is an optional comparison exercise: translate one policy-table row into a policy-as-code rule, feed it the same JSON input, and compare decisions. Keep only one enforcement path in the running service.

## 6. Audit decisions and test abuse

Each audit event should record request ID, verified subject/service, target site, purpose, query type, policy version, allow/deny, reason category, time, and whether an aggregate was released. Do not copy raw rows or bearer tokens into the audit log. Restrict who can read it and document its retention.

Implement `PostgresAuditStore.Append(event)` as one parameterized `INSERT INTO query_audit (...) VALUES (...)`. Do not use `UPDATE` or `UPSERT` for an existing request ID. If the insert fails, return 503 and do not release the aggregate. The `query_audit` table documents an append-only application pattern; the local database owner can still edit it, so this test does not establish tamper-proof audit storage.

Test all cases in the policy table. `TestAllowedSummary` should cover site-a; add `TestApprovedPartnerSiteAllowed` for site-b and make `TestWrongSiteDenied` target unapproved site-c. Add tests for expired requests, repeated nonces, path/body site mismatch, missing identity claims, policy timeout, a cohort just below threshold, and repeated overlapping queries. For every request, confirm both response and audit outcome.

Name the tests TestAllowedSummary, TestApprovedPartnerSiteAllowed, TestWrongSiteDenied, TestWrongPurposeDenied, TestMissingIdentityDenied, TestExpiredRequestDenied, TestNonceReplayDenied, TestPolicyUnavailableFailsClosed, TestSmallCohortSuppressed, TestDeniedRequestDoesNotQueryDatabase, and TestAuditWriteFailureReturnsNoData. Use a fake repository with a call counter for the denied-query test; expect zero aggregate-query calls after denial. For the audit-failure test, expect HTTP 503 and no response fields containing category counts.

In `internal/query/request_test.go`, add this native Go fuzz target so Phase 8 can revisit the same parser:

~~~go
package query

import "testing"

func FuzzDecodeQueryJSON(f *testing.F) {
	f.Add([]byte(`{"request_id":"r1","site_id":"site-a","purpose":"service-planning","query_type":"count_by_category","window_start":"2026-01-01","window_end":"2026-02-01","expires_at":"2026-01-01T12:01:00Z","nonce":"n1"}`))
	f.Add([]byte(`{"`))
	f.Fuzz(func(t *testing.T, body []byte) {
		if len(body) > 1024 {
			t.Skip()
		}
		_, _ = decodeQueryJSON(body)
	})
}
~~~

This checks that arbitrary bounded bytes return an error or a request without panicking. Keep table tests for oversize input, unknown fields, and trailing JSON, because this fuzzer skips inputs over 1 KiB. Run `go test ./...` after adding the target.

Study differencing: if one query asks for a group and another asks for the same group minus one person, their answers can reveal a difference even when each answer is an aggregate. Use synthetic numbers to construct such a pair. Add query limits or a privacy budget only after explaining which inference risk it addresses and the usability cost it creates.

## 7. Decide whether advanced privacy is justified

Differential privacy adds calibrated randomness and composes privacy loss across queries. Secure multi-party computation lets parties jointly compute without simply exchanging raw inputs, but adds protocol, availability, and operating complexity. Do not implement either as a badge. State the adversary, utility target, privacy parameter or protocol assumptions, and baseline first. For this project, a documented “not justified by current workload” decision is valid.

## Evidence gate

From the Phase 6 practice folder, run `go test ./...`; all policy, validation, audit, and handler tests should pass. Start the local TLS server with `go run ./cmd/siteapi`, then verify the mutual TLS health check from a second terminal with the curl command in Step 4. Stop the server with Ctrl+C when it returns.

Save the data-flow diagram, threat model, policy table, allowed/denied test outputs, sample audit events with synthetic identities, and the differencing example. Confirm persisted events in PostgreSQL with `docker compose -f ../../03-durable-auditable-data/practice/compose.yaml exec db psql -U kestrel -d kestrel -c 'SELECT request_id, decision, reason_code, aggregate_released FROM query_audit ORDER BY audit_id;'`. Keep the Phase 3 database volume because it contains earlier practice evidence; do not run `down -v` for this shared local database. Complete learned.md. Close the lesson implementation and rebuild the authorization path in Kestrel from the policy table and threat model. Do not copy enforcement code. Check that a missing identity or policy result returns no data.

## Read beside the build

Read each item after defining the matching design element. The privacy-paper choice is recorded in your threat model so the paper answers a real question from this exercise.

| When | Read | Carry this question into the reading |
|---|---|---|
| After drawing trust boundaries | Anderson, *Security Engineering*, 3rd ed., sections on security goals, access control, and distributed systems | Which actor can cross which boundary, and what evidence would reveal misuse? |
| Before writing abuse tests | [OWASP API Security Top 10, 2023](https://api-security.owasp.org/editions/2023/en/0x00-header/), especially object-level authorization and authentication risks | Can changing an object or site ID expose data the caller cannot access? |
| Before implementing identity verification | [OpenID Connect Core](https://openid.net/specs/openid-connect-core-1_0.html), Authentication and ID Token validation sections | Which issuer, audience, signature, and expiry make these claims trustworthy? |
| Before configuring site-to-site transport | Kurose & Ross, 8th ed., Chapter 8 sections on endpoint authentication and TLS; Anderson, sections on protocols | Who is authenticated by TLS, and which authorization decision remains separate? |
| After the repeated-query exercise | Dwork and Roth, *The Algorithmic Foundations of Differential Privacy*, Chapters 1–2 (optional) | What privacy loss can compose across queries, and what utility does randomization change? |
| Before the final control review | Selected OWASP ASVS verification requirements that match your assets and threat model | Which claim is tested, and which control remains unverified? |

For secure multiparty computation, choose a primary paper only if your written threat model requires it; otherwise document why it is outside this lesson. Do not treat one paper or checklist as a security certification.
