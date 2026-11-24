# 04 A connection pool has a limit

> About 4 hours · Builds on [03 One contract for two repositories](03-one-contract-for-two-repositories.md).

## The problem

A pool reuses connections instead of dialing PostgreSQL for every query. When all its connections are in use, another caller must wait. If it spends the entire request deadline waiting for a connection, the application loses its chance to report why it couldn't do the work.

## The mental model

~~~text
HTTP deadline
|---------------------------- 2 seconds -----------------------------|
|-- acquire at most 100 ms --|-- use the connection and return it ----|
~~~

The acquisition timeout is a budget inside the request deadline. It covers waiting for a connection, including the time needed to establish a new one. After acquisition, the query still uses the request's original context.

## The pattern

Bound the number of connections and the time callers can spend waiting for one. Give the pool time to recover after a burst. On overload, send a retryable response and expose counters that show whether callers were waiting.

## Build it

### Step 1. Name the failure at the port

The HTTP and gRPC handlers need a portable error for storage that cannot accept work within its budget.

<!-- edit: internal/jobs/repository.go -->
~~~go
	ErrConflict = errors.New("job was changed by another request")
~~~

~~~go
	ErrConflict = errors.New("job was changed by another request")
	ErrStoreBusy = errors.New("job storage is busy")
~~~

### Step 2. Give the pool a budget

The adapter borrows a connection explicitly. Use a child context for the acquisition and release the connection once the row has been read. If the caller already ran out of time or cancelled, return that error. A shorter timeout from the pool's budget becomes `ErrStoreBusy`.

<!-- edit: internal/pgstore/store.go -->
~~~go
type Store struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Store {
	return &Store{pool: pool}
}
~~~

~~~go
type Store struct {
	pool           *pgxpool.Pool
	acquireTimeout time.Duration
}

func New(pool *pgxpool.Pool, acquireTimeout time.Duration) *Store {
	return &Store{pool: pool, acquireTimeout: acquireTimeout}
}

func (s *Store) acquire(ctx context.Context) (*pgxpool.Conn, error) {
	wait, cancel := context.WithTimeout(ctx, s.acquireTimeout)
	defer cancel()

	conn, err := s.pool.Acquire(wait)
	if err == nil {
		return conn, nil
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return nil, jobs.ErrStoreBusy
	}
	return nil, err
}
~~~

<!-- edit: internal/pgstore/store.go -->
~~~go
	return scanJob(s.pool.QueryRow(ctx, `
~~~

~~~go
	conn, err := s.acquire(ctx)
	if err != nil {
		return jobs.Job{}, err
	}
	defer conn.Release()
	return scanJob(conn.QueryRow(ctx, `
~~~

<!-- edit: internal/pgstore/store.go -->
~~~go
	job, err := scanJob(s.pool.QueryRow(ctx, "SELECT "+columns+" FROM jobs WHERE id = $1", id))
~~~

~~~go
	conn, err := s.acquire(ctx)
	if err != nil {
		return jobs.Job{}, err
	}
	defer conn.Release()
	job, err := scanJob(conn.QueryRow(ctx, "SELECT "+columns+" FROM jobs WHERE id = $1", id))
~~~

<!-- edit: internal/pgstore/store.go -->
~~~go
	var updated, exists bool
	err := s.pool.QueryRow(ctx, `
~~~

~~~go
	conn, err := s.acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	var updated, exists bool
	err = conn.QueryRow(ctx, `
~~~

Use a one-second acquisition budget in the repository contract:

<!-- edit: internal/pgstore/store_test.go -->
~~~go
	repotest.Run(t, pgstore.New(pool))
~~~

~~~go
	repotest.Run(t, pgstore.New(pool, time.Second))
~~~

### Step 3. Map the error at the API

When storage runs out of time to accept work, HTTP returns `503` and a `Retry-After` hint. gRPC reports `Unavailable`. The client still decides when and whether to retry within its own deadline.

<!-- edit: internal/httpapi/handler.go -->
~~~go
	case errors.Is(err, jobs.ErrNotFound):
~~~

~~~go
	case errors.Is(err, jobs.ErrStoreBusy):
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusServiceUnavailable, "the service is busy; retry later")
	case errors.Is(err, jobs.ErrNotFound):
~~~

<!-- edit: internal/grpcapi/server.go -->
~~~go
	case errors.Is(err, jobs.ErrDispatchFailed):
~~~

~~~go
	case errors.Is(err, jobs.ErrDispatchFailed), errors.Is(err, jobs.ErrStoreBusy):
~~~

### Step 4. Choose the repository at startup

Set `SWITCHYARD_DATABASE_URL` to use PostgreSQL. Run the migrations before starting the API. A bounded startup ping checks that the database can accept a connection. Set the URL through the environment and keep it out of logs.

<!-- edit: cmd/switchyard/main.go -->
~~~go
	"github.com/prometheus/client_golang/prometheus"
~~~

~~~go
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
	"switchyard/internal/queue"
~~~

~~~go
	"switchyard/internal/pgstore"
	"switchyard/internal/queue"
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
	LeaseTTL       time.Duration
~~~

~~~go
	LeaseTTL       time.Duration
	DatabaseURL    string
	DatabaseMaxConns int
	DatabaseAcquireTimeout time.Duration
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
	return cfg, nil
}

func hostPortFromEnv
~~~

~~~go
	cfg.DatabaseURL = getenv("SWITCHYARD_DATABASE_URL")
	if cfg.DatabaseMaxConns, err = positiveIntFromEnv(getenv, "DATABASE_MAX_CONNS", 4); err != nil {
		return config{}, err
	}
	if cfg.DatabaseMaxConns > 1<<31-1 {
		return config{}, errors.New("DATABASE_MAX_CONNS exceeds the pool's range")
	}
	if cfg.DatabaseAcquireTimeout, err = durationFromEnv(getenv, "DATABASE_ACQUIRE_TIMEOUT", 100*time.Millisecond); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func hostPortFromEnv
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
	effects := ledger.New()
	pending := queue.New(cfg.QueueCapacity)
	service := jobs.NewService(memstore.New(), jobs.WithDispatcher(pending), jobs.WithEffects(effects))
~~~

~~~go
	var repo jobs.Repository
	var pool *pgxpool.Pool
	if cfg.DatabaseURL == "" {
		repo = memstore.New()
	} else {
		pool, err = openPool(ctx, cfg)
		if err != nil {
			return err
		}
		defer pool.Close()
		repo = pgstore.New(pool, cfg.DatabaseAcquireTimeout)
	}
	effects := ledger.New()
	pending := queue.New(cfg.QueueCapacity)
	service := jobs.NewService(repo, jobs.WithDispatcher(pending), jobs.WithEffects(effects))
~~~

Expose leased connections as a gauge because the number can rise and fall. Expose timed-out or cancelled acquisitions as a counter because the pool accumulates it.

<!-- edit: cmd/switchyard/main.go -->
~~~go
	handler := httpapi.NewHandler(service,
~~~

~~~go
	if pool != nil {
		metrics.MustRegister(
			gauge("db_pool_acquired_connections", "Connections currently acquired.", func() float64 {
				return float64(pool.Stat().AcquiredConns())
			}),
			prometheus.NewCounterFunc(prometheus.CounterOpts{
				Name: "db_pool_canceled_acquisitions_total",
				Help: "Pool acquisitions that ended when their context stopped.",
			}, func() float64 { return float64(pool.Stat().CanceledAcquireCount()) }),
		)
	}

	handler := httpapi.NewHandler(service,
~~~

<!-- append: cmd/switchyard/main.go -->
~~~go
func openPool(ctx context.Context, cfg config) (*pgxpool.Pool, error) {
	settings, err := pgxpool.ParseConfig(cfg.DatabaseURL)
	if err != nil {
		return nil, errors.New("invalid SWITCHYARD_DATABASE_URL")
	}
	settings.MaxConns = int32(cfg.DatabaseMaxConns)
	settings.MinConns = 0
	settings.MinIdleConns = 0
	startup, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	pool, err := pgxpool.NewWithConfig(startup, settings)
	if err != nil {
		return nil, errors.New("cannot create PostgreSQL pool")
	}
	if err := pool.Ping(startup); err != nil {
		pool.Close()
		return nil, errors.New("cannot reach PostgreSQL during startup")
	}
	return pool, nil
}
~~~

### Step 5. Hold every connection

Use a pool with one connection. Borrow it and keep it until after the first request has returned. That makes exhaustion repeatable without load, sleep, or a race between callers. The same handler has to succeed when the connection is returned.

<!-- file: internal/pgstore/pool_test.go -->
~~~go
package pgstore_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"switchyard/internal/httpapi"
	"switchyard/internal/jobs"
	"switchyard/internal/pgstore"
)

func TestPoolExhaustion(t *testing.T) {
	url := os.Getenv("SWITCHYARD_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set SWITCHYARD_TEST_DATABASE_URL to a migrated disposable database")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		t.Fatal("invalid test database URL")
	}
	cfg.MaxConns, cfg.MinConns, cfg.MinIdleConns = 1, 0, 0
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	held, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}

	const budget = 50 * time.Millisecond
	handler := httpapi.NewHandler(jobs.NewService(pgstore.New(pool, budget)))
	post := func() *httptest.ResponseRecorder {
		req := httptest.NewRequestWithContext(ctx, http.MethodPost, "/jobs",
			strings.NewReader(`{"description":"test the pool","duration_ms":0}`))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}

	start := time.Now()
	blocked := post()
	elapsed := time.Since(start)
	held.Release()
	t.Logf("HTTP %d after %s with %d cancelled acquisition(s)",
		blocked.Code, elapsed.Round(time.Millisecond), pool.Stat().CanceledAcquireCount())
	if blocked.Code != 503 || blocked.Header().Get("Retry-After") != "1" {
		t.Fatalf("pool exhausted: got %d %s", blocked.Code, blocked.Body)
	}
	if elapsed < budget || elapsed >= time.Second {
		t.Fatalf("pool wait was %s for a %s budget", elapsed, budget)
	}

	recovered := post()
	t.Logf("HTTP %d after the connection was returned", recovered.Code)
	if recovered.Code != 201 {
		t.Fatalf("pool recovered: got %d %s", recovered.Code, recovered.Body)
	}
}
~~~

~~~bash
gofmt -w cmd/switchyard/main.go internal/jobs/repository.go internal/pgstore
go test -race -v -count=1 -run '^TestPoolExhaustion$' ./internal/pgstore
~~~

~~~text
=== RUN   TestPoolExhaustion
    pool_test.go:57: HTTP 503 after 51ms with 1 cancelled acquisition(s)
    pool_test.go:67: HTTP 201 after the connection was returned
--- PASS: TestPoolExhaustion (0.09s)
PASS
ok  	switchyard/internal/pgstore	1.116s
~~~

<!-- run: gofmt -w cmd/switchyard/main.go internal/jobs/repository.go internal/pgstore && go vet ./... && go test -race -count=1 ./... -->

### Step 6. Measure pool pressure

Start the control plane with `SWITCHYARD_DATABASE_URL="$SWITCHYARD_TEST_DATABASE_URL"`. Use the job-submission command from [Core 02 lesson 07](../../02-python-runtime-and-honest-measurement/lessons/07-three-experiments-on-switchyard.md) and keep the same offered rate during a comparison. Restart with a different `DATABASE_MAX_CONNS` and compare job responses, `db_pool_acquired_connections`, and the change in `db_pool_canceled_acquisitions_total`. Keep workers and the queue the same across both runs. A `503` can also come from the jobs queue, so use both the database counter and `jobs_queue_depth` to identify what filled.

As a starting point, 200 database operations per second that hold a connection for 5 ms each occupy about one connection on average. Use the measured hold time and request rate to justify headroom for bursts, then check the resulting pool size against the database's connection budget. Apply the budget across every process that connects.

## Check it

With the lab database selected, build Switchyard and start it on the usual ports:

~~~bash
go build -o bin/switchyard ./cmd/switchyard
SWITCHYARD_DATABASE_URL="$SWITCHYARD_TEST_DATABASE_URL" ./bin/switchyard
~~~

In a second terminal, submit a job and save its response:

~~~bash
job=$(curl -fsS -H 'Content-Type: application/json' \
  -d '{"description":"persist me","duration_ms":0}' http://127.0.0.1:8080/jobs)
id=$(printf '%s\n' "$job" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')
curl -fsS http://127.0.0.1:8080/metrics | grep '^db_pool_'
~~~

Stop Switchyard with Ctrl+C and launch it again with the same URL. Back in the second terminal, compare the job with the saved response:

~~~bash
test "$(curl -fsS "http://127.0.0.1:8080/jobs/$id")" = "$job" && printf 'same job after restart\n'
~~~

The captured run recorded these checkpoints:

~~~text
POST /jobs: 201 ('persist me')
db_pool_acquired_connections 0
db_pool_canceled_acquisitions_total 0
GET after control-plane restart: 200 (same job)
~~~

The repository can still read the job. The worker dispatcher, lease state, and effect ledger still use process memory in this lesson. The next lessons make completion and retries durable and give unfinished jobs a recovery path.

## If it goes wrong

- If the pool test was skipped, check `SWITCHYARD_TEST_DATABASE_URL` and run it with `-v`.
- If the service starts and every database request reports a missing relation, run the migrations against the URL used by the service.
- If clients hit their own deadline before they see a response, check that the acquisition budget leaves time for the query and response.
