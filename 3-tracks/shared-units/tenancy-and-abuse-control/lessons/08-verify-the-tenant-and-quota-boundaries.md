# 08 Verify the tenant and quota boundaries

> Tenancy and abuse control · Week 3

## The problem

A passing request for your own tenant says little about who else can see it or how much capacity a replica can admit. Use separate fixtures and check the database role directly.

## The mental model

~~~text
credential and rotation tests → verified principal
HTTP fixture matrix           → route scopes and tenant scopes
reused database connection    → transaction-local RLS
two simultaneous API instances → one tenant bucket
~~~

## Build it

### Check the complete request path

Exercise the two protected routes and RLS using seeded tenants. Pause Redis and check that the quota step returns 503. Configure two independently budgeted test instances as the quota negative control.

Create `internal/api/live_test.go`.

<!-- file: internal/api/live_test.go -->
~~~go
package api

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"switchyard/tenantlab/internal/identity"
	"switchyard/tenantlab/internal/jobs"
	"switchyard/tenantlab/internal/quota"
)

type response struct {
	status int
	retry  string
	body   string
	err    error
}

func call(client *http.Client, method, endpoint, token, body string) response {
	request, err := http.NewRequest(method, endpoint, strings.NewReader(body))
	if err != nil {
		return response{err: err}
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	reply, err := client.Do(request)
	if err != nil {
		return response{err: err}
	}
	defer reply.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(reply.Body, 4096))
	return response{status: reply.StatusCode, retry: reply.Header.Get("Retry-After"), body: string(raw), err: err}
}

func TestLive(t *testing.T) {
	if os.Getenv("TENANT_TEST_LIVE") != "1" {
		t.Skip("the live gate provides a database and Redis")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()
	config, err := pgxpool.ParseConfig(os.Getenv("TENANT_DB_URL"))
	if err != nil {
		t.Fatal(err)
	}
	config.MaxConns = 1
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	store := jobs.Store{Pool: pool}

	signer := identity.NewIssuer("trainer", "jobs")
	if err := signer.Stage("current"); err != nil {
		t.Fatal(err)
	}
	if err := signer.Activate("current"); err != nil {
		t.Fatal(err)
	}
	keys, err := signer.JWKS()
	if err != nil {
		t.Fatal(err)
	}
	issue := func(p identity.Principal) string {
		t.Helper()
		token, err := signer.Issue(p, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		return token
	}
	acme := issue(identity.Principal{Subject: "acme-view", Tenant: "acme", Role: "reader"})
	blue := issue(identity.Principal{Subject: "blue-view", Tenant: "blue", Role: "reader"})
	writer := issue(identity.Principal{Subject: "acme-write", Tenant: "acme", Role: "writer"})
	client := &http.Client{Timeout: 4 * time.Second}
	defer client.CloseIdleConnections()
	start := func(t *testing.T, limiter quota.Limiter) string {
		t.Helper()
		verifier := identity.NewVerifier("trainer", "jobs")
		if err := verifier.ReplaceJWKS(keys); err != nil {
			t.Fatal(err)
		}
		server := httptest.NewServer(Server{Verify: verifier, Store: store, Quota: limiter, Now: time.Now}.Routes())
		t.Cleanup(server.Close)
		return server.URL
	}

	t.Run("policy_and_tenant_rows", func(t *testing.T) {
		endpoint := start(t, quota.NewLocal([]string{"acme", "blue"}, 20, time.Minute, time.Now))
		check := func(method, path, token, body string, expected int, want string) {
			t.Helper()
			got := call(client, method, endpoint+path, token, body)
			if got.err != nil || got.status != expected || !strings.Contains(got.body, want) {
				t.Fatalf("%s %s: %+v; want %d %q", method, path, got, expected, want)
			}
		}
		check("GET", "/jobs/shared", "", "", 401, "")
		check("POST", "/jobs", acme, `{"id":"created","name":"writer only"}`, 403, "")
		check("GET", "/jobs/shared", acme, "", 200, "Acme fixture")
		check("GET", "/jobs/shared", blue, "", 200, "Blue fixture")
		check("GET", "/jobs/blue-only", acme, "", 404, "job not found")
		check("GET", "/jobs/absent", acme, "", 404, "job not found")
		check("POST", "/jobs", writer, `{"id":"created","name":"valid","tenant":"blue"}`, 400, "")
		check("POST", "/jobs", writer, `{"id":"created","name":"Acme created"}`, 201, "")
		check("GET", "/jobs/created", writer, "", 200, "Acme created")
		check("GET", "/jobs/created", blue, "", 404, "")
		t.Log("HTTP policy: authentication and role boundaries held; the job ID resolved inside its tenant")
	})

	t.Run("database_policy", func(t *testing.T) {
		var restricted bool
		err := pool.QueryRow(ctx, `SELECT current_user = 'tenant_api'
AND NOT rolsuper AND NOT rolbypassrls
AND pg_get_userbyid(relowner) <> current_user AND relforcerowsecurity
FROM pg_roles CROSS JOIN pg_class
WHERE rolname = current_user AND pg_class.oid = 'tenant_lab.jobs'::regclass`).Scan(&restricted)
		if err != nil || !restricted {
			t.Fatalf("database role is not covered by forced RLS: %t %v", restricted, err)
		}
		checkRows := func(tenant string, limit int) {
			t.Helper()
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(ctx)
			if tenant != "" {
				if _, err := tx.Exec(ctx, "SELECT set_config('switchyard.tenant', $1, true)", tenant); err != nil {
					t.Fatal(err)
				}
			}
			var matches int
			if err := tx.QueryRow(ctx, "SELECT count(*) FROM tenant_lab.jobs WHERE id = 'shared'").Scan(&matches); err != nil || matches != limit {
				t.Fatalf("tenant %q saw %d rows, want %d: %v", tenant, matches, limit, err)
			}
			if err := tx.Commit(ctx); err != nil {
				t.Fatal(err)
			}
		}
		checkRows("acme", 1)
		checkRows("", 0)
		checkRows("blue", 1)
		checkRows("", 0)
		_, err = pool.Exec(ctx, "INSERT INTO tenant_lab.jobs (tenant, id, name) VALUES ('acme', 'unscoped', 'fixture')")
		var failure *pgconn.PgError
		if !errors.As(err, &failure) || failure.Code != "42501" {
			t.Fatalf("unscoped insert did not fail with a policy refusal: %v", err)
		}
		t.Log("database policy: reused connection saw one scoped row; missing context exposed zero rows and refused the insert")
	})

	t.Run("shared_quota", func(t *testing.T) {
		redisURL := os.Getenv("TENANT_REDIS_URL")
		limiter := func() quota.Limiter {
			if os.Getenv("TENANT_TEST_PER_REPLICA") == "1" {
				return quota.NewLocal([]string{"acme", "blue"}, 2, time.Minute, time.Now)
			}
			redisClient, err := quota.OpenRedis(redisURL)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { redisClient.Close() })
			return quota.Shared{Client: redisClient, Prefix: "gate:quota:", Burst: 2, Interval: time.Minute}
		}
		endpoints := []string{start(t, limiter()), start(t, limiter())}
		results := make(chan response, 16)
		for n := range 16 {
			go func() { results <- call(client, "GET", endpoints[n%2]+"/jobs/shared", acme, "") }()
		}
		accepted, limited := 0, 0
		for range 16 {
			got := <-results
			switch {
			case got.err == nil && got.status == 200:
				accepted++
			case got.err == nil && got.status == 429:
				delay, err := strconv.Atoi(got.retry)
				if err != nil || delay < 1 {
					t.Fatalf("bad Retry-After: %q", got.retry)
				}
				limited++
			default:
				t.Fatalf("unexpected quota response: %+v", got)
			}
		}
		if accepted != 2 || limited != 14 {
			t.Fatalf("shared quota: accepted=%d, want 2; limited=%d, want 14", accepted, limited)
		}
		if got := call(client, "GET", endpoints[1]+"/jobs/shared", blue, ""); got.err != nil || got.status != 200 {
			t.Fatalf("quiet tenant: %+v", got)
		}
		t.Log("shared quota: two API instances accepted 2 hot-tenant reads total; 14 returned 429 with Retry-After; quiet tenant succeeded")
	})

	t.Run("quota_unavailable", func(t *testing.T) {
		redisClient, err := quota.OpenRedis(os.Getenv("TENANT_REDIS_URL"))
		if err != nil {
			t.Fatal(err)
		}
		defer redisClient.Close()
		if err := redisClient.Do(ctx, "CLIENT", "PAUSE", 1600, "ALL").Err(); err != nil {
			t.Fatal(err)
		}
		endpoint := start(t, quota.Shared{Client: redisClient, Prefix: "gate:outage:", Burst: 2, Interval: time.Minute})
		at := time.Now()
		got := call(client, "GET", endpoint+"/jobs/shared", blue, "")
		if got.err != nil || got.status != 503 || time.Since(at) >= time.Second {
			t.Fatalf("quota failure: %+v in %s", got, time.Since(at))
		}
		t.Logf("unavailable quota failed closed with 503 in %s", time.Since(at).Round(time.Millisecond))
	})
}
~~~

## Check it

~~~bash
SWITCHYARD_TENANCY_LIVE=1 bash "$blueprint/3-tracks/shared-units/tenancy-and-abuse-control/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/shared-units/tenancy-and-abuse-control/gate/run.sh" "$PWD" -->

The [gate guide](../gate/README.md) explains each check. The [reference evidence](../evidence/README.md) includes the quota negative control.

The reference saw one scoped row on a reused PostgreSQL connection, then zero rows and a refused insert without tenant context. Across both API instances, Redis admitted two of the busy tenant's sixteen requests. With one local bucket per instance, the same test counted four admissions.

## If it goes wrong

| Symptom | Check |
|---|---|
| A newly signed token is refused immediately | Load the staged public key snapshot before activating it. Check issuer, audience, expiry, and key ID. |
| A scoped query returns zero rows | Inspect the runtime role, transaction boundaries, and tenant setting. |
| Two instances accept four requests with a two-token burst | Verify both use the shared Redis bucket and the same namespace for the tenant. |
| A paused Redis server returns 503 | Check the limiter warning and confirm its deadline before investigating PostgreSQL. |
