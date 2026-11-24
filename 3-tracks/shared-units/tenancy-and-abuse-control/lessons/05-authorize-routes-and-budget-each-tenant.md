# 05 Authorize routes and budget each tenant

> Tenancy and abuse control · Week 2

## The problem

A valid reader token does not grant permission to write. An authorized client can still consume capacity faster than the shared system can serve it.

## The mental model

~~~text
Bearer token → authenticate → authorize route → take tenant quota → touch store
               401            403               429 or 503          row or 404
~~~

## The pattern

Map each route to an explicit operation. A reader may read and a writer may read or create. Use the verified tenant for both the database context and the token bucket. A token bucket starts with a burst allowance, spends one token per request, then refills at a steady rate. Return 429 with a positive Retry-After when the bucket is empty. [Go rate limiter](https://pkg.go.dev/golang.org/x/time/rate)

## Build it

### Give each configured tenant a bucket

Keep the local tenant population fixed by provisioning and use a controllable clock.

Create `internal/quota/local.go`.

<!-- file: internal/quota/local.go -->
~~~go
package quota

import (
	"context"
	"errors"
	"time"

	"golang.org/x/time/rate"
)

type Decision struct {
	Allowed bool
	Retry   time.Duration
}

type Limiter interface {
	Take(context.Context, string) (Decision, error)
}

type Local struct {
	buckets  map[string]*rate.Limiter
	interval time.Duration
	now      func() time.Time
}

func NewLocal(tenants []string, burst int, interval time.Duration, now func() time.Time) *Local {
	buckets := make(map[string]*rate.Limiter, len(tenants))
	for _, tenant := range tenants {
		buckets[tenant] = rate.NewLimiter(rate.Every(interval), burst)
	}
	return &Local{buckets: buckets, interval: interval, now: now}
}

func (l *Local) Take(_ context.Context, tenant string) (Decision, error) {
	bucket, known := l.buckets[tenant]
	if !known {
		return Decision{}, errors.New("tenant quota missing")
	}
	now := l.now()
	if bucket.AllowN(now, 1) {
		return Decision{Allowed: true}, nil
	}
	delay := time.Duration((1 - bucket.TokensAt(now)) * float64(l.interval))
	return Decision{Retry: delay}, nil
}
~~~

### Check refill and separate budgets

Exhaust one tenant and advance one refill interval. Verify the other tenant can still spend its own token.

Create `internal/quota/local_test.go`.

<!-- file: internal/quota/local_test.go -->
~~~go
package quota

import (
	"testing"
	"time"
)

func TestLocalBucketRefills(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	local := NewLocal([]string{"acme", "blue"}, 2, time.Second, func() time.Time { return now })
	want := func(tenant string, allowed bool) {
		t.Helper()
		got, err := local.Take(t.Context(), tenant)
		if err != nil || got.Allowed != allowed || (!allowed && got.Retry <= 0) {
			t.Fatalf("quota = %+v, %v", got, err)
		}
	}
	want("acme", true)
	want("acme", true)
	want("acme", false)
	want("blue", true)
	now = now.Add(time.Second)
	want("acme", true)
	want("acme", false)
	t.Log("the noisy tenant exhausted its bucket; a different tenant kept its budget")
}
~~~

### Enforce the policy before database work

Keep request bodies bounded and take tenant identity from the verified token. Return the same missing-row response for a nonexistent or out-of-scope job.

Create `internal/api/api.go`.

<!-- file: internal/api/api.go -->
~~~go
package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"switchyard/tenantlab/internal/identity"
	"switchyard/tenantlab/internal/jobs"
	"switchyard/tenantlab/internal/quota"
)

type JobStore interface {
	Get(context.Context, string, string) (jobs.Job, error)
	Create(context.Context, string, jobs.Job) error
}

type Server struct {
	Verify *identity.Verifier
	Store  JobStore
	Quota  quota.Limiter
	Now    func() time.Time
}

type action string

const (
	readJob   action = "read"
	createJob action = "create"
)

func allowed(role string, operation action) bool {
	switch role {
	case "reader":
		return operation == readJob
	case "writer":
		return operation == readJob || operation == createJob
	default:
		return false
	}
}

func (s Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /jobs/{id}", s.protect(readJob, s.get))
	mux.Handle("POST /jobs", s.protect(createJob, s.create))
	return mux
}

func (s Server) protect(operation action, next func(http.ResponseWriter, *http.Request, identity.Principal)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		scheme, token, hasToken := strings.Cut(r.Header.Get("Authorization"), " ")
		if !hasToken || !strings.EqualFold(scheme, "Bearer") {
			token = ""
		}
		principal, err := s.Verify.Verify(token, s.Now())
		if err != nil {
			w.Header().Set("WWW-Authenticate", "Bearer")
			http.Error(w, "authentication required", http.StatusUnauthorized)
			return
		}
		if !allowed(principal.Role, operation) {
			http.Error(w, "permission denied", http.StatusForbidden)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		decision, err := s.Quota.Take(ctx, principal.Tenant)
		if err != nil {
			slog.Warn("quota unavailable", "error", err)
			http.Error(w, "capacity check unavailable", http.StatusServiceUnavailable)
			return
		}
		if !decision.Allowed {
			seconds := max(1, int(math.Ceil(decision.Retry.Seconds())))
			w.Header().Set("Retry-After", strconv.Itoa(seconds))
			http.Error(w, "tenant quota exhausted", http.StatusTooManyRequests)
			return
		}
		next(w, r.WithContext(ctx), principal)
	})
}

func (s Server) get(w http.ResponseWriter, r *http.Request, p identity.Principal) {
	id := r.PathValue("id")
	if !identity.ValidID(id) {
		http.Error(w, "invalid job ID", http.StatusBadRequest)
		return
	}
	job, err := s.Store.Get(r.Context(), p.Tenant, id)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		http.Error(w, "job not found", http.StatusNotFound)
	case err != nil:
		storeFailure(w, err)
	default:
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(job)
	}
}

func (s Server) create(w http.ResponseWriter, r *http.Request, p identity.Principal) {
	var job jobs.Job
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	decoder.DisallowUnknownFields()
	err := decoder.Decode(&job)
	if err != nil || decoder.Decode(new(any)) != io.EOF || !identity.ValidID(job.ID) ||
		strings.TrimSpace(job.Name) == "" || strings.ContainsRune(job.Name, 0) || utf8.RuneCountInString(job.Name) > 100 {
		http.Error(w, "invalid job", http.StatusBadRequest)
		return
	}
	err = s.Store.Create(r.Context(), p.Tenant, job)
	var pgErr *pgconn.PgError
	switch {
	case errors.As(err, &pgErr) && pgErr.Code == "23505":
		http.Error(w, "job already exists", http.StatusConflict)
	case err != nil:
		storeFailure(w, err)
	default:
		w.WriteHeader(http.StatusCreated)
	}
}

func storeFailure(w http.ResponseWriter, err error) {
	slog.Error("job store unavailable", "error", err)
	http.Error(w, "job store unavailable", http.StatusServiceUnavailable)
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


The live HTTP tests require `401` for a missing token, `403` for a reader creating a job, and `404` for either kind of missing row. A writer creates a job inside the tenant in its token.
