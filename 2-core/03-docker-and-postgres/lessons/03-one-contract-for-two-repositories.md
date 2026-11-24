# 03 One contract for two repositories

> About 5 hours · Builds on [02 A schema you can change](02-a-schema-you-can-change.md).

## The problem

Core 01 relied on a mutex around the in-memory repository's conditional update. Two requests can still read the same old state, so only the first update with that expected state may succeed. When the jobs live in PostgreSQL, the test should ask the same question and the database has to enforce the condition.

## The mental model

~~~text
                    jobs.Repository
                   /               \
     mutex + in-memory map      PostgreSQL + conditional UPDATE
                        same contract tests
~~~

Core 01's repository compares the **expected state**. The test in this lesson starts with a queued job and sends two concurrent updates that would move it out of that state. PostgreSQL serializes the two writes to that row and checks the predicate against the row it can update.

## The pattern

Define the expectations at the port. Run the same test suite against both adapters and check database-specific behavior against PostgreSQL itself. The implementation details belong inside each adapter.

## Build it

### Step 1. Write the shared contract

The contract checks the data you get back, your error when you read an absent ID, and the result when two writers compete for the same state. The fixture uses a description with a quote and a duration below a millisecond so it catches a transcription error in either value. Use a deadline for the whole test, including the competing writes.

<!-- file: internal/repotest/contract.go -->
~~~go
package repotest

import (
	"context"
	"errors"
	"testing"
	"time"

	"switchyard/internal/jobs"
)

// Run exercises the shared behavior of a jobs repository.
func Run(t *testing.T, repo jobs.Repository) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	now := time.Date(2026, 1, 2, 3, 4, 5, 123456000, time.UTC)
	description, err := jobs.NewDescription("Resize O'Reilly's cover")
	if err != nil {
		t.Fatal(err)
	}
	want, err := jobs.New(description, 123*time.Microsecond, now)
	if err != nil {
		t.Fatal(err)
	}
	created, err := repo.Create(ctx, want)
	if err != nil {
		t.Fatal(err)
	}
	if created.ID <= 0 {
		t.Fatalf("create returned invalid ID %d", created.ID)
	}
	want.ID = created.ID
	checkJob(t, created, want)
	got, err := repo.Get(ctx, want.ID)
	if err != nil {
		t.Fatal(err)
	}
	checkJob(t, got, want)

	if _, err := repo.Get(ctx, -1); !errors.Is(err, jobs.ErrNotFound) {
		t.Fatalf("get absent: got %v, want ErrNotFound", err)
	}
	missing := want
	missing.ID = -1
	if err := repo.Update(ctx, missing, jobs.StateQueued); !errors.Is(err, jobs.ErrNotFound) {
		t.Fatalf("update absent: got %v, want ErrNotFound", err)
	}

	running, cancelled := want, want
	if err := running.Start(now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := cancelled.Cancel(now.Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	type result struct {
		job jobs.Job
		err error
	}
	start := make(chan struct{})
	results := make(chan result, 2)
	for _, next := range []jobs.Job{running, cancelled} {
		go func() {
			<-start
			results <- result{next, repo.Update(ctx, next, jobs.StateQueued)}
		}()
	}
	close(start)
	first, second := <-results, <-results
	if first.err != nil {
		first, second = second, first
	}
	if first.err != nil || !errors.Is(second.err, jobs.ErrConflict) {
		t.Fatalf("update pair: got %v and %v, want one success and one conflict", first.err, second.err)
	}
	got, err = repo.Get(ctx, want.ID)
	if err != nil {
		t.Fatal(err)
	}
	checkJob(t, got, first.job)
}

func checkJob(t *testing.T, got, want jobs.Job) {
	t.Helper()
	if got.ID != want.ID || got.Description != want.Description || got.Duration != want.Duration ||
		got.State != want.State || got.FailureReason != want.FailureReason ||
		!got.CreatedAt.Equal(want.CreatedAt) || !got.UpdatedAt.Equal(want.UpdatedAt) {
		t.Fatalf("job = %+v, want %+v", got, want)
	}
}
~~~

Register the contract for the memory adapter first:

<!-- file: internal/memstore/contract_test.go -->
~~~go
package memstore_test

import (
	"testing"

	"switchyard/internal/memstore"
	"switchyard/internal/repotest"
)

func TestRepositoryContract(t *testing.T) {
	repotest.Run(t, memstore.New())
}
~~~

<!-- run: go test -race -count=1 ./internal/memstore -->

### Step 2. Implement PostgreSQL reads and inserts

Add `pgx`, a PostgreSQL driver for Go. For now the adapter accepts a connection pool from its caller. In the next lesson you'll choose the pool size and measure what happens at the limit.

~~~bash
go get github.com/jackc/pgx/v5/pgxpool@v5.11.0
~~~

<!-- run: go get github.com/jackc/pgx/v5/pgxpool@v5.11.0 -->

The adapter sends the description and duration as arguments. The query text stays fixed no matter what description the caller supplies. `RETURNING` reads the row the database actually stored, including its ID and timestamp precision.

<!-- file: internal/pgstore/store.go -->
~~~go
// Package pgstore implements the jobs repository on PostgreSQL.
package pgstore

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"switchyard/internal/jobs"
)

const columns = "id, description, duration_ns, state, failure_reason, created_at, updated_at"

type Store struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Store {
	return &Store{pool: pool}
}

func scanJob(row pgx.Row) (jobs.Job, error) {
	var job jobs.Job
	var durationNS int64
	if err := row.Scan(&job.ID, &job.Description, &durationNS, &job.State,
		&job.FailureReason, &job.CreatedAt, &job.UpdatedAt); err != nil {
		return jobs.Job{}, err
	}
	job.Duration = time.Duration(durationNS)
	job.CreatedAt = job.CreatedAt.UTC()
	job.UpdatedAt = job.UpdatedAt.UTC()
	return job, nil
}

func (s *Store) Create(ctx context.Context, job jobs.Job) (jobs.Job, error) {
	return scanJob(s.pool.QueryRow(ctx, `
		INSERT INTO jobs (description, duration_ns, state, failure_reason, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING `+columns, job.Description, int64(job.Duration), job.State,
		job.FailureReason, job.CreatedAt, job.UpdatedAt))
}

func (s *Store) Get(ctx context.Context, id jobs.ID) (jobs.Job, error) {
	job, err := scanJob(s.pool.QueryRow(ctx, "SELECT "+columns+" FROM jobs WHERE id = $1", id))
	if errors.Is(err, pgx.ErrNoRows) {
		return jobs.Job{}, jobs.ErrNotFound
	}
	return job, err
}
~~~

### Step 3. Make the conditional update a single database statement

The condition is part of the write. A common table expression, the `WITH` clause, gives the outer query the IDs that the update touched. When nothing changed, the second check tells you whether the row exists. Switchyard keeps job rows for their entire lifetime.

<!-- append: internal/pgstore/store.go -->
~~~go
var _ jobs.Repository = (*Store)(nil)

func (s *Store) Update(ctx context.Context, job jobs.Job, expected jobs.State) error {
	var updated, exists bool
	err := s.pool.QueryRow(ctx, `
		WITH changed AS (
			UPDATE jobs
			SET description = $2, duration_ns = $3, state = $4, failure_reason = $5,
			    created_at = $6, updated_at = $7
			WHERE id = $1 AND state = $8
			RETURNING id
		)
		SELECT EXISTS (SELECT 1 FROM changed), EXISTS (SELECT 1 FROM jobs WHERE id = $1)`,
		job.ID, job.Description, int64(job.Duration), job.State,
		job.FailureReason, job.CreatedAt, job.UpdatedAt, expected).Scan(&updated, &exists)
	if err != nil {
		return err
	}
	if updated {
		return nil
	}
	if exists {
		return jobs.ErrConflict
	}
	return jobs.ErrNotFound
}
~~~

### Step 4. Run the contract on a real database

Apply the migrations from lesson 02 to a disposable PostgreSQL database that Go can reach. If you start a new Docker lab for this test, pass `-p 127.0.0.1::5432` to `start_db` and run `migrate`. Docker will assign an available host port.

<!-- file: internal/pgstore/store_test.go -->
~~~go
package pgstore_test

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"switchyard/internal/pgstore"
	"switchyard/internal/repotest"
)

func TestRepositoryContract(t *testing.T) {
	url := os.Getenv("SWITCHYARD_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set SWITCHYARD_TEST_DATABASE_URL to a migrated disposable database")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if err := pool.Ping(ctx); err != nil {
		t.Fatal(err)
	}
	repotest.Run(t, pgstore.New(pool))
}
~~~

~~~bash
port=$(docker port "$db" 5432/tcp)
export SWITCHYARD_TEST_DATABASE_URL="postgres://switchyard:lab-only@$port/switchyard?sslmode=disable"
go test -race -v -count=1 -run '^TestRepositoryContract$' ./internal/memstore ./internal/pgstore
~~~

~~~text
=== RUN   TestRepositoryContract
--- PASS: TestRepositoryContract (0.00s)
PASS
ok  	switchyard/internal/memstore	1.026s
=== RUN   TestRepositoryContract
--- PASS: TestRepositoryContract (0.06s)
PASS
ok  	switchyard/internal/pgstore	1.094s
~~~

<!-- run: go mod tidy && go vet ./internal/memstore ./internal/pgstore ./internal/repotest && go test -race -count=1 ./internal/memstore ./internal/pgstore -->

### Step 5. Check that the test catches a stale write

Temporarily make the SQL predicate `WHERE id = $1 AND (state = $8 OR true)`. It still accepts all eight parameters, so the test can reach the incorrect update. Rerun the PostgreSQL contract and put the predicate back.

~~~text
=== RUN   TestRepositoryContract
    store_test.go:31: update pair: got <nil> and <nil>, want one success and one conflict
--- FAIL: TestRepositoryContract (0.06s)
FAIL
FAIL	switchyard/internal/pgstore	0.085s
FAIL
~~~

## Check it

Draw the two write attempts on one job. Which state can the second attempt see after the first commits? Explain why a separate `SELECT` before an unconditional `UPDATE` would give both attempts a chance to proceed.

## If it goes wrong

- A skipped test means the database URL is unset. Use `-v` and check that both contract tests actually ran.
- A missing relation means the test database does not have lesson 02's schema. Run the migration driver against the same database named in your URL.
- A mismatch smaller than a microsecond can be a timestamp precision difference. Use `RETURNING` for the value you send back and compare times at the precision of the database.
