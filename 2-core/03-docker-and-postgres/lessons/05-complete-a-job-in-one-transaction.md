# 05 Complete a job in one transaction

> About 5 hours · Builds on [04 A connection pool has a limit](04-a-connection-pool-has-a-limit.md).

## The problem

Core 01 first marks a job completed, then puts its effect in an in-memory ledger. In PostgreSQL those two operations could be two separate writes. If the process stops between them, a reader sees a completed job with no recorded effect.

## The mental model

~~~text
BEGIN
  lock and read the job
  check the state transition
  update the job
  insert the effect
COMMIT    other transactions can now see both writes
~~~

A transaction holds these operations together. If the effect insert fails, a rollback removes the tentative update. A row lock makes a competing update wait for the transaction to finish. The primary key on the effect table gives every job at most one row.

The effect here is the record inside PostgreSQL. Sending an email or calling a payments API would put work outside this transaction's reach.

## The pattern

Put the invariant at the boundary that can enforce it. Keep transition rules in the Go domain. Let PostgreSQL serialize competing writes and commit both parts of a successful transition.

## Build it

### Step 1. Add the effects table

<!-- file: db/migrations/003_job_effects.sql -->
~~~sql
CREATE TABLE job_effects (
    job_id bigint PRIMARY KEY REFERENCES jobs (id),
    recorded_at timestamptz NOT NULL
);
~~~

Add this to the migration driver just before `COMMIT`:

<!-- edit: db/migrate.sql -->
~~~sql
COMMIT;
~~~

~~~sql
SELECT NOT EXISTS (
    SELECT 1 FROM schema_migrations WHERE version = 3
) AS apply_003 \gset
\if :apply_003
    \ir migrations/003_job_effects.sql
    INSERT INTO schema_migrations (version) VALUES (3);
\endif
COMMIT;
~~~

Apply the change to your lab with `migrate`. This migration creates the ledger for completions made from this point onward. If you're continuing with a database from the earlier lessons, rows already marked completed have no recorded database effect.

<!-- run: if [[ -n "${SWITCHYARD_TEST_DATABASE_URL:-}" ]]; then psql "$SWITCHYARD_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f db/migrate.sql; fi -->

### Step 2. Keep the transition and the two writes together

Borrow one connection. Every statement runs through the same transaction, including the read. `FOR UPDATE` locks that row through the end of the transaction. A bounded cleanup context lets the deferred rollback run even when the initiating request was cancelled. The connection returns to the pool after cleanup.

<!-- file: internal/pgstore/completion.go -->
~~~go
package pgstore

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"switchyard/internal/jobs"
)

func (s *Store) CompleteWithEffect(ctx context.Context, id jobs.ID, now time.Time) (jobs.Job, error) {
	conn, err := s.acquire(ctx)
	if err != nil {
		return jobs.Job{}, err
	}
	defer conn.Release()

	tx, err := conn.Begin(ctx)
	if err != nil {
		return jobs.Job{}, err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), time.Second)
		defer cancel()
		_ = tx.Rollback(cleanup)
	}()

	job, err := scanJob(tx.QueryRow(ctx, "SELECT "+columns+" FROM jobs WHERE id = $1 FOR UPDATE", id))
	if errors.Is(err, pgx.ErrNoRows) {
		return jobs.Job{}, jobs.ErrNotFound
	}
	if err != nil {
		return jobs.Job{}, err
	}
	if err := job.Complete(now.UTC().Truncate(time.Microsecond)); err != nil {
		return job, err
	}
	if _, err := tx.Exec(ctx, "UPDATE jobs SET state = $2, updated_at = $3 WHERE id = $1",
		id, job.State, job.UpdatedAt); err != nil {
		return jobs.Job{}, fmt.Errorf("update completed job: %w", err)
	}
	if _, err := tx.Exec(ctx, "INSERT INTO job_effects (job_id, recorded_at) VALUES ($1, $2)",
		id, job.UpdatedAt); err != nil {
		return jobs.Job{}, fmt.Errorf("record job effect: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return jobs.Job{}, fmt.Errorf("commit job completion: %w", err)
	}
	return job, nil
}

func (s *Store) CountEffects(ctx context.Context, id jobs.ID) (int, error) {
	conn, err := s.acquire(ctx)
	if err != nil {
		return 0, err
	}
	defer conn.Release()

	var n int
	err = conn.QueryRow(ctx, "SELECT count(*) FROM job_effects WHERE job_id = $1", id).Scan(&n)
	return n, err
}
~~~

If cancellation reaches PostgreSQL first, `job.Complete` sees a cancelled job after it takes the lock. If completion gets there first, cancellation's update compares against the changed state and the service reads the job again before deciding. The lock and conditional update cooperate across the adapters' distinct use cases.

### Step 3. Call the transaction from the use case

The memory backend keeps its existing path. Inject the atomic completion operation when the composition root chooses PostgreSQL.

<!-- edit: internal/jobs/service.go -->
~~~go
// Simulate is the default work:
~~~

~~~go
// Completion commits a successful job transition and its effect together.
type Completion interface {
	CompleteWithEffect(ctx context.Context, id ID, now time.Time) (Job, error)
}

// Simulate is the default work:
~~~

<!-- edit: internal/jobs/service.go -->
~~~go
	effects  Effects
~~~

~~~go
	effects    Effects
	completion Completion
~~~

<!-- edit: internal/jobs/service.go -->
~~~go
// Create stores a queued job and dispatches it.
~~~

~~~go
// WithCompletion supplies the transaction used by a durable backend.
func WithCompletion(c Completion) Option {
	return func(s *Service) { s.completion = c }
}

// Create stores a queued job and dispatches it.
~~~

<!-- edit: internal/jobs/service.go -->
~~~go
// Finish records how a running job ended. If it completed, its effect is
// recorded too, but only after the state change succeeded: a job that was
// cancelled or handed to another worker in the meantime gets no effect.
// (With a database, the two writes would be one transaction.)
func (s *Service) Finish(ctx context.Context, id ID, workErr error) (Job, error) {
~~~

~~~go
// Finish records how a running job ended. A durable backend commits a
// successful completion and its effect in one transaction.
func (s *Service) Finish(ctx context.Context, id ID, workErr error) (Job, error) {
	if workErr == nil && s.completion != nil {
		return s.completion.CompleteWithEffect(ctx, id, s.now())
	}
~~~

Leave a lease in place when completion returns an error, so its holder can retry until the lease expires. Give completion a deadline even if the worker disconnects.

<!-- edit: internal/coord/coord.go -->
~~~go
	delete(c.leases, job)
	finished, err := c.jobs.Finish(context.WithoutCancel(ctx), job, nil)
	if err != nil {
		return finished, err
	}
	c.finished[job] = token
~~~

~~~go
	finish, cancel := context.WithTimeout(context.WithoutCancel(ctx), c.ttl)
	defer cancel()
	finished, err := c.jobs.Finish(finish, job, nil)
	if err != nil {
		return finished, err
	}
	delete(c.leases, job)
	c.finished[job] = token
~~~

### Step 4. Read effects from the same backend

Give the read port a context and an error. A database read can fail, and reporting zero would be misleading.

<!-- edit: internal/httpapi/handler.go -->
~~~go
// EffectCounter says how many effects a job has had. *ledger.Ledger is one.
type EffectCounter interface {
	EffectsFor(job jobs.ID) int
}
~~~

~~~go
// EffectCounter reads the recorded effects for a job.
type EffectCounter interface {
	CountEffects(ctx context.Context, job jobs.ID) (int, error)
}
~~~

<!-- edit: internal/httpapi/handler.go -->
~~~go
	writeJSON(w, http.StatusOK, effectsResponse{JobID: id, Effects: h.effects.EffectsFor(id)})
~~~

~~~go
	n, err := h.effects.CountEffects(r.Context(), id)
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, effectsResponse{JobID: id, Effects: n})
~~~

<!-- edit: internal/ledger/ledger.go -->
~~~go
import (
	"fmt"
~~~

~~~go
import (
	"context"
	"fmt"
~~~

<!-- append: internal/ledger/ledger.go -->
~~~go
func (l *Ledger) CountEffects(ctx context.Context, job jobs.ID) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	return l.EffectsFor(job), nil
}
~~~

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
func (c countEffects) EffectsFor(job jobs.ID) int { return c[job] }
~~~

~~~go
func (c countEffects) CountEffects(_ context.Context, job jobs.ID) (int, error) {
	return c[job], nil
}
~~~

Choose the completion and read implementations together. The existing in-memory metric reads the in-process ledger, so register it only when that ledger is in use.

<!-- edit: cmd/switchyard/main.go -->
~~~go
	var repo jobs.Repository
	var pool *pgxpool.Pool
~~~

~~~go
	var repo jobs.Repository
	var pool *pgxpool.Pool
	var completion jobs.Completion
	effects := ledger.New()
	var effectCounter httpapi.EffectCounter = effects
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
		repo = pgstore.New(pool, cfg.DatabaseAcquireTimeout)
	}
	effects := ledger.New()
	pending := queue.New(cfg.QueueCapacity)
	service := jobs.NewService(repo, jobs.WithDispatcher(pending), jobs.WithEffects(effects))
~~~

~~~go
		store := pgstore.New(pool, cfg.DatabaseAcquireTimeout)
		repo, completion, effectCounter = store, store, store
	}
	pending := queue.New(cfg.QueueCapacity)
	service := jobs.NewService(repo, jobs.WithDispatcher(pending),
		jobs.WithEffects(effects), jobs.WithCompletion(completion))
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
		prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "effects_applied_total",
			Help: "Job effects recorded in the ledger.",
		}, func() float64 { applied, _ := effects.Counts(); return float64(applied) }),
	)

	if pool != nil {
~~~

~~~go
	)
	if pool == nil {
		metrics.MustRegister(prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "effects_applied_total",
			Help: "Job effects recorded in the ledger.",
		}, func() float64 { applied, _ := effects.Counts(); return float64(applied) }))
	}
	if pool != nil {
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
		httpapi.WithEffects(effects),
~~~

~~~go
		httpapi.WithEffects(effectCounter),
~~~

### Step 5. Force a failure after the first write

Use a disposable PostgreSQL database. The test temporarily adds a constraint that refuses an effect row for one particular job. The job update happens first. If both writes really belong to one transaction, the job is still running and has no effect after the second write fails.

<!-- file: internal/pgstore/completion_test.go -->
~~~go
package pgstore_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"switchyard/internal/jobs"
	"switchyard/internal/pgstore"
)

func completionFixture(t *testing.T) (context.Context, *pgxpool.Pool, *pgstore.Store, *jobs.Service, jobs.Job) {
	t.Helper()
	url := os.Getenv("SWITCHYARD_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set SWITCHYARD_TEST_DATABASE_URL to a migrated disposable database")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)

	store := pgstore.New(pool, time.Second)
	svc := jobs.NewService(store, jobs.WithCompletion(store))
	job, err := svc.Create(ctx, "record one effect", 0)
	if err != nil {
		t.Fatal(err)
	}
	job, err = svc.Start(ctx, job.ID)
	if err != nil {
		t.Fatal(err)
	}
	return ctx, pool, store, svc, job
}

func TestCompletionRollsBack(t *testing.T) {
	ctx, pool, store, svc, job := completionFixture(t)
	// Format only an internally generated integer. These DDL identifiers and
	// the CHECK expression cannot be supplied as query parameters.
	name := fmt.Sprintf("test_reject_effect_%d", job.ID)
	add := fmt.Sprintf("ALTER TABLE job_effects ADD CONSTRAINT %s CHECK (job_id <> %d)", name, job.ID)
	drop := "ALTER TABLE job_effects DROP CONSTRAINT IF EXISTS " + name
	if _, err := pool.Exec(ctx, add); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		if _, err := pool.Exec(cleanup, drop); err != nil {
			t.Errorf("remove test constraint: %v", err)
		}
	})

	_, err := svc.Finish(ctx, job.ID, nil)
	var reject *pgconn.PgError
	if !errors.As(err, &reject) || reject.ConstraintName != name {
		t.Fatalf("want the injected constraint error, got %v", err)
	}
	assertCompletion(t, ctx, store, job.ID, jobs.StateRunning, 0)

	if _, err := pool.Exec(ctx, drop); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Finish(ctx, job.ID, nil); err != nil {
		t.Fatal(err)
	}
	assertCompletion(t, ctx, store, job.ID, jobs.StateCompleted, 1)
}

func TestCompletionRacesCancellation(t *testing.T) {
	ctx, _, store, svc, job := completionFixture(t)
	start := make(chan struct{})
	var wg sync.WaitGroup
	var completeErr, cancelErr error
	wg.Add(2)
	go func() {
		defer wg.Done()
		<-start
		_, completeErr = svc.Finish(ctx, job.ID, nil)
	}()
	go func() {
		defer wg.Done()
		<-start
		_, cancelErr = svc.Cancel(ctx, job.ID)
	}()
	close(start)
	wg.Wait()

	switch {
	case completeErr == nil && errors.Is(cancelErr, jobs.ErrInvalidTransition):
		assertCompletion(t, ctx, store, job.ID, jobs.StateCompleted, 1)
	case cancelErr == nil && errors.Is(completeErr, jobs.ErrInvalidTransition):
		assertCompletion(t, ctx, store, job.ID, jobs.StateCancelled, 0)
	default:
		t.Fatalf("one transition must win: complete = %v, cancel = %v", completeErr, cancelErr)
	}
}

func assertCompletion(t *testing.T, ctx context.Context, store *pgstore.Store, id jobs.ID, state jobs.State, effects int) {
	t.Helper()
	got, err := store.Get(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	n, err := store.CountEffects(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != state || n != effects {
		t.Fatalf("job is %s with %d effects, want %s with %d", got.State, n, state, effects)
	}
	t.Logf("job is %s with %d effects", got.State, n)
}
~~~

Run the checks with `SWITCHYARD_TEST_DATABASE_URL` set to your lab database:

~~~bash
gofmt -w cmd/switchyard/main.go internal/jobs/service.go internal/coord/coord.go internal/pgstore
go test -race -v -count=1 -run '^TestCompletion' ./internal/pgstore
~~~

<!-- run: gofmt -w cmd/switchyard/main.go internal/jobs/service.go internal/coord/coord.go internal/pgstore && go vet ./... && go test -race -count=1 ./... -->

~~~text
=== RUN   TestCompletionRollsBack
    completion_test.go:69: job is running with 0 effects
    completion_test.go:77: job is completed with 1 effects
--- PASS: TestCompletionRollsBack (0.08s)
=== RUN   TestCompletionRacesCancellation
    completion_test.go:101: job is completed with 1 effects
--- PASS: TestCompletionRacesCancellation (0.06s)
PASS
ok  	switchyard/internal/pgstore	1.179s
~~~

To see the test catch the bug, temporarily move `tx.Commit(ctx)` to just before the effect insert and use `conn.Exec` for that insert. The constraint still refuses the effect, but the state update has already committed. Restore the transaction after the test fails.

~~~text
=== RUN   TestCompletionRollsBack
    completion_test.go:69: job is completed with 0 effects, want running with 0
--- FAIL: TestCompletionRollsBack (0.07s)
FAIL
FAIL	switchyard/internal/pgstore	0.097s
FAIL
~~~

### Step 6. Finish a job through Switchyard

Start the control plane against the migrated lab database and start a worker over gRPC:

~~~bash
go build -o bin/switchyard ./cmd/switchyard
go build -o bin/worker ./cmd/worker
SWITCHYARD_DATABASE_URL="$SWITCHYARD_TEST_DATABASE_URL" ./bin/switchyard
~~~

In a second terminal, run `CONTROL_PLANE=127.0.0.1:9090 ./bin/worker`. In a third, submit a fresh job, then look it up after the worker reports completion:

~~~bash
job=$(curl -fsS -H 'Content-Type: application/json' \
  -d '{"description":"transaction demo","duration_ms":50}' http://127.0.0.1:8080/jobs)
id=$(printf '%s\n' "$job" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')
curl -fsS "http://127.0.0.1:8080/jobs/$id"
curl -fsS "http://127.0.0.1:8080/effects/$id"
~~~

The captured run checked the state and effect count:

~~~text
job state: completed
effect count: 1
~~~

## Check it

Explain which part of the rollback test would fail if the job update ran directly on the connection in autocommit mode. Then explain which row the cancellation waits on while a completion is in progress.

## If it goes wrong

- A missing `job_effects` relation means the database needs migration 003.
- If both the state and effect are unchanged after an ordinary completion, surface the first SQL error and check the transaction's commit result.
- If a cancelled job gets an effect, check that the domain transition runs after the locked read and that the insert follows a successful transition.
