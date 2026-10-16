# Phase 3 teaching: make data durable

At the end of Phase 2, Runway survives a worker being killed in the middle of a job. Restart the **API**, though, and every job it ever accepted is gone, because the jobs live in a Go map. Even the in-memory design has a gap Phase 2 couldn't close: the API stores a job and then publishes its command in two separate steps, and a crash between them leaves a job that will never run.

This phase puts the data where it survives: **PostgreSQL**. Then it deals with everything that follows from sharing one database between many requests, many processes and many instances:
- connections are scarce;
- concurrent writes can quietly lose each other's changes;
- a database write and a message send can't be made atomic directly;
- reads become the bottleneck;
- maintenance has to run somewhere;
- the database itself can hang or die.

Along the way, Runway's history becomes an **event stream** in Kafka that other services read at their own pace. The Rust log you built in the Rust Bridge becomes Runway's append-only audit trail.

**The goal:** every job and every change to it survives restarts and crashes, together with an event history that can't disagree with it. Commands and events leave through a transactional outbox, so none is lost. Job events stream to Kafka, where a projector builds a read model and a feed writes them into the Rust audit log. Reads are cached in Redis, background tasks keep the tables clean, and the API fails fast when the database is in trouble. You'll also have practised restoring from a backup.

**Time:** about 7 weeks. **Before you start:** finish Phase 2 and the Rust Bridge. Docker must be working, as in Phase 2.

## How this guide works

The same as before. You type everything into your `practice/` folder, a new file appears in full the first time, and later changes are exact edits. Each step ends with tests you run. CI rebuilds the code from this guide, against real PostgreSQL, Redis, Kafka and RabbitMQ, so every step is known to work.

| Step | What you add |
|---|---|
| 1 | PostgreSQL behind the same `Repository` port: SQL, migrations, contract tests, SQL injection |
| 2 | Connection pooling: sized, measured, and exhausted on purpose |
| 3 | Transactions: a history that commits with each change, and an isolation anomaly reproduced and fixed |
| 4 | The transactional outbox: closing Phase 2's dual-write gap |
| 5 | Idempotency keys in PostgreSQL, shared by every instance |
| 6 | Kafka: an event stream, consumer groups, replay, and an inbox |
| 7 | Redis: cache-aside, stampede protection, and failing open |
| 8 | Background jobs: a runner, advisory locks, an abandoned-job reaper, and `EXPLAIN ANALYZE` |
| 9 | A circuit breaker around the database, and readiness vs liveness |
| 10 | The audit log: job events from Kafka into the Rust `klog` |
| 11 | Backup, restore and crash recovery: a drill |

## Setup

Start from your finished Phase 2 code. From the repository root:

~~~bash
cd lessons/03-durable-auditable-data
cp -r ../02-connected-services/practice practice
cd practice
go test ./...
~~~

Everything should pass before you change anything.

<!-- continue: ../02-connected-services/TEACHING.md -->

Integration tests in this phase need real servers. Each test package skips itself unless its variable is set, exactly like `RUNWAY_AMQP_URL` in Phase 2. Once the servers are running (step 1 starts PostgreSQL, step 6 Kafka, step 7 Redis), put these in your shell for the rest of the phase:

~~~bash
export RUNWAY_AMQP_URL=amqp://guest:guest@localhost:5672/
export RUNWAY_DATABASE_URL=postgres://runway:runway@localhost:5432/runway
export RUNWAY_KAFKA_BROKERS=localhost:9092
export RUNWAY_REDIS_URL=redis://localhost:6379/0
~~~

A test that says `SKIP` hasn't checked anything. When you see one, check that its variable is set.

---

## Step 1: PostgreSQL behind the same port

**The problem.** Run the Phase 2 API on its own (no `AMQP_URL`, so it uses the in-memory bus), create a job, then restart the API and ask for the job:

~~~bash
go run ./cmd/api &
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"resize","duration_ms":200}'
kill %1; go run ./cmd/api &
curl -s http://127.0.0.1:8080/jobs/1
~~~

~~~text
{"id":1,"state":"queued","description":"resize","duration_ms":200,"created_at":"2026-10-05T19:27:43.656639341Z","updated_at":"2026-10-05T19:27:43.656639341Z"}
{"error":"job not found"}
~~~

(`&` runs a command in the background; `kill %1` stops background job number 1. Give the API a second to start before each `curl`.)

The job existed only in the process's memory, and the process is gone. A second API instance would have had its own separate map, so it couldn't have answered either. Both problems have the same cause: the data lives inside one process.

**New ideas.**

- A **database server** is a separate, long-running process whose whole job is to keep data safe and answer questions about it. Your service is its **client**: it connects over the network and sends requests. PostgreSQL ("Postgres") is the database you'll use. It's open source and widely deployed, and its documentation is excellent.
- PostgreSQL is **relational**. Data lives in **tables**. A table has named, typed **columns**, and each **row** is one record: one job, here. The **schema** is the set of tables and their columns.
- A **primary key** is the column that identifies a row; no two rows may share one. An **identity column** asks the database to assign the next number itself, as `memstore` did with its counter.
- **Constraints** are rules the database enforces on every write, whatever client sends it. `NOT NULL` forbids missing values; `CHECK (...)` forbids values that fail a condition. They are a second line of defence behind the domain's validation, because a database usually outlives any one version of the code that writes to it.
- **SQL** is the language you send. This step uses:
  - `CREATE TABLE`, which defines a table;
  - `INSERT`, which adds rows;
  - `SELECT ... WHERE`, which reads rows matching a condition;
  - `UPDATE ... WHERE`, which changes them.

  `RETURNING` makes an `INSERT` or `UPDATE` send back values from the row it wrote, in the same round trip.
- **Query parameters.** You never build SQL by pasting values into the text. You write placeholders (`$1`, `$2`, …) and send the values separately, and the server never confuses a value with SQL. Pasting values in is how **SQL injection** happens; you'll do it on purpose below.
- **pgx** is the Go driver for PostgreSQL. You'll use its **pool** (`pgxpool`), which keeps several connections open and lends them out. Step 2 is all about the pool, so for now treat it as "the database handle".
- A **migration** is a numbered, versioned change to the schema, kept in the repository with the code. A tool applies the ones a database hasn't had yet, and records which it has applied in a table of its own. Every environment (your laptop, CI, production) then gets the same schema by the same steps. You'll use **goose**. Its migrations are SQL files with an `Up` section (apply) and a `Down` section (undo).
- **`//go:embed`** compiles files into the Go binary, so the migrations ship inside the program that needs them.
- A **contract test** is one set of tests that every implementation of an interface must pass. You'll move the repository's rules into a shared contract and run it against both `memstore` and PostgreSQL. This is the payoff of the `Repository` port from Phase 1: the domain, the HTTP handlers and the gRPC server don't change at all.

### Run PostgreSQL

Add a PostgreSQL service to `compose.yaml`. Change:

<!-- edit: compose.yaml -->
~~~yaml
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 5s
      timeout: 10s
      retries: 20
~~~

to:

~~~yaml
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 5s
      timeout: 10s
      retries: 20

  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: runway
      POSTGRES_PASSWORD: runway
      POSTGRES_DB: runway
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data # the data outlives the container
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "runway"]
      interval: 2s
      timeout: 5s
      retries: 20

volumes:
  pgdata:
~~~

The image creates the `runway` user and database on first start. **`volumes`** gives the data directory a named Docker volume, `pgdata`, so the data survives `docker compose down` and even deleting the container. `docker compose down -v` deletes the volume as well, when you want a clean start.

Start it and ask it something:

~~~bash
docker compose up -d --wait postgres
docker compose exec postgres psql -U runway -c 'SELECT 1 + 1 AS two'
~~~

~~~text
 two 
-----
   2
(1 row)
~~~

`psql` is PostgreSQL's command-line client. Running it inside the container with `docker compose exec` means you don't need to install it. You'll use it throughout this phase to look at what your code wrote.

### The schema

Get the driver and the migration tool:

<!-- run: go get github.com/jackc/pgx/v5@v5.11.0 github.com/pressly/goose/v3@v3.28.0 -->
~~~bash
go get github.com/jackc/pgx/v5@v5.11.0 github.com/pressly/goose/v3@v3.28.0
~~~

Create the first migration, `internal/pgstore/migrations/0001_jobs.sql`:

<!-- file: internal/pgstore/migrations/0001_jobs.sql -->
~~~sql
-- +goose Up
CREATE TABLE jobs (
    id             BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    description    TEXT        NOT NULL CHECK (char_length(description) BETWEEN 1 AND 200),
    duration_ms    BIGINT      NOT NULL CHECK (duration_ms BETWEEN 0 AND 5000),
    state          TEXT        NOT NULL CHECK (state IN ('queued', 'running', 'completed', 'failed')),
    failure_reason TEXT        NOT NULL DEFAULT '',
    created_at     TIMESTAMPTZ NOT NULL,
    updated_at     TIMESTAMPTZ NOT NULL
);

-- +goose Down
DROP TABLE jobs;
~~~

Each column matches a field of `jobs.Job`:

| Column | Type | Why |
|---|---|---|
| `id` | `BIGINT GENERATED ALWAYS AS IDENTITY` | A 64-bit integer the database assigns, like `jobs.ID` |
| `description` | `TEXT` with a length check | The same rule as `NewDescription` |
| `duration_ms` | `BIGINT` with a range check | A `time.Duration` stored as whole milliseconds, the unit the API uses |
| `state` | `TEXT` restricted to four values | The four states of the domain |
| `failure_reason` | `TEXT`, empty by default | Empty unless the job failed |
| `created_at`, `updated_at` | `TIMESTAMPTZ` | A moment in time. PostgreSQL stores it in UTC and keeps **microseconds**; Go keeps nanoseconds. That difference will bite in a moment |

### The adapter

Create `internal/pgstore/pgstore.go`:

<!-- file: internal/pgstore/pgstore.go -->
~~~go
// Package pgstore keeps jobs in PostgreSQL. It implements jobs.Repository,
// the same port memstore implements, so nothing above it changes.
package pgstore

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/pressly/goose/v3/database"

	"runway/internal/jobs"
)

//go:embed migrations/*.sql
var migrations embed.FS

// Migrate applies every migration the database hasn't seen yet.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	files, err := fs.Sub(migrations, "migrations")
	if err != nil {
		return err
	}
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	provider, err := goose.NewProvider(database.DialectPostgres, db, files)
	if err != nil {
		return err
	}
	if _, err := provider.Up(ctx); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}

// Store implements jobs.Repository on a pool of PostgreSQL connections.
type Store struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Store {
	return &Store{pool: pool}
}

func (s *Store) Create(ctx context.Context, job jobs.Job) (jobs.Job, error) {
	err := s.pool.QueryRow(ctx, `
		INSERT INTO jobs (description, duration_ms, state, failure_reason, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING id, created_at, updated_at`,
		job.Description, job.Duration.Milliseconds(), job.State, job.FailureReason, job.CreatedAt, job.UpdatedAt,
	).Scan(&job.ID, &job.CreatedAt, &job.UpdatedAt)
	if err != nil {
		return jobs.Job{}, fmt.Errorf("create job: %w", err)
	}
	job.CreatedAt, job.UpdatedAt = job.CreatedAt.UTC(), job.UpdatedAt.UTC()
	return job, nil
}

func (s *Store) Get(ctx context.Context, id jobs.ID) (jobs.Job, error) {
	row := s.pool.QueryRow(ctx, `
		SELECT id, description, duration_ms, state, failure_reason, created_at, updated_at
		FROM jobs WHERE id = $1`, id)
	job, err := scanJob(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return jobs.Job{}, jobs.ErrNotFound
	}
	if err != nil {
		return jobs.Job{}, fmt.Errorf("get job %d: %w", id, err)
	}
	return job, nil
}

// Update is compare-and-swap in SQL: the WHERE clause checks the expected
// state and the write happens in one statement, so two updates can't both
// succeed from the same starting state.
func (s *Store) Update(ctx context.Context, job jobs.Job, expected jobs.State) error {
	tag, err := s.pool.Exec(ctx, `
		UPDATE jobs SET state = $2, failure_reason = $3, updated_at = $4
		WHERE id = $1 AND state = $5`,
		job.ID, job.State, job.FailureReason, job.UpdatedAt, expected)
	if err != nil {
		return fmt.Errorf("update job %d: %w", job.ID, err)
	}
	if tag.RowsAffected() == 1 {
		return nil
	}
	// No row matched: the job is missing, or its state has moved on.
	var exists bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM jobs WHERE id = $1)`, job.ID).Scan(&exists); err != nil {
		return fmt.Errorf("update job %d: %w", job.ID, err)
	}
	if !exists {
		return jobs.ErrNotFound
	}
	return jobs.ErrConflict
}

func scanJob(row pgx.Row) (jobs.Job, error) {
	var job jobs.Job
	var durationMS int64
	err := row.Scan(&job.ID, &job.Description, &durationMS, &job.State, &job.FailureReason, &job.CreatedAt, &job.UpdatedAt)
	job.Duration = time.Duration(durationMS) * time.Millisecond
	job.CreatedAt, job.UpdatedAt = job.CreatedAt.UTC(), job.UpdatedAt.UTC()
	return job, err
}
~~~

Read it piece by piece:

- `Migrate` hands goose the embedded files. goose works with Go's standard `database/sql` interface, so `stdlib.OpenDBFromPool` wraps the pool in one.
- `Create` uses `RETURNING` to get the new ID **and the timestamps as stored**. PostgreSQL keeps only microseconds, so the stored `created_at` can differ from the one Go sent. The repository must return what it actually kept, or a later `Get` would disagree with `Create`.
- `Get` turns `pgx.ErrNoRows` into the domain's `jobs.ErrNotFound`. No PostgreSQL error leaks above this package.
- `Update` is the same **compare-and-swap** as `memstore`, done by the database. The `WHERE` clause matches the row only if its state is still the expected one, and the check and the write happen in **one statement**. When no row matched, a second query tells "missing" from "changed".
- Every query passes values as parameters (`$1`, `$2`, …). No value is ever pasted into the SQL text.

### One contract for every store

The rules `memstore`'s tests check are really rules of the `Repository` port. Move them where every implementation can use them. Create `internal/jobs/jobstest/contract.go`:

<!-- file: internal/jobs/jobstest/contract.go -->
~~~go
// Package jobstest checks that a jobs.Repository behaves the way the jobs
// package relies on. Every implementation runs these same tests, so the
// in-memory store and PostgreSQL can't quietly drift apart.
package jobstest

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"runway/internal/jobs"
)

// t0 has nanoseconds on purpose: PostgreSQL keeps only microseconds, and
// the contract must notice if a store hands back a time it didn't keep.
var t0 = time.Date(2026, 10, 5, 12, 0, 0, 123456789, time.UTC)

func newJob(t *testing.T) jobs.Job {
	t.Helper()
	job, err := jobs.New("resize", 250*time.Millisecond, t0)
	if err != nil {
		t.Fatal(err)
	}
	return job
}

// Run runs the contract. newRepo must return an empty repository.
func Run(t *testing.T, newRepo func(t *testing.T) jobs.Repository) {
	ctx := context.Background()

	t.Run("create assigns increasing IDs", func(t *testing.T) {
		repo := newRepo(t)
		first, err := repo.Create(ctx, newJob(t))
		if err != nil {
			t.Fatal(err)
		}
		second, _ := repo.Create(ctx, newJob(t))
		if first.ID <= 0 || second.ID <= first.ID {
			t.Fatalf("IDs %d then %d; want positive and increasing", first.ID, second.ID)
		}
	})

	t.Run("get returns exactly what was stored", func(t *testing.T) {
		repo := newRepo(t)
		created, _ := repo.Create(ctx, newJob(t))
		got, err := repo.Get(ctx, created.ID)
		if err != nil {
			t.Fatal(err)
		}
		if got != created || got.Duration != 250*time.Millisecond || got.CreatedAt.Sub(t0).Abs() > time.Microsecond {
			t.Fatalf("got %+v, want %+v", got, created)
		}
	})

	t.Run("get unknown is ErrNotFound", func(t *testing.T) {
		if _, err := newRepo(t).Get(ctx, 999); !errors.Is(err, jobs.ErrNotFound) {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("update with the expected state succeeds", func(t *testing.T) {
		repo := newRepo(t)
		job, _ := repo.Create(ctx, newJob(t))
		_ = job.Start(t0.Add(time.Second))
		if err := repo.Update(ctx, job, jobs.StateQueued); err != nil {
			t.Fatal(err)
		}
		got, _ := repo.Get(ctx, job.ID)
		if got.State != jobs.StateRunning || got.UpdatedAt.Sub(t0.Add(time.Second)).Abs() > time.Microsecond {
			t.Fatalf("got %+v", got)
		}
	})

	t.Run("update from a stale state is ErrConflict and changes nothing", func(t *testing.T) {
		repo := newRepo(t)
		job, _ := repo.Create(ctx, newJob(t))
		_ = job.Fail("first", t0)
		if err := repo.Update(ctx, job, jobs.StateRunning); !errors.Is(err, jobs.ErrConflict) {
			t.Fatalf("error = %v, want ErrConflict", err)
		}
		if got, _ := repo.Get(ctx, job.ID); got.State != jobs.StateQueued {
			t.Fatalf("state = %s; a refused update must change nothing", got.State)
		}
	})

	t.Run("update unknown is ErrNotFound", func(t *testing.T) {
		if err := newRepo(t).Update(ctx, jobs.Job{ID: 999}, jobs.StateQueued); !errors.Is(err, jobs.ErrNotFound) {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("concurrent compare-and-swap lets exactly one win", func(t *testing.T) {
		repo := newRepo(t)
		job, _ := repo.Create(ctx, newJob(t))
		_ = job.Start(t0)

		const callers = 10
		results := make(chan error, callers)
		var wg sync.WaitGroup
		for range callers {
			wg.Add(1)
			go func() {
				defer wg.Done()
				results <- repo.Update(ctx, job, jobs.StateQueued)
			}()
		}
		wg.Wait()
		close(results)
		won := 0
		for err := range results {
			switch {
			case err == nil:
				won++
			case !errors.Is(err, jobs.ErrConflict):
				t.Fatalf("unexpected error %v", err)
			}
		}
		if won != 1 {
			t.Fatalf("%d updates won, want exactly 1", won)
		}
	})

	t.Run("a cancelled context is refused", func(t *testing.T) {
		repo := newRepo(t)
		cancelled, cancel := context.WithCancel(ctx)
		cancel()
		if _, err := repo.Create(cancelled, newJob(t)); !errors.Is(err, context.Canceled) {
			t.Fatalf("error = %v, want context.Canceled", err)
		}
	})
}
~~~

`Run` takes a function that makes a fresh, empty repository, and runs every rule against it. Notice `t0` has nanoseconds on purpose: a store that rounds times must not pretend it didn't.

Run the contract against `memstore` too. In `internal/memstore/store_test.go`, add the import. Change:

<!-- edit: internal/memstore/store_test.go -->
~~~go
	"runway/internal/jobs"
)
~~~

to:

~~~go
	"runway/internal/jobs"
	"runway/internal/jobs/jobstest"
)
~~~

and add at the end:

<!-- append: internal/memstore/store_test.go -->
~~~go
func TestContract(t *testing.T) {
	jobstest.Run(t, func(*testing.T) jobs.Repository { return New() })
}
~~~

### Test against a real database

Tests in different packages run at the same time, and they must not see each other's rows. The trick: give every test its own **schema**. In PostgreSQL, a schema is a namespace for tables inside one database, and the `search_path` setting says which one unqualified table names refer to. Create `internal/pgstore/pgtest/pgtest.go`:

<!-- file: internal/pgstore/pgtest/pgtest.go -->
~~~go
// Package pgtest gives each test its own empty PostgreSQL schema, so tests
// in different packages can share one database without seeing each other.
package pgtest

import (
	"context"
	"crypto/rand"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// URL creates a fresh schema and returns RUNWAY_DATABASE_URL with that
// schema as its search path, so every table the test creates lands in it.
// The schema is dropped when the test ends. The test is skipped when
// RUNWAY_DATABASE_URL is unset.
func URL(t *testing.T) string {
	t.Helper()
	base := os.Getenv("RUNWAY_DATABASE_URL")
	if base == "" {
		t.Skip("set RUNWAY_DATABASE_URL to run PostgreSQL tests")
	}
	ctx := context.Background()
	schema := "test_" + strings.ToLower(rand.Text())

	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close(ctx)
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if conn, err := pgx.Connect(context.Background(), base); err == nil {
			_, _ = conn.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE")
			conn.Close(context.Background())
		}
	})

	u, err := url.Parse(base)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	return u.String()
}

// Pool connects to a fresh schema (see URL) and applies migrate to it.
func Pool(t *testing.T, migrate func(context.Context, *pgxpool.Pool) error) *pgxpool.Pool {
	t.Helper()
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, URL(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if err := migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	return pool
}
~~~

`URL` creates a schema with a random name, returns a connection URL whose `search_path` points at it, and drops the schema when the test ends. `Pool` connects with that URL and applies the migrations, so every test starts from an empty, fully migrated set of tables.

Now run the contract against PostgreSQL. Create `internal/pgstore/pgstore_test.go`:

<!-- file: internal/pgstore/pgstore_test.go -->
~~~go
package pgstore

import (
	"testing"

	"runway/internal/jobs"
	"runway/internal/jobs/jobstest"
	"runway/internal/pgstore/pgtest"
)

func TestContract(t *testing.T) {
	jobstest.Run(t, func(t *testing.T) jobs.Repository {
		return New(pgtest.Pool(t, Migrate))
	})
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/memstore/... ./internal/pgstore/... -->

~~~bash
go test -v -run TestContract ./internal/pgstore/
~~~

~~~text
--- PASS: TestContract (0.64s)
    --- PASS: TestContract/create_assigns_increasing_IDs (0.08s)
    --- PASS: TestContract/get_returns_exactly_what_was_stored (0.07s)
    --- PASS: TestContract/get_unknown_is_ErrNotFound (0.07s)
    --- PASS: TestContract/update_with_the_expected_state_succeeds (0.08s)
    --- PASS: TestContract/update_from_a_stale_state_is_ErrConflict_and_changes_nothing (0.08s)
    --- PASS: TestContract/update_unknown_is_ErrNotFound (0.08s)
    --- PASS: TestContract/concurrent_compare-and-swap_lets_exactly_one_win (0.12s)
    --- PASS: TestContract/a_cancelled_context_is_refused (0.07s)
PASS
ok  	runway/internal/pgstore	0.650s
~~~

Run it again with `RUNWAY_DATABASE_URL` unset and every subtest says `SKIP`. That's why the setup asked you to export it.

The concurrent compare-and-swap test is worth a second look. Twenty goroutines run `UPDATE ... WHERE id = $1 AND state = 'queued'` at once, and exactly one wins. The first `UPDATE` to reach the row **locks** it. The others wait for that lock, then check their `WHERE` clause again against the row as it is *now*, find the state has changed, and match nothing. Step 3 shows exactly when this works and when it doesn't.

### Use it from the API

The API chooses its store the way it chooses its bus: PostgreSQL when `DATABASE_URL` is set, memory otherwise. In `cmd/api/main.go`, add the imports. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"github.com/prometheus/client_golang/prometheus"
~~~

to:

~~~go
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/messages"
	"runway/internal/rabbit"
~~~

to:

~~~go
	"runway/internal/messages"
	"runway/internal/pgstore"
	"runway/internal/rabbit"
~~~

Add the setting. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	AMQPURL          string
	RequestTimeout   time.Duration
~~~

to:

~~~go
	AMQPURL          string
	DatabaseURL      string
	RequestTimeout   time.Duration
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL")}
~~~

to:

~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), DatabaseURL: getenv("DATABASE_URL")}
~~~

Add a function that picks the store, just before `run`. Change:

<!-- edit: cmd/api/main.go -->
~~~go
// run starts the API and its consumers, blocks until ctx is cancelled or the
~~~

to:

~~~go
// connectStore returns the job repository: PostgreSQL when DATABASE_URL is
// set, after bringing its schema up to date, or memory otherwise.
func connectStore(ctx context.Context, cfg config) (jobs.Repository, func(), error) {
	if cfg.DatabaseURL == "" {
		return memstore.New(), func() {}, nil
	}
	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return nil, nil, fmt.Errorf("connect to PostgreSQL: %w", err)
	}
	if err := pgstore.Migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, nil, err
	}
	return pgstore.New(pool), pool.Close, nil
}

// run starts the API and its consumers, blocks until ctx is cancelled or the
~~~

And use it in `run`. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	service := jobs.NewService(memstore.New(), jobs.WithDispatcher(dispatcher))
~~~

to:

~~~go
	repo, closeStore, err := connectStore(ctx, cfg)
	if err != nil {
		return err
	}
	defer closeStore()
	service := jobs.NewService(repo, jobs.WithDispatcher(dispatcher))
~~~

The API migrates the database every time it starts. That's safe because goose skips migrations that are already applied. (Step 5 finds a problem with it anyway.)

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

### Run it

Repeat the restart experiment with `DATABASE_URL` set:

~~~bash
export DATABASE_URL=postgres://runway:runway@localhost:5432/runway
go run ./cmd/api &
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"resize","duration_ms":200}'
kill %1; go run ./cmd/api &
curl -s http://127.0.0.1:8080/jobs/1
~~~

~~~text
{"id":1,"state":"queued","description":"resize","duration_ms":200,"created_at":"2026-10-05T19:27:46.395226Z","updated_at":"2026-10-05T19:27:46.395226Z"}
{"id":1,"state":"completed","description":"resize","duration_ms":200,"created_at":"2026-10-05T19:27:46.395226Z","updated_at":"2026-10-05T19:27:46.612042Z"}
~~~

The job survived the restart, and it completed: the in-process worker finished it before the API stopped. Notice the timestamps now have six decimal places, not nine. That's PostgreSQL's microseconds.

Look at what the database holds:

~~~bash
docker compose exec postgres psql -U runway -c '\dt' -c 'SELECT * FROM jobs' -c 'SELECT version_id, is_applied FROM goose_db_version ORDER BY id'
~~~

~~~text
             List of relations
 Schema |       Name       | Type  | Owner  
--------+------------------+-------+--------
 public | goose_db_version | table | runway
 public | jobs             | table | runway
(2 rows)

 id | description | duration_ms |   state   | failure_reason |          created_at           |          updated_at           
----+-------------+-------------+-----------+----------------+-------------------------------+-------------------------------
  1 | resize      |         200 | completed |                | 2026-10-05 19:27:46.395226+00 | 2026-10-05 19:27:46.612042+00
(1 row)

 version_id | is_applied 
------------+------------
          0 | t
          1 | t
(2 rows)
~~~

`\dt` is a `psql` command that lists tables. `goose_db_version` is goose's record of what it has applied: version 0 is the table's own creation, and version 1 is your migration. Create one more job (`"thumbnail"`) so the next experiment has two rows to find.

**Break it: return the time you sent, not the time stored.** In `Create`, change `RETURNING id, created_at, updated_at` to `RETURNING id`, and `.Scan(&job.ID, &job.CreatedAt, &job.UpdatedAt)` to `.Scan(&job.ID)`. Run the contract:

~~~text
--- FAIL: TestContract (0.08s)
    --- FAIL: TestContract/get_returns_exactly_what_was_stored (0.08s)
        contract.go:53: got {ID:1 Description:resize Duration:250ms State:queued FailureReason: CreatedAt:2026-10-05 12:00:00.123456 +0000 UTC UpdatedAt:2026-10-05 12:00:00.123456 +0000 UTC}, want {ID:1 Description:resize Duration:250ms State:queued FailureReason: CreatedAt:2026-10-05 12:00:00.123456789 +0000 UTC UpdatedAt:2026-10-05 12:00:00.123456789 +0000 UTC}
~~~

`Create` claimed `.123456789`; the database kept `.123456`. A whole class of bugs looks like this: two parts of a system disagree about a value by a rounding step, and an equality check somewhere fails once in a while. The contract caught it only because `t0` has nanoseconds. Restore the code.

**Break it: SQL injection.** Suppose a search feature built its SQL by pasting in what the user typed:

~~~go
query := "SELECT id, description FROM jobs WHERE description = '" + typed + "'"
~~~

If someone types `' OR '1'='1`, the text sent to the database becomes the second query below. Try both in `psql`:

~~~bash
docker compose exec postgres psql -U runway
~~~

~~~sql
SELECT id, description FROM jobs WHERE description = 'resize';
SELECT id, description FROM jobs WHERE description = '' OR '1'='1';
~~~

~~~text
 id | description 
----+-------------
  1 | resize
(1 row)

 id | description 
----+-------------
  1 | resize
  2 | thumbnail
(2 rows)
~~~

The typed text closed the quoted string early and added a condition that's always true, so every row came back. With `DELETE` instead of `SELECT`, it would have deleted every row. Now send the same text as a **parameter**, which is what pgx does with `$1`:

~~~sql
PREPARE find(text) AS SELECT id, description FROM jobs WHERE description = $1;
EXECUTE find('resize');
EXECUTE find(''' OR ''1''=''1');
~~~

~~~text
 id | description 
----+-------------
  1 | resize
(1 row)

 id | description 
----+-------------
(0 rows)
~~~

(Inside an SQL string, `''` is one quote character, so the second `EXECUTE` sends exactly `' OR '1'='1`.) As a parameter, the text is only ever a value: there's no job with that odd description, so no rows. The query's structure was fixed before the value arrived. That's the whole defence, and it's why every query in `pgstore` uses `$1` placeholders.

**Break it: the constraints.** Still in `psql`, try to write data the domain would never allow:

~~~sql
INSERT INTO jobs (description, duration_ms, state, created_at, updated_at) VALUES ('too long', 9000, 'queued', now(), now());
UPDATE jobs SET state = 'paused' WHERE id = 1;
~~~

~~~text
ERROR:  new row for relation "jobs" violates check constraint "jobs_duration_ms_check"
DETAIL:  Failing row contains (3, too long, 9000, queued, , 2026-10-05 19:28:07.999188+00, 2026-10-05 19:28:07.999188+00).
ERROR:  new row for relation "jobs" violates check constraint "jobs_state_check"
DETAIL:  Failing row contains (1, resize, 200, paused, , 2026-10-05 19:27:46.395226+00, 2026-10-05 19:27:46.612042+00).
~~~

The database refused both, whoever sent them: a script, a hurried fix in `psql`, a future service with a bug. Notice the failed insert still used up ID 3. Identity values are handed out before the row is checked and are never given back, so **IDs are increasing, not consecutive**. That's exactly what the contract promises, and no more.

Quit `psql` with `\q`.

**Explain it:** why does `Create` use `RETURNING` for the timestamps? Why can't a value sent as a parameter change a query's meaning? What does a contract test give you that two separate test files don't?

**Read.** The PostgreSQL manual's *Tutorial* (Part I), chapters 2 and 3, and the page on *Constraints* (§5.5). Then DDIA Ch. 2, *Relational Model Versus Document Model*. Carry this question in: which of Runway's rules belong in the domain, which in the database, and which in both?

---

## Step 2: Connection pooling

**The problem.** A database connection is expensive. Opening one takes:
- a TCP handshake;
- an attempted TLS handshake;
- a password exchange;
- on the server, a whole new operating-system **process**: PostgreSQL runs one backend process per connection.

So the server can only hold so many. Find out how many, then go past it. In one terminal, open 110 sessions that each sleep for four seconds:

~~~bash
docker compose exec postgres psql -U runway -Atc 'SHOW max_connections'
for i in $(seq 110); do docker compose exec -T postgres psql -U runway -Atc 'SELECT pg_sleep(4)' & done; wait
~~~

~~~text
100
psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: FATAL:  sorry, too many clients already
psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: FATAL:  sorry, too many clients already
...
~~~

You'll see the error 10 times: 100 sessions got in and 10 were refused. (PostgreSQL normally keeps 3 slots for administrators. The `runway` user the image created *is* a superuser, so it may use those too. Phase 6 replaces it with a user that has only the rights it needs.)

Now picture ten API instances. If each opened a fresh connection per request, a traffic spike would hit this wall, and the next request would fail with a `FATAL`. If each kept 20 connections open "just in case", the ten instances would need 200 between them. The answer is a **pool** in each process, and a size you choose on purpose.

**New ideas.**

- A **connection pool** keeps some connections open and lends them out. A request **acquires** a connection, runs its queries, and **releases** it back, still open, for the next request. pgxpool does this inside every query call, which is why `pgstore` never mentions connections.
- **Max size** is the most connections the pool will open. When all are busy, the next caller **waits** for one to come back. That wait is a queue in your own process, and like every queue it needs a limit. Here the limit is the caller's **context deadline**.
- **Min size**, **max lifetime** and **max idle time** control the rest of a connection's life: how many stay open when idle, when old connections are replaced (to spread load after a database failover, for example), and when unused ones are closed.
- **Sizing.** By Little's law from Phase 2, connections in use = queries per second × seconds per query. At 500 queries a second taking 4 ms each, that's 2 connections on average. Bursts need more, but rarely as many as you'd guess. A database also does *less* total work with too many connections, because they fight over CPU, locks and disk. The total across all instances must stay well under `max_connections`. When it can't, a connection **proxy** such as PgBouncer sits in between and shares a few real connections among many clients.
- **Failing fast at start-up.** `pgxpool.New` doesn't connect: it connects lazily, on first use. So a wrong password would only show up on the first request. A **ping** at start-up makes a misconfigured service fail immediately, before it reports itself as running.

### Open the pool on purpose

Create `internal/pgstore/pool.go`:

<!-- file: internal/pgstore/pool.go -->
~~~go
package pgstore

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
)

// PoolOptions sizes the connection pool. Zero values keep pgx's defaults.
type PoolOptions struct {
	MaxConns        int32         // the most connections open at once
	MinConns        int32         // connections kept open even when idle
	MaxConnLifetime time.Duration // replace connections older than this
	MaxConnIdleTime time.Duration // close connections idle longer than this
}

// Open creates a pool and checks that the database answers, so a wrong
// address or password fails at start-up rather than on the first request.
func Open(ctx context.Context, url string, opts PoolOptions) (*pgxpool.Pool, error) {
	config, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("parse DATABASE_URL: %w", err)
	}
	if opts.MaxConns > 0 {
		config.MaxConns = opts.MaxConns
	}
	if opts.MinConns > 0 {
		config.MinConns = opts.MinConns
	}
	if opts.MaxConnLifetime > 0 {
		config.MaxConnLifetime = opts.MaxConnLifetime
	}
	if opts.MaxConnIdleTime > 0 {
		config.MaxConnIdleTime = opts.MaxConnIdleTime
	}
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, fmt.Errorf("connect to PostgreSQL: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("connect to PostgreSQL: %w", err)
	}
	return pool, nil
}

// PoolCollectors exposes the pool's state as Prometheus metrics: how many
// connections are busy, idle and allowed, and how often and how long
// requests had to wait for one.
func PoolCollectors(pool *pgxpool.Pool) []prometheus.Collector {
	gauge := func(name, help string, value func(*pgxpool.Stat) float64) prometheus.Collector {
		return prometheus.NewGaugeFunc(prometheus.GaugeOpts{Name: name, Help: help},
			func() float64 { return value(pool.Stat()) })
	}
	counter := func(name, help string, value func(*pgxpool.Stat) float64) prometheus.Collector {
		return prometheus.NewCounterFunc(prometheus.CounterOpts{Name: name, Help: help},
			func() float64 { return value(pool.Stat()) })
	}
	return []prometheus.Collector{
		gauge("db_pool_acquired_connections", "Connections in use right now.",
			func(s *pgxpool.Stat) float64 { return float64(s.AcquiredConns()) }),
		gauge("db_pool_idle_connections", "Open connections waiting for work.",
			func(s *pgxpool.Stat) float64 { return float64(s.IdleConns()) }),
		gauge("db_pool_max_connections", "The pool's limit.",
			func(s *pgxpool.Stat) float64 { return float64(s.MaxConns()) }),
		counter("db_pool_waits_total", "Acquires that found no free connection and had to wait.",
			func(s *pgxpool.Stat) float64 { return float64(s.EmptyAcquireCount()) }),
		counter("db_pool_wait_seconds_total", "Total time spent waiting for a free connection.",
			func(s *pgxpool.Stat) float64 { return s.EmptyAcquireWaitTime().Seconds() }),
	}
}
~~~

The metrics read `pool.Stat()` each time Prometheus scrapes, as the queue-depth gauge did in Phase 2. The last two are **counters**: they only ever go up, and Prometheus works out rates from them. `db_pool_waits_total` counts acquires that found no free connection and had to wait (including waiting for a new connection to be opened). `db_pool_wait_seconds_total` adds up how long those waits took.

Prove the waiting happens, and that a deadline ends it. Create `internal/pgstore/pool_test.go`:

<!-- file: internal/pgstore/pool_test.go -->
~~~go
package pgstore

import (
	"context"
	"errors"
	"os"
	"sync"
	"testing"
	"time"
)

// With 2 connections both busy, a third query can't start. It waits for a
// free connection, and gives up when its own deadline passes.
func TestExhaustedPoolMakesCallersWait(t *testing.T) {
	url := os.Getenv("RUNWAY_DATABASE_URL")
	if url == "" {
		t.Skip("set RUNWAY_DATABASE_URL to run PostgreSQL tests")
	}
	ctx := context.Background()
	pool, err := Open(ctx, url, PoolOptions{MaxConns: 2})
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()

	var busy sync.WaitGroup
	for range 2 {
		busy.Add(1)
		go func() {
			defer busy.Done()
			_, _ = pool.Exec(ctx, "SELECT pg_sleep(0.5)")
		}()
	}
	time.Sleep(100 * time.Millisecond) // let both slow queries take a connection

	short, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err = pool.Exec(short, "SELECT 1")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error = %v, want the caller's deadline to expire while waiting", err)
	}
	if waited := time.Since(start); waited < 90*time.Millisecond {
		t.Fatalf("returned after %v; it should have waited for a connection", waited)
	}
	busy.Wait()
	if pool.Stat().EmptyAcquireCount() == 0 {
		t.Fatal("the pool recorded no waits")
	}
}
~~~

`pg_sleep(0.5)` is a query that takes half a second, so two of them hold both connections. The third query waits in the pool, not in the database, and gives up when its own 100 ms deadline passes.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/pgstore/... && go test -race -count=1 ./internal/pgstore/... -->

~~~bash
go test -v -run TestExhausted ./internal/pgstore/
~~~

~~~text
--- PASS: TestExhaustedPoolMakesCallersWait (0.53s)
ok  	runway/internal/pgstore	0.542s
~~~

### Configure it in the API

`connectStore` now opens the pool with `Open` and registers its metrics. In `cmd/api/main.go`, `pgxpool` is no longer used directly. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
~~~

to:

~~~go
	"github.com/prometheus/client_golang/prometheus"
~~~

Add the setting. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	DatabaseURL      string
	RequestTimeout   time.Duration
~~~

to:

~~~go
	DatabaseURL      string
	DBMaxConns       int
	RequestTimeout   time.Duration
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
~~~

to:

~~~go
	if cfg.DBMaxConns, err = envconfig.PositiveInt(getenv, "DB_MAX_CONNS", 10); err != nil {
		return config{}, err
	}
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
~~~

Then replace the start of `connectStore`. Change:

<!-- edit: cmd/api/main.go -->
~~~go
func connectStore(ctx context.Context, cfg config) (jobs.Repository, func(), error) {
	if cfg.DatabaseURL == "" {
		return memstore.New(), func() {}, nil
	}
	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return nil, nil, fmt.Errorf("connect to PostgreSQL: %w", err)
	}
~~~

to:

~~~go
func connectStore(ctx context.Context, cfg config, metrics *httpapi.Metrics) (jobs.Repository, func(), error) {
	if cfg.DatabaseURL == "" {
		return memstore.New(), func() {}, nil
	}
	pool, err := pgstore.Open(ctx, cfg.DatabaseURL, pgstore.PoolOptions{MaxConns: int32(cfg.DBMaxConns)})
	if err != nil {
		return nil, nil, err
	}
	metrics.MustRegister(pgstore.PoolCollectors(pool)...)
~~~

and pass the metrics in. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	repo, closeStore, err := connectStore(ctx, cfg)
~~~

to:

~~~go
	repo, closeStore, err := connectStore(ctx, cfg, metrics)
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

### Run it

Start the API with a pool of 2, send 50 jobs at once, twice, and read the pool's metrics after each burst:

~~~bash
DB_MAX_CONNS=2 go run ./cmd/api &
for i in $(seq 50); do curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"burst","duration_ms":50}' & done; wait
curl -s http://127.0.0.1:8080/metrics | grep '^db_pool'
~~~

Then do the same with `DB_MAX_CONNS=10`. My numbers:

| | Pool of 2 | Pool of 10 |
|---|---|---|
| Burst 1: waits | 52 | 51 |
| Burst 1: total time waiting | 3.46 s | 2.26 s |
| Burst 2: new waits | 50 | 30 |
| Burst 2: new time waiting | 2.93 s | 0.72 s |

~~~text
db_pool_acquired_connections 0
db_pool_idle_connections 10
db_pool_max_connections 10
db_pool_wait_seconds_total 2.983646793
db_pool_waits_total 81
~~~

Read the table carefully, because the first burst misleads. The pool of 10 started with **one** connection (the start-up ping's), so in burst 1 nearly every request waited, mostly for new connections to be **opened**. That cost is the reason pools exist. In burst 2 the ten connections were already open: 30 short waits added up to 0.72 s, against 2.26 s in burst 1. The pool of 2 waited just as much in burst 2 as in burst 1, because two connections were all it would ever have. (`PoolOptions.MinConns` would open connections ahead of time and take away burst 1's penalty.)

Now break the configuration on purpose:

~~~bash
DB_MAX_CONNS=0 go run ./cmd/api
DATABASE_URL=postgres://runway:wrong@localhost:5432/runway go run ./cmd/api
~~~

~~~text
DB_MAX_CONNS must be a positive whole number, got "0"
connect to PostgreSQL: failed to connect to `user=runway database=runway`:
	127.0.0.1:5432 (localhost): tls error: server refused TLS connection
	127.0.0.1:5432 (localhost): failed SASL auth: FATAL: password authentication failed for user "runway" (SQLSTATE 28P01)
~~~

Both fail at once, before the API reports that it's listening. That's the ping in `Open` at work. The `tls error` line is pgx's first attempt: by default it tries an encrypted connection, then falls back to an unencrypted one. The local server doesn't offer TLS; Phase 6 turns it on and makes it required.

**Break it: wait without a deadline.** In `pool_test.go`, give the third query a whole minute: change `context.WithTimeout(ctx, 100*time.Millisecond)` to `context.WithTimeout(ctx, time.Minute)`.

~~~text
--- FAIL: TestExhaustedPoolMakesCallersWait (0.53s)
    pool_test.go:41: error = <nil>, want the caller's deadline to expire while waiting
~~~

The query "succeeded", about 0.4 s later, when a slow query handed back its connection. Nothing in the pool ever says "too busy". **A caller waits as long as its deadline allows.** That's why Phase 1's request timeout matters even more now: it's the only thing stopping a slow database from piling up every request in the pool. Restore the 100 ms.

**Explain it:** why does a database limit its connections? Using Little's law, how many connections does a service need at 300 queries a second of 5 ms each? In burst 1, why did the pool of 10 wait almost as often as the pool of 2?

**Read.** The PostgreSQL manual, §19.3.1 (`max_connections`), and the HikariCP wiki page *About Pool Sizing*. Carry this question in: ten instances of Runway share one database with `max_connections = 100`. What would you set `DB_MAX_CONNS` to, and why?

---

## Step 3: Transactions

**The problem.** A job's current state says where it is, but not how it got there. When a job failed, when did it start? Did it ever run? For a system people will audit, you want the **history**: one row per change. That means each change writes two rows, the job and its history entry, and they must never disagree. If the job says `failed` there must be a `failed` entry, and if there's an entry the job must have made that change.

With two separate statements, a crash, a lost connection or a bug between them leaves one written without the other. You need both writes to succeed or fail **as one**.

The second problem is quieter. Two requests that each *read* a value, compute a new one and *write* it back can overwrite each other's work, and neither of them gets an error. You'll make that happen on purpose too.

**New ideas.**

- A **transaction** groups statements so they act as one unit. `BEGIN` starts one, `COMMIT` makes every change in it permanent at once, and `ROLLBACK` throws all of them away. If the connection drops or the server crashes before `COMMIT`, it's as if none of it happened. The usual summary is **ACID**:
  - **atomic**: all or nothing;
  - **consistent**: the constraints hold at every commit;
  - **isolated**: concurrent transactions don't see each other's half-done work;
  - **durable**: once committed, it survives a crash (step 11 tests that).
- **`pgx.BeginFunc`** runs a function inside a transaction: it commits if the function returns nil and rolls back if it returns an error. You can't forget either.
- A **unit of work** is the set of changes that must commit together. Here that's the job row plus its event row; in step 4 an outgoing message joins them. The repository decides where a transaction starts and ends, so the domain never sees one.
- A **domain event** is a fact about the domain that has already happened: "job 7 entered `failed` at 12:00:02 because the disk was full". It's named in the past tense, and it's never changed afterwards. The **aggregate** (the job, the thing whose rules guard its own state) changes; its events record each change.
- A **data migration** changes existing *rows*, not just the schema. Jobs stored before this step have no history, so the migration writes one event for each, describing its current state.
- **Isolation levels** say how much a transaction can see of others running at the same time. In PostgreSQL every transaction reads from a **snapshot**: a consistent picture of the committed data. Different levels take the snapshot at different times:

  | Level | Snapshot taken | Prevents | Still allows |
  |---|---|---|---|
  | `READ COMMITTED` (the default) | At the start of each **statement** | Dirty reads (seeing uncommitted data) | A **lost update** from read-modify-write; values changing between two reads |
  | `REPEATABLE READ` | At the start of the **transaction** | Lost updates, by refusing the second writer | **Write skew**: two transactions each read, then each write a *different* row, breaking a rule that spans both |
  | `SERIALIZABLE` | Like repeatable read, plus tracking of what each transaction read | Every anomaly: the result equals *some* one-at-a-time order | Nothing, but more transactions are refused and must be retried |

- A **lost update**: two transactions both read `n = 0`, both compute `n + 1`, and both write `1`. Two increments happened, and one vanished without an error. (A *write skew* example: two doctors on call each check "is someone else on call?", see yes, and both go off call.)
- **Row locks.** An `UPDATE` locks the rows it changes until its transaction ends. Another transaction that wants to change the same row waits. `SELECT ... FOR UPDATE` takes the same lock while only reading, to say "I'm going to change this".
- **Serialization failure.** When PostgreSQL refuses a transaction to protect isolation, it reports SQLSTATE **`40001`**. The right response is to retry the *whole* transaction from the beginning.

### Events in the domain

Create `internal/jobs/event.go`:

<!-- file: internal/jobs/event.go -->
~~~go
package jobs

import "time"

// Event is a domain event: a fact about a job that has already happened.
// Every change of state produces one. Storage records it in the same
// transaction as the change, so a job's history can never disagree with
// the job.
type Event struct {
	JobID  ID
	State  State
	Reason string
	At     time.Time
}

// EventFor describes the change that left job in its current state.
func EventFor(job Job) Event {
	return Event{JobID: job.ID, State: job.State, Reason: job.FailureReason, At: job.UpdatedAt}
}
~~~

`EventFor` reads the change straight off the job: its new state, the reason, and when it happened (`UpdatedAt`).

### The history table

Create `internal/pgstore/migrations/0002_job_events.sql`:

<!-- file: internal/pgstore/migrations/0002_job_events.sql -->
~~~sql
-- +goose Up
CREATE TABLE job_events (
    id     BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_id BIGINT      NOT NULL REFERENCES jobs (id),
    state  TEXT        NOT NULL,
    reason TEXT        NOT NULL DEFAULT '',
    at     TIMESTAMPTZ NOT NULL
);
CREATE INDEX job_events_job_id ON job_events (job_id, id);

-- Jobs stored before this migration get one event for their current state,
-- so every job has a history.
INSERT INTO job_events (job_id, state, reason, at)
SELECT id, state, failure_reason, updated_at FROM jobs ORDER BY id;

-- +goose Down
DROP TABLE job_events;
~~~

- `REFERENCES jobs (id)` is a **foreign key**: an event must belong to a job that exists. The database enforces it like any other constraint.
- The **index** on `(job_id, id)` makes "the events of job 7, in order" fast. Step 8 explains indexes properly.
- The `INSERT ... SELECT` is the data migration. It runs once, in the same migration that creates the table, so there is never a moment when old jobs have no history.

### Write the change and its event together

In `internal/pgstore/pgstore.go`, replace `Create`. Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
func (s *Store) Create(ctx context.Context, job jobs.Job) (jobs.Job, error) {
	err := s.pool.QueryRow(ctx, `
		INSERT INTO jobs (description, duration_ms, state, failure_reason, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING id, created_at, updated_at`,
		job.Description, job.Duration.Milliseconds(), job.State, job.FailureReason, job.CreatedAt, job.UpdatedAt,
	).Scan(&job.ID, &job.CreatedAt, &job.UpdatedAt)
	if err != nil {
~~~

to:

~~~go
// Create stores the job and its first event in one transaction: both rows
// are written, or neither is.
func (s *Store) Create(ctx context.Context, job jobs.Job) (jobs.Job, error) {
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `
			INSERT INTO jobs (description, duration_ms, state, failure_reason, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6)
			RETURNING id, created_at, updated_at`,
			job.Description, job.Duration.Milliseconds(), job.State, job.FailureReason, job.CreatedAt, job.UpdatedAt,
		).Scan(&job.ID, &job.CreatedAt, &job.UpdatedAt)
		if err != nil {
			return err
		}
		return s.record(ctx, tx, job)
	})
	if err != nil {
~~~

Every statement inside the function goes through `tx`, the transaction, not `s.pool`. That's the whole trick, and the "Break it" below shows what happens when one statement slips out.

Now replace `Update`, and add the helpers after it. Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
// Update is compare-and-swap in SQL: the WHERE clause checks the expected
// state and the write happens in one statement, so two updates can't both
// succeed from the same starting state.
func (s *Store) Update(ctx context.Context, job jobs.Job, expected jobs.State) error {
	tag, err := s.pool.Exec(ctx, `
		UPDATE jobs SET state = $2, failure_reason = $3, updated_at = $4
		WHERE id = $1 AND state = $5`,
		job.ID, job.State, job.FailureReason, job.UpdatedAt, expected)
	if err != nil {
		return fmt.Errorf("update job %d: %w", job.ID, err)
	}
	if tag.RowsAffected() == 1 {
		return nil
	}
	// No row matched: the job is missing, or its state has moved on.
	var exists bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM jobs WHERE id = $1)`, job.ID).Scan(&exists); err != nil {
		return fmt.Errorf("update job %d: %w", job.ID, err)
	}
	if !exists {
		return jobs.ErrNotFound
	}
	return jobs.ErrConflict
}
~~~

to:

~~~go
// Update is compare-and-swap in SQL: the WHERE clause checks the expected
// state and the write happens in one statement, so two updates can't both
// succeed from the same starting state. The change and its event commit
// together.
func (s *Store) Update(ctx context.Context, job jobs.Job, expected jobs.State) error {
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE jobs SET state = $2, failure_reason = $3, updated_at = $4
			WHERE id = $1 AND state = $5`,
			job.ID, job.State, job.FailureReason, job.UpdatedAt, expected)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return notUpdated(ctx, tx, job.ID)
		}
		return s.record(ctx, tx, job)
	})
	if err != nil && !errors.Is(err, jobs.ErrNotFound) && !errors.Is(err, jobs.ErrConflict) {
		return fmt.Errorf("update job %d: %w", job.ID, err)
	}
	return err
}

// notUpdated explains why an update matched no row: the job is missing, or
// its state has moved on.
func notUpdated(ctx context.Context, tx pgx.Tx, id jobs.ID) error {
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM jobs WHERE id = $1)`, id).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return jobs.ErrNotFound
	}
	return jobs.ErrConflict
}

// record writes the event for the job's latest change, inside tx.
func (s *Store) record(ctx context.Context, tx pgx.Tx, job jobs.Job) error {
	event := jobs.EventFor(job)
	_, err := tx.Exec(ctx, `
		INSERT INTO job_events (job_id, state, reason, at) VALUES ($1, $2, $3, $4)`,
		event.JobID, event.State, event.Reason, event.At)
	return err
}

// History returns a job's events, oldest first.
func (s *Store) History(ctx context.Context, id jobs.ID) ([]jobs.Event, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT job_id, state, reason, at FROM job_events WHERE job_id = $1 ORDER BY id`, id)
	if err != nil {
		return nil, fmt.Errorf("history of job %d: %w", id, err)
	}
	events, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (jobs.Event, error) {
		var e jobs.Event
		err := row.Scan(&e.JobID, &e.State, &e.Reason, &e.At)
		e.At = e.At.UTC()
		return e, err
	})
	if err != nil {
		return nil, fmt.Errorf("history of job %d: %w", id, err)
	}
	return events, nil
}
~~~

A compare-and-swap that loses returns `ErrConflict` from inside the function, so `BeginFunc` rolls back: no event is written for a change that didn't happen. The domain errors pass through unwrapped, exactly as the contract expects.

`History` isn't part of the `Repository` port: nothing in the domain needs it yet. It's here so tests (and you, in `psql`) can check the history.

### Test the history and the atomicity

In `internal/pgstore/pgstore_test.go`, add imports. Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
import (
	"testing"
~~~

to:

~~~go
import (
	"context"
	"slices"
	"testing"
	"time"
~~~

and add at the end:

<!-- append: internal/pgstore/pgstore_test.go -->
~~~go
var t0 = time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)

func TestHistoryRecordsEveryChange(t *testing.T) {
	ctx := context.Background()
	store := New(pgtest.Pool(t, Migrate))
	job, _ := jobs.New("resize", time.Second, t0)
	job, err := store.Create(ctx, job)
	if err != nil {
		t.Fatal(err)
	}
	_ = job.Start(t0.Add(time.Second))
	if err := store.Update(ctx, job, jobs.StateQueued); err != nil {
		t.Fatal(err)
	}
	_ = job.Fail("disk full", t0.Add(2*time.Second))
	if err := store.Update(ctx, job, jobs.StateRunning); err != nil {
		t.Fatal(err)
	}

	got, err := store.History(ctx, job.ID)
	if err != nil {
		t.Fatal(err)
	}
	want := []jobs.Event{
		{JobID: job.ID, State: jobs.StateQueued, At: t0},
		{JobID: job.ID, State: jobs.StateRunning, At: t0.Add(time.Second)},
		{JobID: job.ID, State: jobs.StateFailed, Reason: "disk full", At: t0.Add(2 * time.Second)},
	}
	if !slices.Equal(got, want) {
		t.Fatalf("history:\n got %v\nwant %v", got, want)
	}
}

// If the event can't be written, the change it describes mustn't be either.
func TestChangeAndEventCommitTogether(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.Pool(t, Migrate)
	store := New(pool)
	job, _ := jobs.New("resize", time.Second, t0)
	job, err := store.Create(ctx, job)
	if err != nil {
		t.Fatal(err)
	}

	// From now on, every new event is refused, as a full disk or a bug might.
	if _, err := pool.Exec(ctx, `ALTER TABLE job_events ADD CONSTRAINT refuse_all CHECK (false) NOT VALID`); err != nil {
		t.Fatal(err)
	}

	started := job
	_ = started.Start(t0.Add(time.Second))
	if err := store.Update(ctx, started, jobs.StateQueued); err == nil {
		t.Fatal("update succeeded although its event was refused")
	}
	if got, _ := store.Get(ctx, job.ID); got.State != jobs.StateQueued {
		t.Fatalf("state = %s: the change committed without its event", got.State)
	}

	if _, err := store.Create(ctx, job); err == nil {
		t.Fatal("create succeeded although its event was refused")
	}
	var count int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM jobs`).Scan(&count)
	if count != 1 {
		t.Fatalf("%d jobs stored, want 1: a job was stored without its event", count)
	}
}
~~~

The second test needs a write that fails *inside* the transaction, after the job's own write succeeded. A constraint that refuses everything does it: `CHECK (false)` can never pass, and `NOT VALID` skips checking the rows already there. It stands in for a full disk, a bug or a lost connection, which you can't easily produce on demand.

### See an anomaly, and three fixes

These tests are **learning tests**. They don't test Runway; they pin down what PostgreSQL itself does, so you can watch an anomaly happen and then see each fix. Each one runs two transactions, `a` and `b`, step by step in a fixed order, so the result is the same every time. Create `internal/pgstore/isolation_test.go`:

<!-- file: internal/pgstore/isolation_test.go -->
~~~go
package pgstore

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"runway/internal/pgstore/pgtest"
)

// These tests don't test Runway. They pin down what PostgreSQL does when two
// transactions read and then write the same row: a counter that two
// clients each increment once, so the right answer is always 2.

func counterPool(t *testing.T) *pgxpool.Pool {
	return pgtest.Pool(t, func(ctx context.Context, pool *pgxpool.Pool) error {
		_, err := pool.Exec(ctx, `CREATE TABLE counter (n INT NOT NULL); INSERT INTO counter VALUES (0)`)
		return err
	})
}

func begin(t *testing.T, pool *pgxpool.Pool, level pgx.TxIsoLevel) pgx.Tx {
	t.Helper()
	tx, err := pool.BeginTx(context.Background(), pgx.TxOptions{IsoLevel: level})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
	return tx
}

func read(t *testing.T, tx pgx.Tx, query string) int {
	t.Helper()
	var n int
	if err := tx.QueryRow(context.Background(), query).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func write(tx pgx.Tx, n int) error {
	_, err := tx.Exec(context.Background(), `UPDATE counter SET n = $1`, n)
	return err
}

func commit(t *testing.T, tx pgx.Tx) {
	t.Helper()
	if err := tx.Commit(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func final(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(context.Background(), `SELECT n FROM counter`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// The anomaly: both read 0, both write 1. One increment is lost, and
// neither client gets an error.
func TestReadCommittedLosesAnUpdate(t *testing.T) {
	pool := counterPool(t)
	a := begin(t, pool, pgx.ReadCommitted)
	b := begin(t, pool, pgx.ReadCommitted)

	na := read(t, a, `SELECT n FROM counter`)
	nb := read(t, b, `SELECT n FROM counter`)
	if err := write(a, na+1); err != nil {
		t.Fatal(err)
	}
	commit(t, a)
	if err := write(b, nb+1); err != nil {
		t.Fatal(err)
	}
	commit(t, b)

	if got := final(t, pool); got != 1 {
		t.Fatalf("n = %d; expected the lost update to leave 1", got)
	}
}

// Fix 1: under REPEATABLE READ, PostgreSQL notices that b is about to
// overwrite a change it never saw, and refuses. b must retry from the start.
func TestRepeatableReadRefusesTheLostUpdate(t *testing.T) {
	pool := counterPool(t)
	a := begin(t, pool, pgx.RepeatableRead)
	b := begin(t, pool, pgx.RepeatableRead)

	na := read(t, a, `SELECT n FROM counter`)
	nb := read(t, b, `SELECT n FROM counter`)
	if err := write(a, na+1); err != nil {
		t.Fatal(err)
	}
	commit(t, a)

	err := write(b, nb+1)
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "40001" {
		t.Fatalf("error = %v; want serialization_failure (40001)", err)
	}
	t.Logf("b was refused: %s", pgErr.Message)
}

// Fix 2: SELECT ... FOR UPDATE locks the row, so b's read waits until a
// commits, and then sees a's write.
func TestSelectForUpdateMakesTheSecondReaderWait(t *testing.T) {
	pool := counterPool(t)
	a := begin(t, pool, pgx.ReadCommitted)
	b := begin(t, pool, pgx.ReadCommitted)

	na := read(t, a, `SELECT n FROM counter FOR UPDATE`)
	bRead := make(chan int)
	go func() {
		var n int
		_ = b.QueryRow(context.Background(), `SELECT n FROM counter FOR UPDATE`).Scan(&n)
		bRead <- n
	}()
	select {
	case <-bRead:
		t.Fatal("b read the row while a held its lock")
	case <-time.After(100 * time.Millisecond):
		// b is waiting, as it should be.
	}
	if err := write(a, na+1); err != nil {
		t.Fatal(err)
	}
	commit(t, a)

	nb := <-bRead
	if err := write(b, nb+1); err != nil {
		t.Fatal(err)
	}
	commit(t, b)
	if got := final(t, pool); got != 2 {
		t.Fatalf("n = %d, want 2", got)
	}
}

// Fix 3: don't read at all. One UPDATE reads and writes the row under its
// lock. Runway's compare-and-swap works the same way.
func TestAtomicUpdateNeedsNoRead(t *testing.T) {
	pool := counterPool(t)
	a := begin(t, pool, pgx.ReadCommitted)
	b := begin(t, pool, pgx.ReadCommitted)

	if _, err := a.Exec(context.Background(), `UPDATE counter SET n = n + 1`); err != nil {
		t.Fatal(err)
	}
	bDone := make(chan error)
	go func() {
		_, err := b.Exec(context.Background(), `UPDATE counter SET n = n + 1`)
		bDone <- err
	}()
	time.Sleep(100 * time.Millisecond) // b is now waiting for a's row lock
	commit(t, a)
	if err := <-bDone; err != nil {
		t.Fatal(err)
	}
	commit(t, b)
	if got := final(t, pool); got != 2 {
		t.Fatalf("n = %d, want 2", got)
	}
}
~~~

The timeline of the first test:

| | Transaction `a` | Transaction `b` | `counter.n` |
|---|---|---|---|
| 1 | reads 0 | | 0 |
| 2 | | reads 0 | 0 |
| 3 | writes 1, commits | | 1 |
| 4 | | writes 1 (0 + 1), commits | **1** |

Two increments, one result, no error. That's why the test *expects* 1. And it's why Runway's `Update` never reads first and writes later: its `WHERE state = $5` makes the read and the write **one statement**, just like fix 3.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

~~~bash
go test -v -run 'Read|Select|Atomic|History|CommitTogether' ./internal/pgstore/
~~~

~~~text
--- PASS: TestReadCommittedLosesAnUpdate (0.08s)
    isolation_test.go:109: b was refused: could not serialize access due to concurrent update
--- PASS: TestRepeatableReadRefusesTheLostUpdate (0.08s)
--- PASS: TestSelectForUpdateMakesTheSecondReaderWait (0.18s)
--- PASS: TestAtomicUpdateNeedsNoRead (0.18s)
--- PASS: TestHistoryRecordsEveryChange (0.10s)
--- PASS: TestChangeAndEventCommitTogether (0.10s)
ok  	runway/internal/pgstore	0.731s
~~~

(`t.Logf` lines appear with `-v`; the log line belongs to the test listed just *after* it.)

| Fix | How it works | What it costs |
|---|---|---|
| `REPEATABLE READ` | `b`'s snapshot predates `a`'s commit, so `b` may not overwrite what it never saw: error `40001` | The caller must retry the whole transaction |
| `SELECT ... FOR UPDATE` | `b`'s read waits for `a`'s lock, then sees `a`'s write | Transactions queue up behind the lock |
| One atomic `UPDATE` | No separate read, so nothing can go stale | Works only when the new value can be computed in SQL |

### Run it

Restart the API (it applies migration 2 on start-up), create a job, and look at its history:

~~~bash
go run ./cmd/api &
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"history","duration_ms":300}'
docker compose exec postgres psql -U runway \
  -c "SELECT (SELECT count(*) FROM jobs) AS jobs, (SELECT count(*) FROM job_events) AS events" \
  -c "SELECT job_id, state, reason, at FROM job_events WHERE job_id = (SELECT max(id) FROM jobs) ORDER BY id"
~~~

~~~text
 jobs | events 
------+--------
  203 |    205
(1 row)

 job_id |   state   | reason |              at               
--------+-----------+--------+-------------------------------
    204 | queued    |        | 2026-10-05 19:31:32.939151+00
    204 | running   |        | 2026-10-05 19:31:32.948827+00
    204 | completed |        | 2026-10-05 19:31:33.249401+00
(3 rows)
~~~

Your numbers will differ. Mine: 202 old jobs got one backfilled event each, and the new job wrote three, so 205 events for 203 jobs. (The job is 204, not 203: remember the ID used up by the refused insert in step 1.)

**Break it: one statement outside the transaction.** In `Update`, change `tag, err := tx.Exec(ctx, ` to `tag, err := s.pool.Exec(ctx, `. The `UPDATE` now runs on a different connection, outside the transaction, and commits on its own the moment it finishes.

~~~text
--- FAIL: TestChangeAndEventCommitTogether (0.12s)
    pgstore_test.go:75: state = running: the change committed without its event
~~~

The event was refused and the transaction rolled back, but the change had already committed elsewhere. It compiles, it looks almost identical, and every other test still passes. Code review rarely catches this; a test like this one does. Restore `tx`.

**Explain it:** what does each letter of ACID promise, and which did the "Break it" violate? Draw the lost-update timeline, and say how each of the three fixes changes it. Why is Runway's `Update` safe under `READ COMMITTED`?

**Read.** DDIA Ch. 7, *Transactions*: the sections on weak isolation levels (read committed, snapshot isolation, lost updates, write skew). Then the PostgreSQL manual, Ch. 13, *Concurrency Control*, §13.2. Carry this question in: which anomalies can still happen in Runway, and does any of them matter?

---

## Step 4: The transactional outbox

**The problem.** Read `Service.Create` again. It stores the job, *then* publishes the `RunJob` command: two systems, two writes. Phase 2's comment admits what that means. If the publish fails, `Create` marks the job failed, which is clumsy but honest. If the **process dies between the two**, the job is stored as `queued` and its command was never sent. Nothing will ever run it, and nothing will notice.

This is the **dual-write problem**. A transaction can't solve it on its own, because RabbitMQ isn't part of PostgreSQL's transaction. Whichever order you choose, a crash in between leaves one write without the other:

| Order | Crash in between leaves |
|---|---|
| Store, then publish | A job that never runs |
| Publish, then store | A worker running a job that doesn't exist |

**New ideas.**

- The **transactional outbox**: don't send the message during the request. Instead, write it as a row in an `outbox` table, **in the same transaction** as the job. Now the job and "a message must be sent" commit together, or not at all. A separate **relay** loop reads unsent rows, publishes them, and marks them sent.
- If the relay crashes after publishing but before marking, it publishes again after restarting. So the outbox gives **at-least-once** delivery, never "at most once". That's fine because Phase 2 already made every receiver idempotent: a duplicate `RunJob` is harmless.
- **Polling** means the relay asks "anything new?" every so often (`OUTBOX_INTERVAL`, 100 ms by default). That adds up to one interval of latency to each job. The alternatives are PostgreSQL's `LISTEN/NOTIFY` (a wake-up signal) or **change data capture**, which tails the database's own write-ahead log (Debezium does this). Polling is the simplest, and it's what many production systems run.
- **`FOR UPDATE SKIP LOCKED`** lets several relays (one per API instance) share the outbox. Each locks the rows it takes, and the others **skip** locked rows instead of waiting for them. So the batches never overlap, and nobody waits.
- A **partial index** indexes only the rows that match a condition: here, unsent messages. The relay's query stays fast however many sent messages pile up. (Step 8 explains indexes and deletes the old rows.)

### The outbox table

Create `internal/pgstore/migrations/0003_outbox.sql`:

<!-- file: internal/pgstore/migrations/0003_outbox.sql -->
~~~sql
-- +goose Up
CREATE TABLE outbox (
    id           BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    destination  TEXT        NOT NULL,
    key          TEXT        NOT NULL DEFAULT '',
    envelope     JSONB       NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at TIMESTAMPTZ
);

-- The relay only ever looks for unpublished messages. A partial index holds
-- just those rows, so it stays small however long the table grows.
CREATE INDEX outbox_pending ON outbox (id) WHERE published_at IS NULL;

-- +goose Down
DROP TABLE outbox;
~~~

`JSONB` stores the envelope as structured JSON, which you can query in `psql`, as you'll see. (It also reorders keys and drops whitespace. That's harmless, because the envelope is read back as JSON, never compared byte for byte.)

### The outbox and its relay

Create `internal/outbox/outbox.go`:

<!-- file: internal/outbox/outbox.go -->
~~~go
// Package outbox delivers messages that were saved in the same database
// transaction as the change that caused them. Saving the change and sending
// the message can't be one atomic step, because the broker isn't part of
// the database's transaction. So the message is saved first, as a row, and
// a relay sends it afterwards. If the process crashes in between, the row
// is still there and the relay sends it on the next pass.
//
// Delivery is at least once: the relay can crash after sending a message
// and before marking it sent, and then sends it again. Receivers must be
// idempotent, which Runway's already are.
package outbox

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"runway/internal/messages"
)

// Message is one message waiting to be sent.
type Message struct {
	Destination string // the queue or topic to send it to
	Key         string // messages with the same key stay in order, where the broker supports it
	Envelope    messages.Envelope
}

// Write saves msgs inside tx. They are sent only if tx commits.
func Write(ctx context.Context, tx pgx.Tx, msgs ...Message) error {
	for _, msg := range msgs {
		envelope, err := json.Marshal(msg.Envelope)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO outbox (destination, key, envelope) VALUES ($1, $2, $3)`,
			msg.Destination, msg.Key, envelope); err != nil {
			return fmt.Errorf("write to outbox: %w", err)
		}
	}
	return nil
}

// Publisher sends one message to its destination.
type Publisher interface {
	Publish(ctx context.Context, msg Message) error
}

// PublisherFunc lets an ordinary function be a Publisher.
type PublisherFunc func(ctx context.Context, msg Message) error

func (f PublisherFunc) Publish(ctx context.Context, msg Message) error { return f(ctx, msg) }

// Relay sends saved messages and marks them sent.
type Relay struct {
	pool      *pgxpool.Pool
	publisher Publisher
	batchSize int
	interval  time.Duration
	logger    *slog.Logger
}

func NewRelay(pool *pgxpool.Pool, publisher Publisher, batchSize int, interval time.Duration, logger *slog.Logger) *Relay {
	return &Relay{pool: pool, publisher: publisher, batchSize: batchSize, interval: interval, logger: logger}
}

// RelayOnce sends up to one batch of messages, oldest first, and reports how
// many it sent. It stops at the first failure: the messages it already sent
// are marked, the rest stay for the next pass.
//
// FOR UPDATE SKIP LOCKED locks the rows this relay takes and skips rows
// another relay has locked, so several relays never send the same batch.
func (r *Relay) RelayOnce(ctx context.Context) (int, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(context.WithoutCancel(ctx))

	rows, err := tx.Query(ctx, `
		SELECT id, destination, key, envelope FROM outbox
		WHERE published_at IS NULL
		ORDER BY id
		LIMIT $1
		FOR UPDATE SKIP LOCKED`, r.batchSize)
	if err != nil {
		return 0, err
	}
	type pending struct {
		id  int64
		msg Message
	}
	batch, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (pending, error) {
		var p pending
		var envelope []byte
		if err := row.Scan(&p.id, &p.msg.Destination, &p.msg.Key, &envelope); err != nil {
			return p, err
		}
		return p, json.Unmarshal(envelope, &p.msg.Envelope)
	})
	if err != nil {
		return 0, err
	}

	var sent []int64
	var publishErr error
	for _, p := range batch {
		if publishErr = r.publisher.Publish(ctx, p.msg); publishErr != nil {
			break
		}
		sent = append(sent, p.id)
	}
	if len(sent) > 0 {
		if _, err := tx.Exec(ctx, `UPDATE outbox SET published_at = now() WHERE id = ANY($1)`, sent); err != nil {
			return 0, err
		}
		if err := tx.Commit(ctx); err != nil {
			return 0, err
		}
	}
	if publishErr != nil {
		return len(sent), fmt.Errorf("publish outbox message: %w", publishErr)
	}
	return len(sent), nil
}

// Run relays until ctx is done. After a full batch it goes again at once;
// otherwise it waits for interval before looking again.
func (r *Relay) Run(ctx context.Context) {
	for {
		sent, err := r.RelayOnce(ctx)
		if err != nil && ctx.Err() == nil {
			r.logger.Warn("outbox relay failed; will retry", "error", err)
		}
		if err == nil && sent == r.batchSize {
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(r.interval):
		}
	}
}

// Pending counts messages not yet sent. A number that keeps growing means
// the broker is unreachable.
func Pending(ctx context.Context, pool *pgxpool.Pool) (int, error) {
	var n int
	err := pool.QueryRow(ctx, `SELECT count(*) FROM outbox WHERE published_at IS NULL`).Scan(&n)
	return n, err
}
~~~

Follow `RelayOnce`:
1. It begins a transaction and locks up to one batch of unsent rows, oldest first.
2. It publishes each one, in order.
3. It marks the ones it sent, then commits, which releases the locks.

If publishing fails halfway, it marks only what it sent. The rest stay unsent, in order, for the next pass. `defer tx.Rollback(...)` covers every early return; after a successful commit it does nothing.

`Run` goes straight back for more after a full batch, so a backlog drains quickly; otherwise it waits one interval. `PublisherFunc` lets a plain function satisfy `Publisher`, as `http.HandlerFunc` does for handlers.

Test it against a real database. The tests reuse `pgstore.Migrate` for the schema, so this file lives in package `outbox_test`, an **external test package**. That way `outbox` itself doesn't import `pgstore` (which is about to import `outbox`). Create `internal/outbox/outbox_test.go`:

<!-- file: internal/outbox/outbox_test.go -->
~~~go
package outbox_test

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"runway/internal/messages"
	"runway/internal/outbox"
	"runway/internal/pgstore"
	"runway/internal/pgstore/pgtest"
)

// save writes n messages, numbered from first, in one transaction.
func save(t *testing.T, pool *pgxpool.Pool, first, n int) {
	t.Helper()
	ctx := context.Background()
	err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		for i := first; i < first+n; i++ {
			env := messages.Envelope{ID: fmt.Sprint(i), Type: "test", Version: 1, Payload: []byte(`{}`)}
			if err := outbox.Write(ctx, tx, outbox.Message{Destination: "q", Envelope: env}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// recorder is a Publisher that remembers what it sent. It fails on the
// message whose ID is failOn, and takes delay per message.
type recorder struct {
	mu     sync.Mutex
	sent   []string
	failOn string
	delay  time.Duration
}

func (r *recorder) Publish(ctx context.Context, msg outbox.Message) error {
	time.Sleep(r.delay)
	r.mu.Lock()
	defer r.mu.Unlock()
	if msg.Envelope.ID == r.failOn {
		return errors.New("broker unreachable")
	}
	r.sent = append(r.sent, msg.Envelope.ID)
	return nil
}

func newRelay(pool *pgxpool.Pool, p outbox.Publisher, batch int) *outbox.Relay {
	return outbox.NewRelay(pool, p, batch, 10*time.Millisecond, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func TestRelaySendsInOrderAndOnlyOnce(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.Pool(t, pgstore.Migrate)
	save(t, pool, 1, 3)
	pub := &recorder{}
	relay := newRelay(pool, pub, 10)

	if n, err := relay.RelayOnce(ctx); n != 3 || err != nil {
		t.Fatalf("first pass sent %d, %v; want 3, nil", n, err)
	}
	if n, err := relay.RelayOnce(ctx); n != 0 || err != nil {
		t.Fatalf("second pass sent %d, %v; want 0, nil", n, err)
	}
	if fmt.Sprint(pub.sent) != "[1 2 3]" {
		t.Fatalf("sent %v, want [1 2 3]", pub.sent)
	}
}

func TestRelayKeepsWhatItCouldNotSend(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.Pool(t, pgstore.Migrate)
	save(t, pool, 1, 3)

	broken := &recorder{failOn: "2"}
	n, err := newRelay(pool, broken, 10).RelayOnce(ctx)
	if n != 1 || err == nil {
		t.Fatalf("sent %d, %v; want 1 and an error", n, err)
	}
	if pending, _ := outbox.Pending(ctx, pool); pending != 2 {
		t.Fatalf("%d pending, want 2", pending)
	}

	fixed := &recorder{}
	if _, err := newRelay(pool, fixed, 10).RelayOnce(ctx); err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(fixed.sent) != "[2 3]" {
		t.Fatalf("after recovery sent %v, want [2 3]", fixed.sent)
	}
}

// Two relays running at once must split the work, not repeat it.
func TestConcurrentRelaysNeverSendTheSameMessage(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.Pool(t, pgstore.Migrate)
	save(t, pool, 1, 40)
	pub := &recorder{delay: 5 * time.Millisecond}

	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			relay := newRelay(pool, pub, 5)
			for {
				n, err := relay.RelayOnce(ctx)
				if err != nil {
					t.Error(err)
					return
				}
				if n == 0 {
					return
				}
			}
		}()
	}
	wg.Wait()

	seen := map[string]int{}
	for _, id := range pub.sent {
		seen[id]++
	}
	for id, count := range seen {
		if count > 1 {
			t.Errorf("message %s sent %d times", id, count)
		}
	}
	if len(seen) != 40 {
		t.Fatalf("%d distinct messages sent, want 40", len(seen))
	}
}
~~~

The third test runs two relays at once over 40 messages, with a slow publisher. That gives them plenty of time to collide, if they could.

### The store writes messages with each change

The store needs to know which messages a change must send, but that's not a storage decision: the composition root decides it and hands it in. In `internal/pgstore/pgstore.go`, add the import. Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	"runway/internal/jobs"
)
~~~

to:

~~~go
	"runway/internal/jobs"
	"runway/internal/outbox"
)
~~~

Give `Store` an option. Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
// Store implements jobs.Repository on a pool of PostgreSQL connections.
type Store struct {
	pool *pgxpool.Pool
}

func New(pool *pgxpool.Pool) *Store {
	return &Store{pool: pool}
}
~~~

to:

~~~go
// Store implements jobs.Repository on a pool of PostgreSQL connections.
type Store struct {
	pool     *pgxpool.Pool
	messages func(jobs.Job) ([]outbox.Message, error)
}

// Option changes one setting of a Store.
type Option func(*Store)

// WithOutbox makes every change also save the messages that messagesFor
// returns, in the same transaction, for the outbox relay to send.
func WithOutbox(messagesFor func(jobs.Job) ([]outbox.Message, error)) Option {
	return func(s *Store) { s.messages = messagesFor }
}

func New(pool *pgxpool.Pool, opts ...Option) *Store {
	s := &Store{pool: pool}
	for _, opt := range opts {
		opt(s)
	}
	return s
}
~~~

Then `record`, which already runs inside every change's transaction, saves the messages too. Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
// record writes the event for the job's latest change, inside tx.
func (s *Store) record(ctx context.Context, tx pgx.Tx, job jobs.Job) error {
	event := jobs.EventFor(job)
	_, err := tx.Exec(ctx, `
		INSERT INTO job_events (job_id, state, reason, at) VALUES ($1, $2, $3, $4)`,
		event.JobID, event.State, event.Reason, event.At)
	return err
}
~~~

to:

~~~go
// record writes the event for the job's latest change, and any outbox
// messages, inside tx.
func (s *Store) record(ctx context.Context, tx pgx.Tx, job jobs.Job) error {
	event := jobs.EventFor(job)
	if _, err := tx.Exec(ctx, `
		INSERT INTO job_events (job_id, state, reason, at) VALUES ($1, $2, $3, $4)`,
		event.JobID, event.State, event.Reason, event.At); err != nil {
		return err
	}
	if s.messages == nil {
		return nil
	}
	msgs, err := s.messages(job)
	if err != nil {
		return err
	}
	return outbox.Write(ctx, tx, msgs...)
}
~~~

Test that a job can't be stored without its message. In `internal/pgstore/pgstore_test.go`, change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	"context"
	"slices"
~~~

to:

~~~go
	"context"
	"fmt"
	"slices"
~~~

and:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	"runway/internal/jobs/jobstest"
	"runway/internal/pgstore/pgtest"
~~~

to:

~~~go
	"runway/internal/jobs/jobstest"
	"runway/internal/messages"
	"runway/internal/outbox"
	"runway/internal/pgstore/pgtest"
~~~

and add at the end:

<!-- append: internal/pgstore/pgstore_test.go -->
~~~go
// A new job and its outbox message commit together.
func TestCreateSavesOutboxMessages(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.Pool(t, Migrate)
	store := New(pool, WithOutbox(func(job jobs.Job) ([]outbox.Message, error) {
		env := messages.Envelope{ID: fmt.Sprint("run-", job.ID), Type: "test", Version: 1, Payload: []byte(`{}`)}
		return []outbox.Message{{Destination: "commands", Envelope: env}}, nil
	}))
	job, _ := jobs.New("resize", time.Second, t0)
	if _, err := store.Create(ctx, job); err != nil {
		t.Fatal(err)
	}
	if pending, _ := outbox.Pending(ctx, pool); pending != 1 {
		t.Fatalf("%d messages pending, want 1", pending)
	}

	if _, err := pool.Exec(ctx, `ALTER TABLE outbox ADD CONSTRAINT refuse_all CHECK (false) NOT VALID`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Create(ctx, job); err == nil {
		t.Fatal("create succeeded although its message was refused")
	}
	var count int
	_ = pool.QueryRow(ctx, `SELECT count(*) FROM jobs`).Scan(&count)
	if count != 1 {
		t.Fatalf("%d jobs stored, want 1: a job was stored without its message", count)
	}
}
~~~

### Decide what a change sends

`eventing` already builds the `RunJob` command for the dispatcher. Share that code with the outbox. In `internal/eventing/eventing.go`, add the import. Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
	"runway/internal/messages"
)
~~~

to:

~~~go
	"runway/internal/messages"
	"runway/internal/outbox"
)
~~~

and change `Dispatch`:

<!-- edit: internal/eventing/eventing.go -->
~~~go
func (d *Dispatcher) Dispatch(ctx context.Context, job jobs.Job) error {
	msg, err := messages.New(messages.TypeRunJob, messages.RunJob{
		JobID:       int64(job.ID),
		Description: string(job.Description),
		DurationMS:  job.Duration.Milliseconds(),
		MaxAttempts: messages.DefaultMaxAttempts,
	}, d.now())
	if err != nil {
		return err
	}
	return d.commands.Publish(ctx, messages.CommandsQueue, msg)
}
~~~

to:

~~~go
func (d *Dispatcher) Dispatch(ctx context.Context, job jobs.Job) error {
	msg, err := runJob(job, d.now())
	if err != nil {
		return err
	}
	return d.commands.Publish(ctx, messages.CommandsQueue, msg)
}

func runJob(job jobs.Job, now time.Time) (messages.Envelope, error) {
	return messages.New(messages.TypeRunJob, messages.RunJob{
		JobID:       int64(job.ID),
		Description: string(job.Description),
		DurationMS:  job.Duration.Milliseconds(),
		MaxAttempts: messages.DefaultMaxAttempts,
	}, now)
}

// OutboxMessages is what a change to job must send, for pgstore.WithOutbox:
// a newly queued job needs a RunJob command.
func OutboxMessages(job jobs.Job) ([]outbox.Message, error) {
	if job.State != jobs.StateQueued {
		return nil, nil
	}
	msg, err := runJob(job, job.UpdatedAt)
	if err != nil {
		return nil, err
	}
	return []outbox.Message{{Destination: messages.CommandsQueue, Envelope: msg}}, nil
}
~~~

The command's envelope ID is created once, here, and stored in the outbox row. If the relay sends it twice, both copies have the **same** ID, which is what lets receivers recognise the duplicate.

Create `internal/eventing/eventing_test.go`:

<!-- file: internal/eventing/eventing_test.go -->
~~~go
package eventing

import (
	"testing"
	"time"

	"runway/internal/jobs"
	"runway/internal/messages"
)

func TestOutboxMessagesRunEachNewJobOnce(t *testing.T) {
	t0 := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	job, _ := jobs.New("resize", 250*time.Millisecond, t0)
	job.ID = 7

	msgs, err := OutboxMessages(job)
	if err != nil || len(msgs) != 1 {
		t.Fatalf("got %d messages, %v; want 1 RunJob", len(msgs), err)
	}
	if msgs[0].Destination != messages.CommandsQueue {
		t.Fatalf("destination %q, want %q", msgs[0].Destination, messages.CommandsQueue)
	}
	cmd, err := messages.DecodeRunJob(msgs[0].Envelope)
	if err != nil || cmd.JobID != 7 || cmd.DurationMS != 250 {
		t.Fatalf("command %+v, %v", cmd, err)
	}

	_ = job.Start(t0.Add(time.Second))
	if msgs, _ := OutboxMessages(job); len(msgs) != 0 {
		t.Fatalf("a started job produced %d messages, want none", len(msgs))
	}
}
~~~

### Wire the relay into the API

With a database, the service no longer dispatches at all. The store writes the command, and the relay sends it. The pool is now needed in two places (the store and the relay), so `connectStore` becomes `connectDatabase`, which returns the pool itself. In `cmd/api/main.go`, add the imports back. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"github.com/prometheus/client_golang/prometheus"
~~~

to:

~~~go
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/messages"
	"runway/internal/pgstore"
~~~

to:

~~~go
	"runway/internal/messages"
	"runway/internal/outbox"
	"runway/internal/pgstore"
~~~

Add the relay's interval. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	DBMaxConns       int
	RequestTimeout   time.Duration
~~~

to:

~~~go
	DBMaxConns       int
	OutboxInterval   time.Duration
	RequestTimeout   time.Duration
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
~~~

to:

~~~go
	if cfg.OutboxInterval, err = envconfig.Duration(getenv, "OUTBOX_INTERVAL", 100*time.Millisecond); err != nil {
		return config{}, err
	}
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
~~~

Replace `connectStore` entirely. Change:

<!-- edit: cmd/api/main.go -->
~~~go
// connectStore returns the job repository: PostgreSQL when DATABASE_URL is
// set, after bringing its schema up to date, or memory otherwise.
func connectStore(ctx context.Context, cfg config, metrics *httpapi.Metrics) (jobs.Repository, func(), error) {
	if cfg.DatabaseURL == "" {
		return memstore.New(), func() {}, nil
	}
	pool, err := pgstore.Open(ctx, cfg.DatabaseURL, pgstore.PoolOptions{MaxConns: int32(cfg.DBMaxConns)})
	if err != nil {
		return nil, nil, err
	}
	metrics.MustRegister(pgstore.PoolCollectors(pool)...)
	if err := pgstore.Migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, nil, err
	}
	return pgstore.New(pool), pool.Close, nil
}
~~~

to:

~~~go
// connectDatabase opens the PostgreSQL pool and brings the schema up to
// date. It returns a nil pool when DATABASE_URL is unset.
func connectDatabase(ctx context.Context, cfg config, metrics *httpapi.Metrics) (*pgxpool.Pool, error) {
	if cfg.DatabaseURL == "" {
		return nil, nil
	}
	pool, err := pgstore.Open(ctx, cfg.DatabaseURL, pgstore.PoolOptions{MaxConns: int32(cfg.DBMaxConns)})
	if err != nil {
		return nil, err
	}
	if err := pgstore.Migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, err
	}
	metrics.MustRegister(pgstore.PoolCollectors(pool)...)
	metrics.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "outbox_pending",
		Help: "Outbox messages not yet sent. Growth means the broker is unreachable.",
	}, func() float64 {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		n, _ := outbox.Pending(ctx, pool)
		return float64(n)
	}))
	return pool, nil
}
~~~

`outbox_pending` is the number to alert on: if it keeps growing, messages are being saved but not sent.

In `run`, choose how the service is built. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	repo, closeStore, err := connectStore(ctx, cfg, metrics)
	if err != nil {
		return err
	}
	defer closeStore()
	service := jobs.NewService(repo, jobs.WithDispatcher(dispatcher))
~~~

to:

~~~go
	pool, err := connectDatabase(ctx, cfg, metrics)
	if err != nil {
		return err
	}
	var service *jobs.Service
	if pool == nil {
		// Jobs live in memory and are dispatched straight to the bus.
		service = jobs.NewService(memstore.New(), jobs.WithDispatcher(dispatcher))
	} else {
		// A job and its RunJob command commit together, and the outbox
		// relay (started below) sends the command.
		defer pool.Close()
		service = jobs.NewService(pgstore.New(pool, pgstore.WithOutbox(eventing.OutboxMessages)))
	}
~~~

Then start the relay next to the consumers, so it stops with them at shutdown. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	consume(messages.EventsQueue, eventing.NewEventHandler(service))
~~~

to:

~~~go
	consume(messages.EventsQueue, eventing.NewEventHandler(service))

	if pool != nil {
		relay := outbox.NewRelay(pool, outbox.PublisherFunc(func(ctx context.Context, msg outbox.Message) error {
			return publisher.Publish(ctx, msg.Destination, msg.Envelope)
		}), 100, cfg.OutboxInterval, logger)
		consumers.Add(1)
		go func() {
			defer consumers.Done()
			relay.Run(stopConsuming)
		}()
	}
~~~

Without a database, nothing changes: the memory store, the dispatcher and its breaker work as in Phase 2.

Finally, an end-to-end test: the API with a real database, its in-memory bus and in-process workers. In `cmd/api/main_test.go`, change:

<!-- edit: cmd/api/main_test.go -->
~~~go
	"time"
)
~~~

to:

~~~go
	"time"

	"runway/internal/pgstore/pgtest"
)
~~~

and add at the end:

<!-- append: cmd/api/main_test.go -->
~~~go
// With a database, the job and its command commit together and the outbox
// relay delivers the command.
func TestJobsRunFromPostgres(t *testing.T) {
	base, _, _, _ := startServer(t, map[string]string{"DATABASE_URL": pgtest.URL(t)})
	createJob(t, base, 50)
	waitForState(t, base, "completed")
}
~~~

`pgtest.URL` gives the whole API its own schema, so this test can't collide with any other.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

### Run it: crash between commit and send

Make the crash window wide enough to hit by hand: start the API with an outbox interval of one minute, so after its first pass the relay sleeps. Use RabbitMQ and a real worker, as in Phase 2:

~~~bash
docker compose up -d --wait
export AMQP_URL=amqp://guest:guest@localhost:5672/ DATABASE_URL=postgres://runway:runway@localhost:5432/runway
go run ./cmd/worker &
OUTBOX_INTERVAL=1m go run ./cmd/api &
~~~

Create two jobs, then look at the outbox:

~~~bash
for d in crash-a crash-b; do curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d "{\"description\":\"$d\",\"duration_ms\":100}"; echo; done
docker compose exec postgres psql -U runway -c "SELECT id, destination, envelope->>'type' AS type, envelope->'payload'->>'job_id' AS job_id, published_at FROM outbox WHERE published_at IS NULL ORDER BY id"
~~~

~~~text
{"id":205,"state":"queued","description":"crash-a","duration_ms":100,...}
{"id":206,"state":"queued","description":"crash-b","duration_ms":100,...}
 id |  destination  |     type     | job_id | published_at 
----+---------------+--------------+--------+--------------
  1 | jobs.commands | jobs.run_job | 205    | 
  2 | jobs.commands | jobs.run_job | 206    | 
(2 rows)
~~~

(`->>` reads a field of a `JSONB` value as text, and `->` as JSON, so `envelope->'payload'->>'job_id'` digs two levels in.) The jobs are committed and their commands are waiting. Now **kill the API with SIGKILL**, exactly at the moment Phase 2 couldn't survive:

~~~bash
pkill -9 -f 'cmd/api|/api$'
go run ./cmd/api &
sleep 2
curl -s http://127.0.0.1:8080/jobs/205; echo
curl -s http://127.0.0.1:8080/jobs/206; echo
~~~

~~~text
{"id":205,"state":"completed","description":"crash-a",...}
{"id":206,"state":"completed","description":"crash-b",...}
~~~

The restarted API's relay found both commands on its first pass, the worker ran both jobs, and `outbox_pending` is back to 0. **The crash lost nothing**, because "this message must be sent" was committed together with the job. Phase 2 would have left both jobs `queued` forever.

**Break it: relays that don't lock.** In `RelayOnce`, delete the line `FOR UPDATE SKIP LOCKED` (keep the closing backquote after `LIMIT $1`), and run the outbox tests:

~~~text
--- FAIL: TestConcurrentRelaysNeverSendTheSameMessage (0.42s)
    outbox_test.go:138: message 5 sent 2 times
    outbox_test.go:138: message 10 sent 2 times
    outbox_test.go:138: message 11 sent 2 times
    ...
~~~

Both relays read the same unsent rows before either marked them, so both sent them. Receivers would cope, but every duplicate is wasted work, and with many instances it adds up. Now try `FOR UPDATE` alone, without `SKIP LOCKED`. The test passes, but the second relay **waits** for the first one's lock; when it gets the rows, they're already sent, so it skips them. That's correct, but the relays take turns instead of working side by side. Restore `FOR UPDATE SKIP LOCKED`.

One more consequence to know about: with several relays, messages are sent **in order within a batch**, but batches from different relays can interleave. Commands don't care. Step 6 sends events whose order does matter, and comes back to this.

**Explain it:** why can't you fix the dual-write problem by publishing first? Why is the outbox at-least-once, and why is that acceptable here? What do `FOR UPDATE` and `SKIP LOCKED` each contribute?

**Read.** Chris Richardson, *Pattern: Transactional outbox* (microservices.io), and the PostgreSQL manual's `SELECT` page, the section on *The Locking Clause*. Carry this question in: what would have to change if the relay published to two different brokers?

---

## Step 5: Idempotency keys in PostgreSQL

**The problem.** Phase 2's idempotency keys live in a map inside one API process. That has two consequences:
- restart the API, and every key is forgotten, so a client retrying across the restart creates a second job;
- run two instances behind a load balancer, and a retry that lands on the *other* instance isn't recognised either.

See the second one directly: two instances, one key, one request each. Here they run in memory mode:

~~~bash
LISTEN_ADDR=127.0.0.1:8081 GRPC_ADDR=127.0.0.1:9091 go run ./cmd/api &
LISTEN_ADDR=127.0.0.1:8082 GRPC_ADDR=127.0.0.1:9092 go run ./cmd/api &
for port in 8081 8082; do
  curl -s -i -X POST http://127.0.0.1:$port/jobs -H 'Content-Type: application/json' -H 'Idempotency-Key: order-77' \
    -d '{"description":"once","duration_ms":10}' | grep -E '^HTTP|^Idempotent|^\{'
done
~~~

~~~text
HTTP/1.1 201 Created
{"id":1,"state":"queued","description":"once","duration_ms":10,...}
HTTP/1.1 201 Created
{"id":1,"state":"queued","description":"once","duration_ms":10,...}
~~~

Two `201`s and two jobs, one in each instance's memory. They even have the same ID, but they're different jobs. The client asked for one. (Stop both instances before going on.)

**New ideas.**

- **Shared state.** Anything instances must agree on has to live outside them, in a place they all reach: here, the database they already share.
- **Check-then-act** is a race. "Is the key there? No? Then insert it" is two steps, and two requests can both pass the check before either inserts. Phase 2 avoided it with a mutex, but a mutex only covers one process.
- **`INSERT ... ON CONFLICT DO NOTHING`** makes the claim one atomic step. The primary key guarantees only one row per key; of many concurrent inserts, exactly one succeeds, and `ON CONFLICT DO NOTHING` turns the rest into "0 rows inserted" instead of errors. The **affected-row count** then tells each request whether it won. (`ON CONFLICT ... DO UPDATE`, an **upsert**, is the cousin you'll use in step 6.)
- **Extract a port when a second implementation arrives.** `idempotency.Store` was a concrete type, because there was only one. Now there are two, so the middleware gets an interface, `Keys`, with `context.Context` and errors in every method, because a database call can be slow or fail.
- **An advisory lock** is a lock on a number that means whatever the application decides. PostgreSQL holds it for you and releases it when the session ends. You'll meet it below, where it fixes a real bug, and again in step 8.

### A port for the key store

In `internal/idempotency/idempotency.go`, add the import. Change:

<!-- edit: internal/idempotency/idempotency.go -->
~~~go
import (
	"bytes"
~~~

to:

~~~go
import (
	"bytes"
	"context"
~~~

Add the interface before `Store`. Change:

<!-- edit: internal/idempotency/idempotency.go -->
~~~go
// Store remembers keys and their responses in memory until they expire.
type Store struct {
~~~

to:

~~~go
// Keys is where keys and their responses are kept. Store keeps them in
// memory; pgstore.Keys keeps them in PostgreSQL, so every API instance
// sees the same keys and they survive a restart.
type Keys interface {
	// Begin claims key for a request with the given fingerprint. It returns
	// the stored response if the same request already finished,
	// ErrInProgress if it hasn't finished yet, ErrMismatch if the key
	// belongs to a different request, or nil and nil if this request may go
	// ahead.
	Begin(ctx context.Context, key string, fingerprint [32]byte) (*Response, error)
	// Complete stores the final response for key.
	Complete(ctx context.Context, key string, response Response) error
	// Release forgets key, so the client may retry the request for real.
	Release(ctx context.Context, key string) error
}

// Store remembers keys and their responses in memory until they expire.
type Store struct {
~~~

Make the memory store implement it. Its methods gain a context, which they ignore (`_`), and errors, which are always nil. Change:

<!-- edit: internal/idempotency/idempotency.go -->
~~~go
// Begin claims key for a request with the given fingerprint. It returns the
// stored response if the same request already finished, ErrInProgress if it
// hasn't finished yet, ErrMismatch if the key belongs to a different
// request, or nil and nil if this request may go ahead.
func (s *Store) Begin(key string, fingerprint [32]byte) (*Response, error) {
~~~

to:

~~~go
func (s *Store) Begin(_ context.Context, key string, fingerprint [32]byte) (*Response, error) {
~~~

and:

<!-- edit: internal/idempotency/idempotency.go -->
~~~go
// Complete stores the final response for key.
func (s *Store) Complete(key string, response Response) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r, ok := s.records[key]; ok {
		r.done = true
		r.response = response
	}
}

// Release forgets key, so the client may retry the request for real.
func (s *Store) Release(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.records, key)
}
~~~

to:

~~~go
func (s *Store) Complete(_ context.Context, key string, response Response) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r, ok := s.records[key]; ok {
		r.done = true
		r.response = response
	}
	return nil
}

func (s *Store) Release(_ context.Context, key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.records, key)
	return nil
}
~~~

(The doc comments moved to the interface, which is where a reader looks for what the methods promise.)

Now the middleware. It takes any `Keys`, and must handle a key store that fails. Change:

<!-- edit: internal/idempotency/idempotency.go -->
~~~go
func Middleware(store *Store, maxBodyBytes int64, next http.Handler) http.Handler {
~~~

to:

~~~go
func Middleware(store Keys, maxBodyBytes int64, next http.Handler) http.Handler {
~~~

and:

<!-- edit: internal/idempotency/idempotency.go -->
~~~go
		cached, err := store.Begin(key, fingerprint(r, body))
		switch {
		case errors.Is(err, ErrMismatch):
			writeError(w, http.StatusUnprocessableEntity, err.Error())
		case errors.Is(err, ErrInProgress):
			w.Header().Set("Retry-After", "1")
			writeError(w, http.StatusConflict, err.Error())
~~~

to:

~~~go
		cached, err := store.Begin(r.Context(), key, fingerprint(r, body))
		switch {
		case errors.Is(err, ErrMismatch):
			writeError(w, http.StatusUnprocessableEntity, err.Error())
		case errors.Is(err, ErrInProgress):
			w.Header().Set("Retry-After", "1")
			writeError(w, http.StatusConflict, err.Error())
		case err != nil:
			// Without the key store, a retry can't be recognised. Refuse
			// rather than risk doing the work twice.
			w.Header().Set("Retry-After", "1")
			writeError(w, http.StatusServiceUnavailable, "idempotency keys are unavailable")
~~~

That new `case` matters. Without it, a failed `Begin` would fall through to `default` and run the request **unprotected**, which is precisely the situation the key exists to prevent.

Finally, the bookkeeping after the handler. Change:

<!-- edit: internal/idempotency/idempotency.go -->
~~~go
			recorder := &responseRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(recorder, r)
			if recorder.status >= 500 {
				store.Release(key) // not a final answer: let the client retry
				return
			}
			store.Complete(key, Response{
				Status: recorder.status,
				Header: w.Header().Clone(),
				Body:   recorder.body.Bytes(),
			})
~~~

to:

~~~go
			recorder := &responseRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(recorder, r)
			// The response is already sent, so a failure below can't change
			// it. The request's context may be done by now; don't let that
			// stop the bookkeeping.
			ctx := context.WithoutCancel(r.Context())
			if recorder.status >= 500 {
				_ = store.Release(ctx, key) // not a final answer: let the client retry
				return
			}
			if err := store.Complete(ctx, key, Response{
				Status: recorder.status,
				Header: w.Header().Clone(),
				Body:   recorder.body.Bytes(),
			}); err != nil {
				_ = store.Release(ctx, key)
			}
~~~

The handler option takes the interface too. In `internal/httpapi/handler.go`, change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	idempotency    *idempotency.Store
~~~

to:

~~~go
	idempotency    idempotency.Keys
~~~

and:

<!-- edit: internal/httpapi/handler.go -->
~~~go
func WithIdempotency(store *idempotency.Store) Option {
~~~

to:

~~~go
func WithIdempotency(store idempotency.Keys) Option {
~~~

### A contract for key stores

As with repositories, the rules belong to the port. Create `internal/idempotency/keystest/contract.go`:

<!-- file: internal/idempotency/keystest/contract.go -->
~~~go
// Package keystest checks that an idempotency.Keys behaves the way the
// middleware relies on. The in-memory store and PostgreSQL both run it.
package keystest

import (
	"context"
	"crypto/sha256"
	"errors"
	"net/http"
	"sync"
	"testing"
	"time"

	"runway/internal/idempotency"
)

// Clock is a time the test can move forward.
type Clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *Clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *Clock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// TTL is the expiry every implementation under test must be built with.
const TTL = time.Hour

// Run runs the contract. newKeys must return an empty store with a TTL of
// TTL, reading the time from clock.
func Run(t *testing.T, newKeys func(t *testing.T, clock *Clock) idempotency.Keys) {
	ctx := context.Background()
	a := sha256.Sum256([]byte("request a"))
	b := sha256.Sum256([]byte("request b"))
	done := idempotency.Response{Status: http.StatusCreated, Header: http.Header{"Location": {"/jobs/1"}}, Body: []byte(`{"id":1}`)}
	// start makes a fresh store for one subtest. It takes the subtest's t,
	// so a store that skips or fails (no database, say) does so in the
	// subtest that asked for it.
	start := func(t *testing.T) (*Clock, idempotency.Keys) {
		clock := &Clock{now: time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)}
		return clock, newKeys(t, clock)
	}

	t.Run("a new key is claimed", func(t *testing.T) {
		_, keys := start(t)
		if got, err := keys.Begin(ctx, "k", a); got != nil || err != nil {
			t.Fatalf("Begin = %v, %v; want nil, nil", got, err)
		}
	})

	t.Run("a key in use is in progress", func(t *testing.T) {
		_, keys := start(t)
		_, _ = keys.Begin(ctx, "k", a)
		if _, err := keys.Begin(ctx, "k", a); !errors.Is(err, idempotency.ErrInProgress) {
			t.Fatalf("error = %v, want ErrInProgress", err)
		}
	})

	t.Run("a key for another request is a mismatch", func(t *testing.T) {
		_, keys := start(t)
		_, _ = keys.Begin(ctx, "k", a)
		if _, err := keys.Begin(ctx, "k", b); !errors.Is(err, idempotency.ErrMismatch) {
			t.Fatalf("error = %v, want ErrMismatch", err)
		}
	})

	t.Run("a completed key returns the response exactly", func(t *testing.T) {
		_, keys := start(t)
		_, _ = keys.Begin(ctx, "k", a)
		if err := keys.Complete(ctx, "k", done); err != nil {
			t.Fatal(err)
		}
		got, err := keys.Begin(ctx, "k", a)
		if err != nil || got == nil {
			t.Fatalf("Begin = %v, %v; want the stored response", got, err)
		}
		if got.Status != done.Status || string(got.Body) != string(done.Body) || got.Header.Get("Location") != "/jobs/1" {
			t.Fatalf("response = %+v, want %+v", *got, done)
		}
	})

	t.Run("a released key can be claimed again", func(t *testing.T) {
		_, keys := start(t)
		_, _ = keys.Begin(ctx, "k", a)
		if err := keys.Release(ctx, "k"); err != nil {
			t.Fatal(err)
		}
		if got, err := keys.Begin(ctx, "k", b); got != nil || err != nil {
			t.Fatalf("Begin = %v, %v; want nil, nil", got, err)
		}
	})

	t.Run("an expired key can be claimed again", func(t *testing.T) {
		clock, keys := start(t)
		_, _ = keys.Begin(ctx, "k", a)
		_ = keys.Complete(ctx, "k", done)
		clock.Advance(TTL + time.Second)
		if got, err := keys.Begin(ctx, "k", b); got != nil || err != nil {
			t.Fatalf("Begin = %v, %v; want nil, nil", got, err)
		}
	})

	t.Run("concurrent claims have exactly one winner", func(t *testing.T) {
		_, keys := start(t)
		var wg sync.WaitGroup
		var mu sync.Mutex
		winners := 0
		for range 20 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if got, err := keys.Begin(ctx, "k", a); got == nil && err == nil {
					mu.Lock()
					winners++
					mu.Unlock()
				}
			}()
		}
		wg.Wait()
		if winners != 1 {
			t.Fatalf("%d requests claimed the key, want 1", winners)
		}
	})
}
~~~

`Clock` lets the expiry test move time forward instead of sleeping for an hour. Run the contract against the memory store. It must be in an external test package (`idempotency_test`), because `keystest` imports `idempotency`, and a package's own tests can't import something that imports it back. Create `internal/idempotency/contract_test.go`:

<!-- file: internal/idempotency/contract_test.go -->
~~~go
package idempotency_test

import (
	"testing"

	"runway/internal/idempotency"
	"runway/internal/idempotency/keystest"
)

func TestContract(t *testing.T) {
	keystest.Run(t, func(t *testing.T, clock *keystest.Clock) idempotency.Keys {
		return idempotency.NewStore(keystest.TTL, clock.Now)
	})
}
~~~

### The PostgreSQL key store

Create `internal/pgstore/migrations/0004_idempotency_keys.sql`:

<!-- file: internal/pgstore/migrations/0004_idempotency_keys.sql -->
~~~sql
-- +goose Up
CREATE TABLE idempotency_keys (
    key         TEXT        PRIMARY KEY,
    fingerprint BYTEA       NOT NULL,
    status      INT,        -- NULL while the first request is still running
    header      JSONB,
    body        BYTEA,
    expires_at  TIMESTAMPTZ NOT NULL
);
CREATE INDEX idempotency_keys_expires_at ON idempotency_keys (expires_at);

-- +goose Down
DROP TABLE idempotency_keys;
~~~

`BYTEA` holds raw bytes: the 32-byte SHA-256 fingerprint and the response body. A `NULL` status marks a request still in progress. The index on `expires_at` is for sweeping expired keys.

Create `internal/pgstore/keys.go`:

<!-- file: internal/pgstore/keys.go -->
~~~go
package pgstore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"runway/internal/idempotency"
)

// Keys implements idempotency.Keys in PostgreSQL, so every API instance
// sees the same keys, and they survive a restart.
type Keys struct {
	pool *pgxpool.Pool
	ttl  time.Duration
	now  func() time.Time
}

func NewKeys(pool *pgxpool.Pool, ttl time.Duration, now func() time.Time) *Keys {
	return &Keys{pool: pool, ttl: ttl, now: now}
}

// Begin claims the key with one INSERT. The primary key makes the claim
// atomic: of many concurrent requests, exactly one insert succeeds, and
// ON CONFLICT DO NOTHING turns the others into "0 rows" instead of errors.
func (k *Keys) Begin(ctx context.Context, key string, fingerprint [32]byte) (*idempotency.Response, error) {
	for {
		now := k.now()
		// An expired key is free again.
		if _, err := k.pool.Exec(ctx, `DELETE FROM idempotency_keys WHERE key = $1 AND expires_at < $2`, key, now); err != nil {
			return nil, fmt.Errorf("idempotency key: %w", err)
		}
		tag, err := k.pool.Exec(ctx, `
			INSERT INTO idempotency_keys (key, fingerprint, expires_at) VALUES ($1, $2, $3)
			ON CONFLICT (key) DO NOTHING`, key, fingerprint[:], now.Add(k.ttl))
		if err != nil {
			return nil, fmt.Errorf("idempotency key: %w", err)
		}
		if tag.RowsAffected() == 1 {
			return nil, nil // claimed: this request goes ahead
		}

		var stored, header, body []byte
		var status *int
		err = k.pool.QueryRow(ctx, `
			SELECT fingerprint, status, header, body FROM idempotency_keys WHERE key = $1`, key,
		).Scan(&stored, &status, &header, &body)
		if errors.Is(err, pgx.ErrNoRows) {
			continue // released between our INSERT and SELECT: try to claim it again
		}
		if err != nil {
			return nil, fmt.Errorf("idempotency key: %w", err)
		}
		switch {
		case !bytes.Equal(stored, fingerprint[:]):
			return nil, idempotency.ErrMismatch
		case status == nil:
			return nil, idempotency.ErrInProgress
		}
		response := idempotency.Response{Status: *status, Body: body}
		if err := json.Unmarshal(header, &response.Header); err != nil {
			return nil, fmt.Errorf("idempotency key: %w", err)
		}
		return &response, nil
	}
}

func (k *Keys) Complete(ctx context.Context, key string, response idempotency.Response) error {
	header, err := json.Marshal(response.Header)
	if err != nil {
		return err
	}
	_, err = k.pool.Exec(ctx, `
		UPDATE idempotency_keys SET status = $2, header = $3, body = $4 WHERE key = $1`,
		key, response.Status, header, response.Body)
	return err
}

func (k *Keys) Release(ctx context.Context, key string) error {
	_, err := k.pool.Exec(ctx, `DELETE FROM idempotency_keys WHERE key = $1`, key)
	return err
}

// Sweep deletes expired keys and reports how many it deleted.
func (k *Keys) Sweep(ctx context.Context) (int, error) {
	tag, err := k.pool.Exec(ctx, `DELETE FROM idempotency_keys WHERE expires_at < $1`, k.now())
	return int(tag.RowsAffected()), err
}

var _ idempotency.Keys = (*Keys)(nil)
~~~

`Begin` takes three statements, and each is safe on its own:
1. The `DELETE` frees an expired key. If two requests both try, one deletes it and the other deletes nothing.
2. The `INSERT ... ON CONFLICT DO NOTHING` is the claim. Exactly one concurrent request sees `RowsAffected() == 1`.
3. The `SELECT` is for the losers: it reads what the winner stored.

The `continue` handles a key released between the losing `INSERT` and its `SELECT`. It's rare, and the honest answer is simply to try to claim it again. `Sweep` deletes all expired keys at once; the API already runs it once a minute. The line `var _ idempotency.Keys = (*Keys)(nil)` makes the compiler check that `Keys` implements the interface.

Run the contract against it. Create `internal/pgstore/keys_test.go`:

<!-- file: internal/pgstore/keys_test.go -->
~~~go
package pgstore

import (
	"testing"

	"runway/internal/idempotency"
	"runway/internal/idempotency/keystest"
	"runway/internal/pgstore/pgtest"
)

func TestKeysContract(t *testing.T) {
	keystest.Run(t, func(t *testing.T, clock *keystest.Clock) idempotency.Keys {
		return NewKeys(pgtest.Pool(t, Migrate), keystest.TTL, clock.Now)
	})
}
~~~

### Use the shared keys in the API

In `cmd/api/main.go`, choose the key store like the job store. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	keys := idempotency.NewStore(cfg.IdempotencyTTL, time.Now)
	metrics.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "idempotency_keys",
		Help: "Idempotency keys currently remembered.",
	}, func() float64 { return float64(keys.Len()) }))
~~~

to:

~~~go
	var keys idempotency.Keys
	var sweepKeys func(context.Context) (int, error)
	if pool == nil {
		memoryKeys := idempotency.NewStore(cfg.IdempotencyTTL, time.Now)
		metrics.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Name: "idempotency_keys",
			Help: "Idempotency keys currently remembered.",
		}, func() float64 { return float64(memoryKeys.Len()) }))
		keys = memoryKeys
		sweepKeys = func(context.Context) (int, error) { return memoryKeys.Sweep(), nil }
	} else {
		// Every instance shares the keys, so a retry that reaches a
		// different instance is still recognised.
		pgKeys := pgstore.NewKeys(pool, cfg.IdempotencyTTL, time.Now)
		keys, sweepKeys = pgKeys, pgKeys.Sweep
	}
~~~

`sweepKeys` gives the two stores one shape, a function from a context to "how many removed, or an error", so the background loop doesn't care which it has. Change the loop:

<!-- edit: cmd/api/main.go -->
~~~go
				if removed := keys.Sweep(); removed > 0 {
					logger.Info("swept idempotency keys", "removed", removed)
				}
~~~

to:

~~~go
				removed, err := sweepKeys(stopConsuming)
				if err != nil {
					logger.Warn("sweeping idempotency keys failed", "error", err)
				} else if removed > 0 {
					logger.Info("swept idempotency keys", "removed", removed)
				}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

~~~bash
go test -v -run KeysContract ./internal/pgstore/
~~~

~~~text
--- PASS: TestKeysContract (0.92s)
    --- PASS: TestKeysContract/a_new_key_is_claimed (0.11s)
    --- PASS: TestKeysContract/a_key_in_use_is_in_progress (0.10s)
    --- PASS: TestKeysContract/a_key_for_another_request_is_a_mismatch (0.11s)
    --- PASS: TestKeysContract/a_completed_key_returns_the_response_exactly (0.10s)
    --- PASS: TestKeysContract/a_released_key_can_be_claimed_again (0.10s)
    --- PASS: TestKeysContract/an_expired_key_can_be_claimed_again (0.10s)
    --- PASS: TestKeysContract/concurrent_claims_have_exactly_one_winner (0.15s)
ok  	runway/internal/pgstore	0.938s
~~~

### Run it: two instances, one key

Repeat the opening experiment with `DATABASE_URL` set. Then something you may not expect happens. The first time you start two instances at the same moment against a database that hasn't had migration 4 yet, one of them can die at start-up:

~~~text
migrate: partial migration error (type:sql,version:4): ERROR: duplicate key value violates unique constraint "pg_type_typname_nsp_index" (SQLSTATE 23505)
~~~

Both instances saw "version 4 not applied" and both ran `CREATE TABLE idempotency_keys` at once. One won; the other's `CREATE` collided with the table the first had just made. Every deploy that starts several instances together risks this. The fix is to let **one** instance migrate while the others wait: goose can take a PostgreSQL advisory lock around the whole run. In `internal/pgstore/pgstore.go`, change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	"github.com/pressly/goose/v3/database"
~~~

to:

~~~go
	"github.com/pressly/goose/v3/database"
	"github.com/pressly/goose/v3/lock"
~~~

and:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
// Migrate applies every migration the database hasn't seen yet.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	files, err := fs.Sub(migrations, "migrations")
	if err != nil {
		return err
	}
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	provider, err := goose.NewProvider(database.DialectPostgres, db, files)
~~~

to:

~~~go
// Migrate applies every migration the database hasn't seen yet. Several
// instances may start at once, so it first takes a PostgreSQL advisory
// lock: one instance migrates while the others wait, checking every second
// for up to a minute, then find nothing left to do.
func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	files, err := fs.Sub(migrations, "migrations")
	if err != nil {
		return err
	}
	locker, err := lock.NewPostgresSessionLocker(lock.WithLockTimeout(1, 60))
	if err != nil {
		return err
	}
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	provider, err := goose.NewProvider(database.DialectPostgres, db, files, goose.WithSessionLocker(locker))
~~~

The lock's default is to check every **5** seconds. `WithLockTimeout(1, 60)` checks every second, for up to 60 tries, so a waiting instance starts about a second after the winner finishes.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

To see it, put the database back to before migration 4 and start both instances together:

~~~bash
docker compose exec postgres psql -U runway -c 'DROP TABLE idempotency_keys' -c 'DELETE FROM goose_db_version WHERE version_id = 4'
export DATABASE_URL=postgres://runway:runway@localhost:5432/runway
LISTEN_ADDR=127.0.0.1:8081 GRPC_ADDR=127.0.0.1:9091 go run ./cmd/api &
LISTEN_ADDR=127.0.0.1:8082 GRPC_ADDR=127.0.0.1:9092 go run ./cmd/api &
~~~

Both start. Now send the same request once to each:

~~~text
HTTP/1.1 201 Created
{"id":207,"state":"queued","description":"once","duration_ms":10,...}
HTTP/1.1 201 Created
Idempotent-Replayed: true
{"id":207,"state":"queued","description":"once","duration_ms":10,...}
~~~

The second instance had never seen the request, but it found the key in the shared table and replayed the first instance's response: one job. Look at the stored key:

~~~bash
docker compose exec postgres psql -U runway -c "SELECT key, left(encode(fingerprint, 'hex'), 12) AS fingerprint, status, length(body) AS body_bytes, expires_at FROM idempotency_keys"
~~~

~~~text
   key    | fingerprint  | status | body_bytes |          expires_at           
----------+--------------+--------+------------+-------------------------------
 order-77 | dd238a1cd6a2 |    201 |        152 | 2026-10-06 19:32:15.555348+00
(1 row)
~~~

**Break it: claim without `ON CONFLICT`.** In `Keys.Begin`, delete `ON CONFLICT (key) DO NOTHING` from the `INSERT` (keep the closing backquote):

~~~text
--- FAIL: TestKeysContract/a_key_in_use_is_in_progress (0.09s)
    contract.go:61: error = idempotency key: ERROR: duplicate key value violates unique constraint "idempotency_keys_pkey" (SQLSTATE 23505), want ErrInProgress
--- FAIL: TestKeysContract/a_key_for_another_request_is_a_mismatch (0.08s)
...
~~~

The primary key still stops a second row, so you never get two jobs. But every retry now becomes an error, and the middleware turns errors into `503`. Clients who did exactly the right thing get told the service is broken. Restore it.

**A gap that remains.** The key and the job are written in **separate** transactions. If the API crashes after creating the job but before `Complete`, the key stays "in progress" until it expires (24 hours by default), and retries get `409` all that time. Stripe's article in the reading list describes the full answer: store the key's progress in the same transaction as the work, and let a later request take over a claim that's been abandoned. That's one of this phase's stretch goals.

**Explain it:** why is "check, then insert" a race, and how does the primary key plus `ON CONFLICT DO NOTHING` close it? Why must a failed `Begin` refuse the request? What went wrong when two instances migrated at once, and how does the advisory lock fix it?

**Read.** Brandur Leach, *Implementing Stripe-like Idempotency Keys in Postgres*, and the PostgreSQL manual's `INSERT` page, the section on `ON CONFLICT`. Carry this question in: what does the key protect against, and what does it not?

---

## Step 6: Kafka, an event stream

**The problem.** Runway now records every change of every job. Other teams want to use that history:
- analytics wants counts per state;
- the security team wants an audit trail (step 10);
- someone will eventually want a dashboard nobody has thought of yet.

None of them should query Runway's tables directly: that would couple them to its schema forever, and add their load to its database. RabbitMQ isn't the right tool either. A queue hands each message to **one** consumer and **deletes** it once acknowledged, so a consumer that joins next month can't read last month's events, and a consumer with a bug can't go back and redo them.

What these readers want is a **log**: an ordered record of events that stays put, which any number of readers can read independently, each at its own pace, from wherever it likes.

**New ideas.**

- **Kafka** stores **topics**. A topic is an append-only log split into **partitions**: messages (called **records**) are appended to the end of a partition and numbered in order by their **offset**. They're kept for a **retention period** (7 days by default), whether anyone has read them or not.
- A record has a **key**. Records with the same key always go to the same partition, so **one key's records stay in order**. Runway keys events by job ID: one job's events stay in order, while different jobs spread across partitions and are processed in parallel. There's no order *across* partitions.
- A **consumer group** is a set of consumers sharing the work of reading a topic. Each partition is read by exactly one member at a time, so a topic with 3 partitions keeps at most 3 members of a group busy. Different groups are completely independent; each reads everything.
- **Committed offsets.** A group stores, per partition, how far it has got. A consumer that restarts carries on from there. A **new** group, or one whose offsets you reset, can start from the oldest record still held: that's **replay**.
- **Rebalancing.** When a member joins or leaves, the group moves partitions between members. franz-go's default is **cooperative** rebalancing: only the partitions that must move stop, and the rest keep going.
- **Lag** is how far a group is behind: log-end offset minus committed offset. It's the queue depth of a stream, and the number to alert on.
- **Queue vs log**, side by side:

  | | RabbitMQ queue | Kafka topic |
  |---|---|---|
  | After a message is handled | Deleted | Kept until retention expires |
  | Several kinds of consumer | Each needs its own queue | Each is its own group, all on one topic |
  | Order | Roughly FIFO, broken by redelivery | Strict, per partition |
  | Going back | Not possible | Reset the group's offsets and replay |
  | Unit of parallelism | Consumers on the same queue | Partitions |
  | Best for | Commands: do this, once, somebody | Events: this happened, tell everyone, keep it |

- A **read model** (or **projection**) is a view built by applying events, kept separately from the data the events came from. If it's wrong or you want a new one, delete it and rebuild it from the stream. This is the core idea of **event sourcing**: the events are the truth, and every table is just one way of looking at them.
- **The inbox.** Kafka delivers at least once, like everything else: a consumer that crashes before committing sees those records again. Runway's job handlers were idempotent by design, but **counting is not**: count an event twice and the number is wrong. An **inbox** table records the ID of every message a consumer has handled, in the **same transaction** as the handling. A redelivered message finds its ID already there and is skipped.

### Run Kafka

Add a broker to `compose.yaml`. Change:

<!-- edit: compose.yaml -->
~~~yaml
volumes:
  pgdata:
~~~

to:

~~~yaml
  kafka:
    image: apache/kafka:4.1.0 # one broker, in KRaft mode: no ZooKeeper
    ports:
      - "9092:9092"
    healthcheck:
      test: ["CMD-SHELL", "/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 > /dev/null"]
      interval: 5s
      timeout: 10s
      retries: 20

volumes:
  pgdata:
~~~

~~~bash
docker compose up -d --wait kafka
~~~

This is one broker holding one copy of every partition: fine for learning, and useless for surviving a broker failure. Phase 4 is about running copies. Get the Go client:

<!-- run: go get github.com/twmb/franz-go@v1.22.1 github.com/twmb/franz-go/pkg/kadm@v1.19.0 -->
~~~bash
go get github.com/twmb/franz-go@v1.22.1 github.com/twmb/franz-go/pkg/kadm@v1.19.0
~~~

### The event

In `internal/messages/messages.go`, add the topic. Change:

<!-- edit: internal/messages/messages.go -->
~~~go
// Queue names. Commands go to workers; events come back to the API.
const (
	CommandsQueue = "jobs.commands"
	EventsQueue   = "jobs.events"
)
~~~

to:

~~~go
// Queue names. Commands go to workers; events come back to the API.
const (
	CommandsQueue = "jobs.commands"
	EventsQueue   = "jobs.events"
)

// JobEventsTopic is the Kafka topic that records every change of a job's
// state, keyed by job ID. Unlike a queue, it keeps messages after they are
// read, so any number of consumers can read it, and read it again.
const JobEventsTopic = "runway.job-events"
~~~

Add the type and its version. Change:

<!-- edit: internal/messages/messages.go -->
~~~go
	TypeJobFailed    = "jobs.job_failed"
)
~~~

to:

~~~go
	TypeJobFailed    = "jobs.job_failed"
	TypeJobChanged   = "jobs.job_changed"
)
~~~

and:

<!-- edit: internal/messages/messages.go -->
~~~go
	TypeJobFailed:    1,
}
~~~

to:

~~~go
	TypeJobFailed:    1,
	TypeJobChanged:   1,
}
~~~

And the payload. Change:

<!-- edit: internal/messages/messages.go -->
~~~go
type JobFailed struct {
	JobID  int64  `json:"job_id"`
	Reason string `json:"reason"`
}
~~~

to:

~~~go
type JobFailed struct {
	JobID  int64  `json:"job_id"`
	Reason string `json:"reason"`
}

// JobChanged is the event the API streams to Kafka whenever a job's state
// changes. The envelope's OccurredAt is when it changed.
type JobChanged struct {
	JobID  int64  `json:"job_id"`
	State  string `json:"state"`
	Reason string `json:"reason,omitempty"`
}
~~~

`JobStarted` and friends are what a *worker* reports to the API. `JobChanged` is what the *API* announces once it has accepted a change. They're different contracts with different readers, so they're different messages.

### Every change streams an event, through the outbox

The event must leave exactly when the change commits: never for a change that rolled back, and never lost for one that committed. That's precisely what the outbox gives you, so each change writes its event to the outbox too, destined for the topic. In `internal/eventing/eventing.go`, add an import. Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
	"fmt"
	"time"
~~~

to:

~~~go
	"fmt"
	"strconv"
	"time"
~~~

and replace `OutboxMessages` with a version you configure. Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
// OutboxMessages is what a change to job must send, for pgstore.WithOutbox:
// a newly queued job needs a RunJob command.
func OutboxMessages(job jobs.Job) ([]outbox.Message, error) {
	if job.State != jobs.StateQueued {
		return nil, nil
	}
	msg, err := runJob(job, job.UpdatedAt)
	if err != nil {
		return nil, err
	}
	return []outbox.Message{{Destination: messages.CommandsQueue, Envelope: msg}}, nil
}
~~~

to:

~~~go
// OutboxMessages returns what a change to a job must send, for
// pgstore.WithOutbox: a newly queued job needs a RunJob command. With
// streamEvents, every change is also streamed as a JobChanged event, keyed
// by job ID so that one job's events stay in order.
func OutboxMessages(streamEvents bool) func(jobs.Job) ([]outbox.Message, error) {
	return func(job jobs.Job) ([]outbox.Message, error) {
		var msgs []outbox.Message
		if job.State == jobs.StateQueued {
			cmd, err := runJob(job, job.UpdatedAt)
			if err != nil {
				return nil, err
			}
			msgs = append(msgs, outbox.Message{Destination: messages.CommandsQueue, Envelope: cmd})
		}
		if streamEvents {
			event := jobs.EventFor(job)
			env, err := messages.New(messages.TypeJobChanged, messages.JobChanged{
				JobID:  int64(event.JobID),
				State:  string(event.State),
				Reason: event.Reason,
			}, event.At)
			if err != nil {
				return nil, err
			}
			msgs = append(msgs, outbox.Message{
				Destination: messages.JobEventsTopic,
				Key:         strconv.FormatInt(int64(event.JobID), 10),
				Envelope:    env,
			})
		}
		return msgs, nil
	}
}
~~~

`OutboxMessages(true)` returns a function: a closure that remembers `streamEvents`. The store doesn't need to know about Kafka at all.

Update the test's two calls. In `internal/eventing/eventing_test.go`, change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	msgs, err := OutboxMessages(job)
~~~

to:

~~~go
	msgs, err := OutboxMessages(false)(job)
~~~

and:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	if msgs, _ := OutboxMessages(job); len(msgs) != 0 {
~~~

to:

~~~go
	if msgs, _ := OutboxMessages(false)(job); len(msgs) != 0 {
~~~

and add at the end:

<!-- append: internal/eventing/eventing_test.go -->
~~~go
func TestOutboxMessagesStreamEveryChange(t *testing.T) {
	t0 := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	job, _ := jobs.New("resize", time.Second, t0)
	job.ID = 7
	_ = job.Start(t0)
	_ = job.Fail("disk full", t0.Add(time.Second))

	msgs, err := OutboxMessages(true)(job)
	if err != nil || len(msgs) != 1 {
		t.Fatalf("got %d messages, %v; want one JobChanged", len(msgs), err)
	}
	msg := msgs[0]
	var event messages.JobChanged
	if err := messages.Decode(msg.Envelope, messages.TypeJobChanged, &event); err != nil {
		t.Fatal(err)
	}
	if msg.Destination != messages.JobEventsTopic || msg.Key != "7" {
		t.Fatalf("sent to %q with key %q", msg.Destination, msg.Key)
	}
	if event != (messages.JobChanged{JobID: 7, State: "failed", Reason: "disk full"}) || !msg.Envelope.OccurredAt.Equal(t0.Add(time.Second)) {
		t.Fatalf("event %+v at %v", event, msg.Envelope.OccurredAt)
	}
}
~~~

### The Kafka adapter

Create `internal/stream/stream.go`:

<!-- file: internal/stream/stream.go -->
~~~go
// Package stream connects Runway to Kafka.
//
// A RabbitMQ queue hands each message to one consumer and deletes it once
// acknowledged. A Kafka topic is a log: messages are appended, kept for the
// retention period whether anyone has read them or not, and each consumer
// group tracks its own position (its offset) in each partition. So any
// number of groups can read the same events independently, and a group can
// go back and read them again.
package stream

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"

	"runway/internal/messages"
	"runway/internal/outbox"
)

// EnsureTopic creates topic with the given number of partitions, unless it
// already exists. One broker can only hold one copy of each partition, so
// the replication factor is 1 here; Phase 4 is about running more copies.
func EnsureTopic(ctx context.Context, brokers []string, topic string, partitions int32) error {
	client, err := kgo.NewClient(kgo.SeedBrokers(brokers...))
	if err != nil {
		return err
	}
	defer client.Close()
	_, err = kadm.NewClient(client).CreateTopic(ctx, partitions, 1, nil, topic)
	if err != nil && !errors.Is(err, kerr.TopicAlreadyExists) {
		return fmt.Errorf("create topic %s: %w", topic, err)
	}
	return nil
}

// Producer appends messages to topics. It implements outbox.Publisher.
type Producer struct {
	client *kgo.Client
}

// NewProducer connects to brokers. franz-go's producer is idempotent by
// default: if it retries a send, the broker drops the duplicate.
func NewProducer(ctx context.Context, brokers []string) (*Producer, error) {
	client, err := kgo.NewClient(kgo.SeedBrokers(brokers...))
	if err != nil {
		return nil, err
	}
	if err := client.Ping(ctx); err != nil {
		client.Close()
		return nil, fmt.Errorf("connect to Kafka: %w", err)
	}
	return &Producer{client: client}, nil
}

// Publish appends msg to the topic msg.Destination and waits until the
// broker has stored it. Records with the same key go to the same partition,
// so they are read back in the order they were written.
func (p *Producer) Publish(ctx context.Context, msg outbox.Message) error {
	value, err := json.Marshal(msg.Envelope)
	if err != nil {
		return err
	}
	record := &kgo.Record{Topic: msg.Destination, Key: []byte(msg.Key), Value: value}
	return p.client.ProduceSync(ctx, record).FirstErr()
}

func (p *Producer) Close() { p.client.Close() }

// Handler processes one event. Returning an error stops the consumer.
type Handler func(ctx context.Context, msg messages.Envelope) error

// Consumer reads one topic as a member of a consumer group. The group's
// members share the topic's partitions between them; each partition is
// read by exactly one member at a time.
type Consumer struct {
	client *kgo.Client
}

// NewConsumer joins group to read topic. A group with no stored offsets
// starts at the oldest message the topic still holds.
func NewConsumer(brokers []string, group, topic string, logger *slog.Logger) (*Consumer, error) {
	client, err := kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		kgo.ConsumerGroup(group),
		kgo.ConsumeTopics(topic),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()),
		// Offsets are committed by Run, after the records are handled.
		kgo.DisableAutoCommit(),
		// Don't hand partitions to another member while a batch is being
		// handled; Run allows it again after committing.
		kgo.BlockRebalanceOnPoll(),
		// The default balancer is cooperative: a rebalance moves only the
		// partitions that must move, so these report changes, not totals.
		kgo.OnPartitionsAssigned(func(_ context.Context, _ *kgo.Client, assigned map[string][]int32) {
			if len(assigned[topic]) > 0 {
				logger.Info("partitions assigned", "topic", topic, "partitions", assigned[topic])
			}
		}),
		kgo.OnPartitionsRevoked(func(_ context.Context, _ *kgo.Client, revoked map[string][]int32) {
			if len(revoked[topic]) > 0 {
				logger.Info("partitions revoked", "topic", topic, "partitions", revoked[topic])
			}
		}),
	)
	if err != nil {
		return nil, err
	}
	return &Consumer{client: client}, nil
}

// Run hands every record to handle until ctx is done. It commits a batch's
// offsets only after every record in it was handled, so delivery is at
// least once: after a crash, the uncommitted records are read again.
//
// A failed record stops Run instead of being skipped. Events in a partition
// are in order, and skipping one would apply the later ones without it.
// Fix the cause, restart, and the record is read again.
func (c *Consumer) Run(ctx context.Context, handle Handler) error {
	for {
		fetches := c.client.PollFetches(ctx)
		if ctx.Err() != nil || fetches.IsClientClosed() {
			c.client.AllowRebalance()
			return nil
		}
		err := c.handleBatch(ctx, fetches, handle)
		// Every poll blocks rebalancing until this call, including one that
		// failed: without it, Close would wait forever.
		c.client.AllowRebalance()
		if err != nil {
			return err
		}
	}
}

func (c *Consumer) handleBatch(ctx context.Context, fetches kgo.Fetches, handle Handler) error {
	if errs := fetches.Errors(); len(errs) > 0 {
		return fmt.Errorf("fetch from Kafka: %w", errs[0].Err)
	}
	records := fetches.Records()
	for _, record := range records {
		var msg messages.Envelope
		err := json.Unmarshal(record.Value, &msg)
		if err == nil {
			err = handle(ctx, msg)
		}
		if err != nil {
			return fmt.Errorf("partition %d, offset %d: %w", record.Partition, record.Offset, err)
		}
	}
	if len(records) == 0 {
		return nil
	}
	// These records are handled, so commit them even if ctx was cancelled
	// meanwhile; otherwise a restart would handle them again.
	commitCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if err := c.client.CommitRecords(commitCtx, records...); err != nil {
		return fmt.Errorf("commit offsets: %w", err)
	}
	return nil
}

// Close leaves the group, so its partitions move to the remaining members
// at once instead of after a session timeout.
func (c *Consumer) Close() { c.client.Close() }
~~~

Three decisions in `Run` deserve a second look:
1. **Commit after handling, never before**: at least once, just like acking after the work in Phase 2. Offsets are committed per batch, not per record, because committing costs a round trip to the broker. After a crash, the uncommitted part of the batch is read again.
2. **A failed record stops the consumer** instead of being skipped. In a log, record 101 may depend on record 100. Skipping is a decision to make deliberately (a dead-letter topic), not a default.
3. **`AllowRebalance` after every poll.** With `BlockRebalanceOnPoll`, the group can't move partitions while you're working on a batch, so you never commit offsets for a partition that just moved to someone else. But *every* poll blocks rebalancing until you allow it again, **including** the one that returned because you were shutting down. Miss that path, and `Close` waits forever for a rebalance that can never happen. I missed it the first time, and the test hung.

The tests need a real broker, and each makes its own topic with three partitions. Create `internal/stream/stream_test.go`:

<!-- file: internal/stream/stream_test.go -->
~~~go
package stream

import (
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"runway/internal/messages"
	"runway/internal/outbox"
)

// topic creates a fresh topic with 3 partitions and returns its name and
// the brokers. The test is skipped when RUNWAY_KAFKA_BROKERS is unset.
func topic(t *testing.T) ([]string, string) {
	t.Helper()
	list := os.Getenv("RUNWAY_KAFKA_BROKERS")
	if list == "" {
		t.Skip("set RUNWAY_KAFKA_BROKERS to run Kafka tests")
	}
	brokers := strings.Split(list, ",")
	name := "test-" + strings.ToLower(rand.Text())
	if err := EnsureTopic(context.Background(), brokers, name, 3); err != nil {
		t.Fatal(err)
	}
	return brokers, name
}

// produce appends n events for each key, numbered 1 to n.
func produce(t *testing.T, brokers []string, topic string, keys []string, n int) {
	t.Helper()
	ctx := context.Background()
	producer, err := NewProducer(ctx, brokers)
	if err != nil {
		t.Fatal(err)
	}
	defer producer.Close()
	for i := 1; i <= n; i++ {
		for _, key := range keys {
			env := messages.Envelope{ID: fmt.Sprintf("%s-%d", key, i), Type: "test", Version: 1, Payload: []byte(`{}`)}
			if err := producer.Publish(ctx, outbox.Message{Destination: topic, Key: key, Envelope: env}); err != nil {
				t.Fatal(err)
			}
		}
	}
}

// consume reads as group until want messages arrived or wait passes, and
// returns the IDs it read.
func consume(t *testing.T, brokers []string, group, topic string, want int, wait time.Duration) []string {
	t.Helper()
	consumer, err := NewConsumer(brokers, group, topic, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer consumer.Close()

	ctx, cancel := context.WithTimeout(context.Background(), wait)
	defer cancel()
	var mu sync.Mutex
	var got []string
	err = consumer.Run(ctx, func(_ context.Context, msg messages.Envelope) error {
		mu.Lock()
		defer mu.Unlock()
		got = append(got, msg.ID)
		if len(got) == want {
			cancel()
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestEachKeyStaysInOrder(t *testing.T) {
	brokers, name := topic(t)
	keys := []string{"a", "b", "c", "d"}
	produce(t, brokers, name, keys, 5)

	got := consume(t, brokers, "g1", name, 20, 20*time.Second)
	if len(got) != 20 {
		t.Fatalf("read %d messages, want 20", len(got))
	}
	next := map[string]int{"a": 1, "b": 1, "c": 1, "d": 1}
	for _, id := range got {
		key, n, _ := strings.Cut(id, "-")
		if want := fmt.Sprint(next[key]); n != want {
			t.Fatalf("key %s: got message %s before %s; order: %v", key, n, want, got)
		}
		next[key]++
	}
}

// A group remembers where it got to; a new group starts from the beginning.
func TestGroupsKeepTheirOwnOffsets(t *testing.T) {
	brokers, name := topic(t)
	produce(t, brokers, name, []string{"a", "b"}, 3)

	if got := consume(t, brokers, "g1", name, 6, 20*time.Second); len(got) != 6 {
		t.Fatalf("first read: %d messages, want 6", len(got))
	}
	if got := consume(t, brokers, "g1", name, 1, 3*time.Second); len(got) != 0 {
		t.Fatalf("g1 read %v again; its offsets were committed", got)
	}
	if got := consume(t, brokers, "g2", name, 6, 20*time.Second); len(got) != 6 {
		t.Fatalf("a new group read %d messages, want all 6", len(got))
	}
}

// A failed record stops the consumer without committing, so the next run
// reads it again.
func TestAFailedRecordIsReadAgain(t *testing.T) {
	brokers, name := topic(t)
	produce(t, brokers, name, []string{"a"}, 1)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	consumer, err := NewConsumer(brokers, "g1", name, logger)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	err = consumer.Run(ctx, func(context.Context, messages.Envelope) error {
		return fmt.Errorf("database unreachable")
	})
	consumer.Close()
	if err == nil || !strings.Contains(err.Error(), "database unreachable") {
		t.Fatalf("Run returned %v, want the handler's error", err)
	}

	if got := consume(t, brokers, "g1", name, 1, 20*time.Second); len(got) != 1 {
		t.Fatalf("after the failure, read %v; want the record again", got)
	}
}
~~~

### The projection and its inbox

Create `internal/pgstore/migrations/0005_projection.sql`:

<!-- file: internal/pgstore/migrations/0005_projection.sql -->
~~~sql
-- +goose Up
-- The inbox: one row per message a consumer has handled. The primary key
-- makes "have I seen this message?" and "remember it" one atomic step.
CREATE TABLE inbox (
    consumer    TEXT        NOT NULL,
    message_id  TEXT        NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer, message_id)
);

-- A read model built from the job-events stream: how many jobs have
-- entered each state, per consumer group that built it.
CREATE TABLE job_state_counts (
    consumer TEXT   NOT NULL,
    state    TEXT   NOT NULL,
    count    BIGINT NOT NULL,
    PRIMARY KEY (consumer, state)
);

-- +goose Down
DROP TABLE job_state_counts;
DROP TABLE inbox;
~~~

The counts are kept **per consumer group**, so you can rebuild them under a new group name and compare the two side by side.

Create `internal/projection/projection.go`:

<!-- file: internal/projection/projection.go -->
~~~go
// Package projection builds a read model from the job-events stream: how
// many jobs have entered each state. Rebuilding it is a matter of reading
// the stream again from the start.
//
// Counting is not idempotent: count the same event twice and the number is
// wrong. Kafka delivers at least once, so every event passes through an
// inbox first.
package projection

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"runway/internal/messages"
)

// Projector applies events for one consumer, which names its inbox and
// its counts.
type Projector struct {
	pool     *pgxpool.Pool
	consumer string
}

func New(pool *pgxpool.Pool, consumer string) *Projector {
	return &Projector{pool: pool, consumer: consumer}
}

// Apply counts one JobChanged event, unless this consumer has already
// counted it. Recording the message in the inbox and counting it happen in
// one transaction, so a crash can't leave one done without the other.
func (p *Projector) Apply(ctx context.Context, msg messages.Envelope) error {
	var event messages.JobChanged
	if err := messages.Decode(msg, messages.TypeJobChanged, &event); err != nil {
		return err
	}
	return pgx.BeginFunc(ctx, p.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			INSERT INTO inbox (consumer, message_id) VALUES ($1, $2)
			ON CONFLICT DO NOTHING`, p.consumer, msg.ID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return nil // already counted: a redelivery
		}
		_, err = tx.Exec(ctx, `
			INSERT INTO job_state_counts (consumer, state, count) VALUES ($1, $2, 1)
			ON CONFLICT (consumer, state) DO UPDATE SET count = job_state_counts.count + 1`,
			p.consumer, event.State)
		return err
	})
}

// Counts returns how many jobs have entered each state.
func (p *Projector) Counts(ctx context.Context) (map[string]int64, error) {
	rows, err := p.pool.Query(ctx, `SELECT state, count FROM job_state_counts WHERE consumer = $1`, p.consumer)
	if err != nil {
		return nil, fmt.Errorf("read counts: %w", err)
	}
	counts := map[string]int64{}
	var state string
	var count int64
	_, err = pgx.ForEachRow(rows, []any{&state, &count}, func() error {
		counts[state] = count
		return nil
	})
	return counts, err
}
~~~

The inbox insert and the count change are one transaction. If the process dies after counting but before Kafka hears the commit, the event comes again, finds its ID in the inbox, and is skipped. The count is right, and no lock or coordination was needed. The count itself is an **upsert**: insert a row with 1, or if one exists, add 1 to it, in a single atomic statement.

Create `internal/projection/projection_test.go`:

<!-- file: internal/projection/projection_test.go -->
~~~go
package projection

import (
	"context"
	"fmt"
	"testing"
	"time"

	"runway/internal/messages"
	"runway/internal/pgstore"
	"runway/internal/pgstore/pgtest"
)

func event(t *testing.T, jobID int64, state string) messages.Envelope {
	t.Helper()
	env, err := messages.New(messages.TypeJobChanged, messages.JobChanged{JobID: jobID, State: state}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return env
}

func TestARedeliveredEventIsCountedOnce(t *testing.T) {
	ctx := context.Background()
	p := New(pgtest.Pool(t, pgstore.Migrate), "test")

	queued := event(t, 1, "queued")
	for _, msg := range []messages.Envelope{queued, queued, event(t, 2, "queued"), event(t, 1, "running")} {
		if err := p.Apply(ctx, msg); err != nil {
			t.Fatal(err)
		}
	}
	counts, err := p.Counts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(counts) != "map[queued:2 running:1]" {
		t.Fatalf("counts = %v, want map[queued:2 running:1]", counts)
	}
}

func TestConsumersCountSeparately(t *testing.T) {
	ctx := context.Background()
	pool := pgtest.Pool(t, pgstore.Migrate)
	msg := event(t, 1, "queued")
	for _, name := range []string{"v1", "v2"} {
		if err := New(pool, name).Apply(ctx, msg); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"v1", "v2"} {
		if counts, _ := New(pool, name).Counts(ctx); counts["queued"] != 1 {
			t.Fatalf("%s counts = %v, want queued:1", name, counts)
		}
	}
}
~~~

### The projector command

Create `cmd/projector/main.go`:

<!-- file: cmd/projector/main.go -->
~~~go
// Command projector reads the job-events stream from Kafka and keeps count,
// in PostgreSQL, of how many jobs have entered each state.
//
// Several projectors with the same PROJECTOR_GROUP share the topic's
// partitions between them. A projector with a new group starts from the
// beginning of the stream and rebuilds the counts from scratch.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"runway/internal/envconfig"
	"runway/internal/messages"
	"runway/internal/pgstore"
	"runway/internal/projection"
	"runway/internal/stream"
)

// Partitions is how many partitions the job-events topic gets: the most
// projectors in one group that can be busy at once.
const Partitions = 3

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer) error {
	brokers, databaseURL := getenv("KAFKA_BROKERS"), getenv("DATABASE_URL")
	if brokers == "" || databaseURL == "" {
		return errors.New("KAFKA_BROKERS and DATABASE_URL must both be set")
	}
	group := getenv("PROJECTOR_GROUP")
	if group == "" {
		group = "runway-projector"
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	pool, err := pgstore.Open(ctx, databaseURL, pgstore.PoolOptions{MaxConns: 2})
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := pgstore.Migrate(ctx, pool); err != nil {
		return err
	}

	list := strings.Split(brokers, ",")
	if err := stream.EnsureTopic(ctx, list, messages.JobEventsTopic, Partitions); err != nil {
		return err
	}
	consumer, err := stream.NewConsumer(list, group, messages.JobEventsTopic, logger)
	if err != nil {
		return err
	}
	defer consumer.Close()

	projector := projection.New(pool, group)
	logger.Info("projecting", "group", group, "topic", messages.JobEventsTopic)
	return consumer.Run(ctx, func(ctx context.Context, msg messages.Envelope) error {
		if err := projector.Apply(ctx, msg); err != nil {
			return err
		}
		logger.Info("applied", "message_id", msg.ID)
		return nil
	})
}
~~~

Create `cmd/projector/main_test.go`:

<!-- file: cmd/projector/main_test.go -->
~~~go
package main

import (
	"context"
	"io"
	"strings"
	"testing"
)

func TestRunNeedsKafkaAndPostgres(t *testing.T) {
	getenv := func(key string) string {
		return map[string]string{"KAFKA_BROKERS": "localhost:9092"}[key]
	}
	err := run(context.Background(), getenv, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "DATABASE_URL") {
		t.Fatalf("error = %v, want one naming DATABASE_URL", err)
	}
}
~~~

### The API streams its events

In `cmd/api/main.go`, add the imports. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"os/signal"
	"sync"
~~~

to:

~~~go
	"os/signal"
	"strings"
	"sync"
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/rabbit"
	"runway/internal/worker"
~~~

to:

~~~go
	"runway/internal/rabbit"
	"runway/internal/stream"
	"runway/internal/worker"
~~~

Add the setting. Events reach Kafka only through the outbox, so Kafka without a database is a configuration mistake, and the API says so. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	DatabaseURL      string
	DBMaxConns       int
~~~

to:

~~~go
	DatabaseURL      string
	KafkaBrokers     []string
	DBMaxConns       int
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), DatabaseURL: getenv("DATABASE_URL")}
	var err error
~~~

to:

~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), DatabaseURL: getenv("DATABASE_URL")}
	if brokers := getenv("KAFKA_BROKERS"); brokers != "" {
		if cfg.DatabaseURL == "" {
			return config{}, errors.New("KAFKA_BROKERS needs DATABASE_URL: events reach Kafka through the outbox")
		}
		cfg.KafkaBrokers = strings.Split(brokers, ",")
	}
	var err error
~~~

Add a function to connect, before `run`. Change:

<!-- edit: cmd/api/main.go -->
~~~go
// run starts the API and its consumers, blocks until ctx is cancelled or the
~~~

to:

~~~go
// connectStream returns a producer for the job-events topic, or nil when
// KAFKA_BROKERS is unset.
func connectStream(ctx context.Context, cfg config) (*stream.Producer, error) {
	if cfg.KafkaBrokers == nil {
		return nil, nil
	}
	if err := stream.EnsureTopic(ctx, cfg.KafkaBrokers, messages.JobEventsTopic, 3); err != nil {
		return nil, err
	}
	return stream.NewProducer(ctx, cfg.KafkaBrokers)
}

// run starts the API and its consumers, blocks until ctx is cancelled or the
~~~

In `run`, connect after the database, and tell the store whether to stream. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	var service *jobs.Service
	if pool == nil {
~~~

to:

~~~go
	producer, err := connectStream(ctx, cfg)
	if err != nil {
		return err
	}
	if producer != nil {
		defer producer.Close()
	}
	var service *jobs.Service
	if pool == nil {
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
pgstore.WithOutbox(eventing.OutboxMessages)
~~~

to:

~~~go
pgstore.WithOutbox(eventing.OutboxMessages(producer != nil))
~~~

The relay now sends to two places, chosen by each message's destination. Change:

<!-- edit: cmd/api/main.go -->
~~~go
		relay := outbox.NewRelay(pool, outbox.PublisherFunc(func(ctx context.Context, msg outbox.Message) error {
			return publisher.Publish(ctx, msg.Destination, msg.Envelope)
		}), 100, cfg.OutboxInterval, logger)
~~~

to:

~~~go
		// Commands go to the message bus; job events go to Kafka.
		relay := outbox.NewRelay(pool, outbox.PublisherFunc(func(ctx context.Context, msg outbox.Message) error {
			if msg.Destination == messages.JobEventsTopic {
				return producer.Publish(ctx, msg)
			}
			return publisher.Publish(ctx, msg.Destination, msg.Envelope)
		}), 100, cfg.OutboxInterval, logger)
~~~

Finally, report what the API is connected to. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	logger.Info("listening", "addr", listener.Addr().String(), "bus", busName(cfg), "in_process_workers", workers)
~~~

to:

~~~go
	logger.Info("listening", "addr", listener.Addr().String(), "bus", busName(cfg), "in_process_workers", workers,
		"database", pool != nil, "kafka", producer != nil)
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

~~~bash
go test -v ./internal/stream/
~~~

~~~text
--- PASS: TestEachKeyStaysInOrder (3.21s)
--- PASS: TestGroupsKeepTheirOwnOffsets (9.52s)
--- PASS: TestAFailedRecordIsReadAgain (6.19s)
ok  	runway/internal/stream	18.923s
~~~

Most of those seconds are spent **joining groups**: each new consumer waits for the group coordinator to assign it partitions. Remember that when a consumer is slow to start in production.

### Run it: two projectors, then a replay

Start the API with Kafka, and two projectors in the same group, a few seconds apart, in separate terminals:

~~~bash
export DATABASE_URL=postgres://runway:runway@localhost:5432/runway KAFKA_BROKERS=localhost:9092
go run ./cmd/api &
go run ./cmd/projector     # terminal 2
go run ./cmd/projector     # terminal 3, a few seconds later
~~~

Watch the partitions move (log lines trimmed to the interesting fields):

~~~text
projector 1: {"msg":"partitions assigned","topic":"runway.job-events","partitions":[0,1,2]}
projector 1: {"msg":"partitions revoked","topic":"runway.job-events","partitions":[2]}
projector 2: {"msg":"partitions assigned","topic":"runway.job-events","partitions":[2]}
~~~

The first projector had all three partitions. When the second joined, the group took **only partition 2** away and gave it to the newcomer; partitions 0 and 1 never stopped. Now create six jobs and look at the result and at the group:

~~~bash
for i in $(seq 6); do curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"stream","duration_ms":50}'; done
docker compose exec postgres psql -U runway -c "SELECT consumer, state, count FROM job_state_counts ORDER BY consumer, state"
docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group runway-projector
~~~

~~~text
     consumer     |   state   | count 
------------------+-----------+-------
 runway-projector | completed |     7
 runway-projector | queued    |     6
 runway-projector | running   |     7
(3 rows)

TOPIC              PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID
runway.job-events  0          8               8               0    kgo-4af64919-...
runway.job-events  1          6               6               0    kgo-4af64919-...
runway.job-events  2          6               6               0    kgo-c6b7cd2c-...
~~~

(The `kafka-consumer-groups.sh` output has more columns; these are the interesting ones.) Lag is 0 on every partition, and two consumer IDs share the three partitions. **Why 7 `running` but only 6 `queued`?** In my run, job 207 from step 5 was still in the outbox when that API was stopped. This API's relay sent its command, so it ran now, and its `running` and `completed` events reached the stream, but its `queued` event was written before Kafka was switched on. Events that happened before a stream existed aren't in it. That's worth remembering when someone builds a report from a stream that started last Tuesday.

Read the raw records of one partition:

~~~bash
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic runway.job-events \
  --partition 0 --offset earliest --max-messages 3 --property print.key=true --property print.offset=true --property print.partition=true
~~~

~~~text
Partition:0	Offset:0	207	{"id":"JMDGAXMNWFFT5C7EOE2N6FMUZ6","type":"jobs.job_changed","version":1,"occurred_at":"2026-10-05T19:33:07.874748019Z","payload":{"state":"running","job_id":207}}
Partition:0	Offset:1	207	{"id":"R4GS3EIPPRA7P3WXNHSUEEVEOA","type":"jobs.job_changed","version":1,"occurred_at":"2026-10-05T19:33:07.884121771Z","payload":{"state":"completed","job_id":207}}
Partition:0	Offset:2	208	{"id":"YLUL737NQ6MBBU4NU3O3CL647Z","type":"jobs.job_changed","version":1,"occurred_at":"2026-10-05T19:33:20.771249Z","payload":{"state":"queued","job_id":208}}
Processed a total of 3 messages
~~~

Reading them didn't remove them: the projectors already read these, and here they are again. (The payload's keys are in a different order from the Go struct because the outbox stored them as `JSONB`.)

Now stop **both** projectors and create three more jobs. Then look at the group again:

~~~text
TOPIC              PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
runway.job-events  0          8               11              3
runway.job-events  2          6               9               3
runway.job-events  1          6               9               3
~~~

Nobody is reading, and the events wait in the log. That's lag, building up. Now **replay**: start a projector under a brand-new group name. It has no committed offsets, so it starts from the oldest record:

~~~bash
PROJECTOR_GROUP=runway-projector-v2 go run ./cmd/projector
~~~

Give it ten seconds, stop it, then start the original group's projector again (`go run ./cmd/projector`) and let it catch up:

~~~text
      consumer       |   state   | count 
---------------------+-----------+-------
 runway-projector    | completed |    10
 runway-projector    | queued    |     9
 runway-projector    | running   |    10
 runway-projector-v2 | completed |    10
 runway-projector-v2 | queued    |     9
 runway-projector-v2 | running   |    10
(6 rows)
~~~

The new group rebuilt the read model **from nothing** and got the same answer as the group that built it incrementally. The original group carried on from its committed offsets and caught up on the nine events it had missed. That's what a log gives you and a queue can't: you can add a reader later, fix a bug in a projection and rebuild it, or compare two versions side by side.

**Break it: no inbox.** In `Apply`, delete the three lines that return early when the inbox insert affected no rows (`if tag.RowsAffected() == 0 { ... }`), and replace them with `_ = tag` so the code still compiles:

~~~text
--- FAIL: TestARedeliveredEventIsCountedOnce (0.14s)
    projection_test.go:38: counts = map[queued:3 running:1], want map[queued:2 running:1]
~~~

The redelivered event was counted twice. In production nothing would fail: the dashboard would just be slightly, silently wrong, forever. Restore the check.

**Ordering, as promised.** One job's events are in order *in Kafka* only if they were *sent* in order. One relay sends in outbox order, but step 4 let several relays run in parallel, and their batches can interleave. So with several API instances, job 7's `completed` could reach Kafka before its `running`. The counts don't care, because they're order-independent. A consumer that does care must either tolerate it (compare the envelope's `occurred_at`; ignore an older state that arrives late), or the system must have **one** relay at a time per key. Step 8 introduces the tool that does the second: an advisory lock held by one instance.

**Explain it:** what does a consumer group's committed offset record, and what happens when a member leaves? Why key events by job ID? Why does counting need an inbox when Runway's job handlers didn't? Name two things a log can do that a queue can't.

**Read.** Jay Kreps, *The Log: What every software engineer should know about real-time data's unifying abstraction*. Then DDIA Ch. 11, *Partitioned Logs* and *Databases and Streams*, and the Kafka documentation's *Design* section on consumer position. Carry this question in: Runway's tables and its event stream both describe the same jobs. Which one is the truth?

---

## Step 7: Redis, cache-aside

**The problem.** Clients poll. A dashboard showing 200 jobs asks `GET /jobs/{id}` for each of them every few seconds, and so does every person who has it open. Every one of those reads goes to PostgreSQL, uses a pooled connection, and competes with the writes that matter. Most of the answers are identical to the last ones, because a finished job never changes again.

**New ideas.**

- **Redis** is an in-memory key-value server: you `SET` a key to a value (optionally with a **TTL**, a time to live after which Redis deletes it) and `GET` it back, typically in well under a millisecond. It keeps everything in RAM, which is why it's fast and why it's a **cache**, not the source of truth.
- **Cache-aside** (also called *lazy loading*): the application talks to both stores itself.
  - **Read:** look in the cache. On a **hit**, done. On a **miss**, read the database and store a copy in the cache.
  - **Write:** write the database, then **delete** the cached copy, so the next read loads the new version.

  You delete rather than overwrite because of a race between two writers. Writer A stores version 2 in the database; writer B stores version 3 and then writes 3 to the cache; A, delayed, then writes 2 to the cache. Now the cache holds an old version, with no expiry in sight. Deleting can't put an old version back.
- **The race that remains.** A reader misses and loads version 1. A writer stores version 2 and deletes the key. The reader, slower, then caches version 1. Reads now return version 1 until the TTL expires. You can't close this window cheaply, so you **bound** it: the TTL is the most stale a read can ever be. Runway's domain helps here. A finished job never changes, so it's safe to keep for an hour; an unfinished one gets a TTL of a few seconds.
- A **cache stampede** (or *thundering herd*): a popular key expires, and a hundred requests miss at the same instant. All hundred query the database at once, which is the very load the cache was supposed to absorb. **Singleflight** collapses concurrent loads of the same key into one: the first caller does the work, and the others wait and share its result.
- **Fail open.** A cache is an optimisation. If Redis is down, Runway must still answer, just more slowly, straight from the database. So every Redis call has a short timeout of its own, and goes through a **circuit breaker** (Phase 2's): after a few failures the cache steps aside completely, instead of making every request wait for a dead Redis first.
- **Versioned keys.** The key includes `v1`. If the stored shape ever changes, the new code uses `v2` and never reads entries written by the old code.

### Run Redis

Add it to `compose.yaml`. Change:

<!-- edit: compose.yaml -->
~~~yaml
volumes:
  pgdata:
~~~

to:

~~~yaml
  redis:
    image: redis:8
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 5s
      retries: 20

volumes:
  pgdata:
~~~

~~~bash
docker compose up -d --wait redis
~~~

Get the client and singleflight:

<!-- run: go get github.com/redis/go-redis/v9@v9.22.0 golang.org/x/sync@v0.23.0 -->
~~~bash
go get github.com/redis/go-redis/v9@v9.22.0 golang.org/x/sync@v0.23.0
~~~

### A caching decorator

The cache is a **decorator**: it implements `jobs.Repository` by wrapping another `jobs.Repository`. The service can't tell it's there. Create `internal/cache/cache.go`:

<!-- file: internal/cache/cache.go -->
~~~go
// Package cache keeps recently read jobs in Redis, so that most reads
// never reach PostgreSQL.
//
// It is cache-aside: a read looks in Redis first; on a miss it loads the
// job from the database and stores a copy. A write goes to the database,
// then deletes the copy, so the next read loads the new version.
package cache

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"
	"golang.org/x/sync/singleflight"

	"runway/internal/breaker"
	"runway/internal/jobs"
)

// Options tunes the cache.
type Options struct {
	// Prefix starts every key. Change its version when the stored shape
	// changes, so new code never reads copies written by old code.
	Prefix string
	// TTL is how long a job that can still change is kept. It bounds how
	// stale a read can be (see the race described on Get).
	TTL time.Duration
	// FinishedTTL is how long a completed or failed job is kept. Those
	// never change again, so they can be kept much longer.
	FinishedTTL time.Duration
	// Timeout limits each call to Redis. A cache that answers slower than
	// the database isn't worth asking, and a hung Redis mustn't use up the
	// request's whole deadline.
	Timeout time.Duration
}

// Repository wraps a jobs.Repository with a cache. It is a decorator: it
// implements the same interface, so nothing above it changes.
type Repository struct {
	next    jobs.Repository
	client  *redis.Client
	breaker *breaker.Breaker
	opts    Options
	loads   singleflight.Group

	requests *prometheus.CounterVec
}

// New wraps next. Calls to Redis go through b: when Redis keeps failing,
// the cache steps aside and every read goes straight to the database. A
// cache is an optimisation, so losing it must never fail a request.
func New(next jobs.Repository, client *redis.Client, b *breaker.Breaker, opts Options) *Repository {
	return &Repository{
		next:    next,
		client:  client,
		breaker: b,
		opts:    opts,
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "cache_requests_total",
			Help: "Cache lookups by result: hit, miss, error, or skipped while the breaker is open.",
		}, []string{"result"}),
	}
}

// Collectors returns the cache's metrics, for registration.
func (r *Repository) Collectors() []prometheus.Collector {
	return []prometheus.Collector{r.requests}
}

func (r *Repository) key(id jobs.ID) string {
	return r.opts.Prefix + strconv.FormatInt(int64(id), 10)
}

// Create doesn't touch the cache: the first Get will load the new job.
func (r *Repository) Create(ctx context.Context, job jobs.Job) (jobs.Job, error) {
	return r.next.Create(ctx, job)
}

// Update writes to the database first, then deletes the cached copy.
// Deleting (not overwriting) means a slow writer can never put an older
// version back over a newer one.
func (r *Repository) Update(ctx context.Context, job jobs.Job, expected jobs.State) error {
	if err := r.next.Update(ctx, job, expected); err != nil {
		return err
	}
	_ = r.call(ctx, func(ctx context.Context) error {
		return r.client.Del(ctx, r.key(job.ID)).Err()
	})
	return nil
}

// Get returns the cached job, or loads it from the database.
//
// A stampede is many requests missing the same key at once, and all of
// them loading it. singleflight lets the first one load it while the
// others wait and share its result.
//
// One race remains. A reader loads version 1; a writer stores version 2
// and deletes the key; the reader then caches version 1. Reads now see
// version 1 until the TTL expires. That is why unfinished jobs get a
// short TTL: it bounds how stale a read can be.
func (r *Repository) Get(ctx context.Context, id jobs.ID) (jobs.Job, error) {
	if job, ok := r.lookup(ctx, id); ok {
		return job, nil
	}
	loaded, err, _ := r.loads.Do(r.key(id), func() (any, error) {
		// A load that finished a moment ago may have filled the cache
		// after this caller's lookup missed. Check once more before
		// going to the database.
		if job, ok, err := r.cached(ctx, id); err == nil && ok {
			return job, nil
		}
		job, err := r.next.Get(ctx, id)
		if err != nil {
			return nil, err
		}
		r.store(ctx, job)
		return job, nil
	})
	if err != nil {
		return jobs.Job{}, err
	}
	return loaded.(jobs.Job), nil
}

// lookup returns the cached job, if there is one, and counts the result.
func (r *Repository) lookup(ctx context.Context, id jobs.ID) (jobs.Job, bool) {
	job, ok, err := r.cached(ctx, id)
	switch {
	case errors.Is(err, breaker.ErrOpen):
		r.requests.WithLabelValues("skipped").Inc()
	case err != nil:
		r.requests.WithLabelValues("error").Inc()
	case !ok:
		r.requests.WithLabelValues("miss").Inc()
	default:
		r.requests.WithLabelValues("hit").Inc()
	}
	return job, ok
}

// cached reads the job's copy from Redis. ok is false on a miss.
func (r *Repository) cached(ctx context.Context, id jobs.ID) (job jobs.Job, ok bool, err error) {
	var data []byte
	err = r.call(ctx, func(ctx context.Context) error {
		var err error
		data, err = r.client.Get(ctx, r.key(id)).Bytes()
		if errors.Is(err, redis.Nil) {
			return nil // a miss is a healthy answer, not a failure
		}
		return err
	})
	if err != nil || data == nil {
		return jobs.Job{}, false, err
	}
	if err := json.Unmarshal(data, &job); err != nil {
		return jobs.Job{}, false, err
	}
	return job, true, nil
}

func (r *Repository) store(ctx context.Context, job jobs.Job) {
	data, err := json.Marshal(job)
	if err != nil {
		return
	}
	ttl := r.opts.TTL
	if job.State == jobs.StateCompleted || job.State == jobs.StateFailed {
		ttl = r.opts.FinishedTTL
	}
	_ = r.call(ctx, func(ctx context.Context) error {
		return r.client.Set(ctx, r.key(job.ID), data, ttl).Err()
	})
}

// call runs one Redis command through the breaker, with its own short
// timeout. It ignores ctx's cancellation, so a write that already reached
// the database still updates the cache when the client has gone away.
func (r *Repository) call(ctx context.Context, fn func(context.Context) error) error {
	return r.breaker.Do(func() error {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), r.opts.Timeout)
		defer cancel()
		return fn(ctx)
	})
}

// Ping checks that Redis answers, for start-up.
func Ping(ctx context.Context, client *redis.Client) error {
	if err := client.Ping(ctx).Err(); err != nil {
		return fmt.Errorf("connect to Redis: %w", err)
	}
	return nil
}

var _ jobs.Repository = (*Repository)(nil)
~~~

Read `Get` from the top:
1. `lookup` asks Redis, through the breaker, with its own timeout. A miss (`redis.Nil`) is a healthy answer, not a failure, so it doesn't count against the breaker.
2. On a miss, `singleflight.Group.Do` runs the load once per key, however many goroutines ask at the same moment. Inside it, the cache is checked **once more**. A goroutine can miss, then be delayed just long enough that the first load has already finished and filled the cache; without the second check it would start a load of its own. This guide's own CI run hit exactly that once, under load: the stampede test saw 2 database reads instead of 1. `lookup` counts metrics; `cached` is the quiet read underneath it, so the second check doesn't inflate the miss count.
3. The loaded job is stored with a TTL that depends on whether it can still change.

`ErrNotFound` is never cached. Caching "this doesn't exist" (**negative caching**) is a separate decision with its own staleness question: what happens when the job is created a moment later?

One honest limitation of singleflight: the waiters share the **leader's** context. If the leader's request is cancelled, every waiter gets its error too. For loads this short, that's acceptable; `DoChan` lets each waiter stop waiting on its own deadline, if you ever need it.

Test it against a real Redis. The decorator must pass the **same repository contract** as everything else. Create `internal/cache/cache_test.go`:

<!-- file: internal/cache/cache_test.go -->
~~~go
package cache

import (
	"context"
	"crypto/rand"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"

	"runway/internal/breaker"
	"runway/internal/jobs"
	"runway/internal/jobs/jobstest"
	"runway/internal/memstore"
)

// counting wraps a repository and counts Gets, so tests can see how many
// reads reached the database. delay makes each Get slow.
type counting struct {
	jobs.Repository
	gets  atomic.Int32
	delay time.Duration
	hold  chan struct{} // if set, every Get waits until it is closed
}

func (c *counting) Get(ctx context.Context, id jobs.ID) (jobs.Job, error) {
	c.gets.Add(1)
	if c.hold != nil {
		<-c.hold
	}
	time.Sleep(c.delay)
	return c.Repository.Get(ctx, id)
}

// client connects to RUNWAY_REDIS_URL, or skips the test.
func client(t *testing.T) *redis.Client {
	t.Helper()
	url := os.Getenv("RUNWAY_REDIS_URL")
	if url == "" {
		t.Skip("set RUNWAY_REDIS_URL to run Redis tests")
	}
	opts, err := redis.ParseURL(url)
	if err != nil {
		t.Fatal(err)
	}
	c := redis.NewClient(opts)
	t.Cleanup(func() { c.Close() })
	return c
}

// newCache wraps next with a cache whose keys are unique to this test.
func newCache(t *testing.T, c *redis.Client, next jobs.Repository) *Repository {
	return New(next, c, breaker.New(3, time.Minute, time.Now), Options{
		Prefix:      "test:" + strings.ToLower(rand.Text()) + ":job:",
		TTL:         time.Minute,
		FinishedTTL: time.Hour,
		Timeout:     100 * time.Millisecond,
	})
}

func create(t *testing.T, repo jobs.Repository) jobs.Job {
	t.Helper()
	job, _ := jobs.New("resize", time.Second, time.Now().UTC())
	job, err := repo.Create(context.Background(), job)
	if err != nil {
		t.Fatal(err)
	}
	return job
}

// The cache is a repository like any other: it must pass the same contract.
func TestContract(t *testing.T) {
	c := client(t)
	jobstest.Run(t, func(t *testing.T) jobs.Repository {
		return newCache(t, c, memstore.New())
	})
}

func TestSecondReadIsServedFromRedis(t *testing.T) {
	db := &counting{Repository: memstore.New()}
	repo := newCache(t, client(t), db)
	job := create(t, repo)

	for range 3 {
		if _, err := repo.Get(context.Background(), job.ID); err != nil {
			t.Fatal(err)
		}
	}
	if n := db.gets.Load(); n != 1 {
		t.Fatalf("the database was read %d times, want 1", n)
	}
}

func TestUpdateDeletesTheCachedCopy(t *testing.T) {
	ctx := context.Background()
	repo := newCache(t, client(t), memstore.New())
	job := create(t, repo)
	_, _ = repo.Get(ctx, job.ID) // now cached as queued

	_ = job.Start(time.Now().UTC())
	if err := repo.Update(ctx, job, jobs.StateQueued); err != nil {
		t.Fatal(err)
	}
	if got, _ := repo.Get(ctx, job.ID); got.State != jobs.StateRunning {
		t.Fatalf("read %s after the update, want running", got.State)
	}
}

// 100 requests miss the same job at once. Only one may load it.
func TestAStampedeLoadsOnce(t *testing.T) {
	// The database load is held until every reader has started, so all of
	// them arrive while it is in progress, however busy the machine. (A
	// fixed delay assumes they all start within it, and on a loaded
	// machine some don't.) The cache write gets a generous timeout for the
	// same reason.
	db := &counting{Repository: memstore.New(), hold: make(chan struct{})}
	repo := newCache(t, client(t), db)
	repo.opts.Timeout = time.Second
	job := create(t, repo)

	var wg, started sync.WaitGroup
	for range 100 {
		wg.Add(1)
		started.Add(1)
		go func() {
			defer wg.Done()
			started.Done()
			if _, err := repo.Get(context.Background(), job.ID); err != nil {
				t.Error(err)
			}
		}()
	}
	started.Wait()
	time.Sleep(100 * time.Millisecond) // from "started" to inside Get
	close(db.hold)
	wg.Wait()
	if n := db.gets.Load(); n != 1 {
		t.Fatalf("the database was read %d times, want 1", n)
	}
}

// With Redis unreachable, reads still work, and once the breaker opens
// they stop trying Redis at all.
func TestReadsSurviveRedisBeingDown(t *testing.T) {
	down := redis.NewClient(&redis.Options{Addr: "127.0.0.1:1", MaxRetries: -1})
	defer down.Close()
	repo := newCache(t, down, memstore.New())
	job := create(t, repo)

	for range 5 {
		if _, err := repo.Get(context.Background(), job.ID); err != nil {
			t.Fatalf("read failed because the cache is down: %v", err)
		}
	}
	if state := repo.breaker.State(); state != breaker.Open {
		t.Fatalf("breaker is %s, want open", state)
	}
}
~~~

`counting` is a tiny decorator of its own: it counts how many reads reach the "database" underneath. `127.0.0.1:1` is a port where nothing listens, so connecting fails at once: a stand-in for a Redis that's down.

### Put it in front of PostgreSQL

In `cmd/api/main.go`, add the imports. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"github.com/prometheus/client_golang/prometheus"
	"google.golang.org/grpc"
~~~

to:

~~~go
	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc"
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/bus"
	"runway/internal/envconfig"
~~~

to:

~~~go
	"runway/internal/bus"
	"runway/internal/cache"
	"runway/internal/envconfig"
~~~

Add the settings. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	KafkaBrokers     []string
	DBMaxConns       int
~~~

to:

~~~go
	KafkaBrokers     []string
	RedisURL         string
	CacheTTL         time.Duration
	CacheTimeout     time.Duration
	DBMaxConns       int
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), DatabaseURL: getenv("DATABASE_URL")}
~~~

to:

~~~go
	cfg := config{AMQPURL: getenv("AMQP_URL"), DatabaseURL: getenv("DATABASE_URL"), RedisURL: getenv("REDIS_URL")}
	if cfg.RedisURL != "" && cfg.DatabaseURL == "" {
		return config{}, errors.New("REDIS_URL needs DATABASE_URL: the cache sits in front of PostgreSQL")
	}
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
~~~

to:

~~~go
	if cfg.CacheTTL, err = envconfig.Duration(getenv, "CACHE_TTL", 5*time.Second); err != nil {
		return config{}, err
	}
	if cfg.CacheTimeout, err = envconfig.Duration(getenv, "CACHE_TIMEOUT", 50*time.Millisecond); err != nil {
		return config{}, err
	}
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
~~~

Add a function that wraps a repository when Redis is configured. Change:

<!-- edit: cmd/api/main.go -->
~~~go
// run starts the API and its consumers, blocks until ctx is cancelled or the
~~~

to:

~~~go
// withCache puts a Redis cache in front of repo when REDIS_URL is set. It
// returns a function that closes the Redis client.
func withCache(ctx context.Context, cfg config, repo jobs.Repository, metrics *httpapi.Metrics) (jobs.Repository, func(), error) {
	if cfg.RedisURL == "" {
		return repo, func() {}, nil
	}
	opts, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		return nil, nil, fmt.Errorf("parse REDIS_URL: %w", err)
	}
	client := redis.NewClient(opts)
	if err := cache.Ping(ctx, client); err != nil {
		client.Close()
		return nil, nil, err
	}
	cacheBreaker := breaker.New(cfg.BreakerThreshold, cfg.BreakerCooldown, time.Now)
	cached := cache.New(repo, client, cacheBreaker, cache.Options{
		Prefix:      "runway:job:v1:",
		TTL:         cfg.CacheTTL,
		FinishedTTL: time.Hour,
		Timeout:     cfg.CacheTimeout,
	})
	metrics.MustRegister(cached.Collectors()...)
	metrics.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "cache_breaker_state",
		Help: "The cache circuit breaker: 0 closed, 1 open, 2 half-open.",
	}, func() float64 { return float64(cacheBreaker.State()) }))
	return cached, func() { client.Close() }, nil
}

// run starts the API and its consumers, blocks until ctx is cancelled or the
~~~

Use it. Change:

<!-- edit: cmd/api/main.go -->
~~~go
		service = jobs.NewService(pgstore.New(pool, pgstore.WithOutbox(eventing.OutboxMessages(producer != nil))))
~~~

to:

~~~go
		repo, closeCache, err := withCache(ctx, cfg, pgstore.New(pool, pgstore.WithOutbox(eventing.OutboxMessages(producer != nil))), metrics)
		if err != nil {
			return err
		}
		defer closeCache()
		service = jobs.NewService(repo)
~~~

and report it. Change:

<!-- edit: cmd/api/main.go -->
~~~go
		"database", pool != nil, "kafka", producer != nil)
~~~

to:

~~~go
		"database", pool != nil, "kafka", producer != nil, "cache", cfg.RedisURL != "")
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

### Run it

Start the API with the cache, create one job, read it five times, and look inside Redis:

~~~bash
export DATABASE_URL=postgres://runway:runway@localhost:5432/runway REDIS_URL=redis://localhost:6379/0
go run ./cmd/api &
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"cache me","duration_ms":100}'
for i in 1 2 3 4 5; do curl -s -o /dev/null http://127.0.0.1:8080/jobs/217; done
curl -s http://127.0.0.1:8080/metrics | grep '^cache_'
docker compose exec redis redis-cli --scan --pattern 'runway:job:*'
docker compose exec redis redis-cli TTL runway:job:v1:217
docker compose exec redis redis-cli GET runway:job:v1:217
~~~

Use your own job's ID. Mine was 217:

~~~text
cache_breaker_state 0
cache_requests_total{result="hit"} 4
cache_requests_total{result="miss"} 3
runway:job:v1:217
3599
{"ID":217,"Description":"cache me","Duration":100000000,"State":"completed","FailureReason":"","CreatedAt":"2026-10-05T19:36:03.097528Z","UpdatedAt":"2026-10-05T19:36:03.281064Z"}
~~~

Five reads, four hits, but **three** misses. The two extra misses aren't yours: the in-process worker's `MarkStarted` and `MarkCompleted` each read the job through the same repository. Each change also deleted the key, so the next read missed. The finished job is now cached with nearly an hour to live (`TTL` reports seconds). The value is plain JSON of `jobs.Job`; `Duration` is in nanoseconds, Go's unit.

Now stop Redis and keep reading:

~~~bash
docker compose stop redis
for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://127.0.0.1:8080/jobs/217; done
~~~

~~~text
200 0.104314s
200 0.103908s
200 0.052556s
200 0.001757s
200 0.001901s
200 0.001604s
200 0.001565s
200 0.001601s
~~~

Every read succeeded. The first two each paid two 50 ms timeouts (the lookup and the store). The third paid one, and its failure opened the breaker (five failures in a row, `BREAKER_THRESHOLD`). After that, reads skipped Redis entirely and went to PostgreSQL in under 2 ms:

~~~text
cache_breaker_state 1
cache_requests_total{result="error"} 3
cache_requests_total{result="hit"} 4
cache_requests_total{result="miss"} 3
cache_requests_total{result="skipped"} 5
~~~

Start Redis again (`docker compose start redis`) and wait out the cooldown (10 s). The next read is the breaker's half-open trial; it succeeds and the cache is back: `cache_breaker_state 0`, and the hits count up again. (Redis even still has the key: it saved its data to disk when it was stopped.)

**Break it: no singleflight.** In `Get`, replace the `r.loads.Do(...)` call and the lines after it with a direct load:

~~~go
	job, err := r.next.Get(ctx, id)
	if err != nil {
		return jobs.Job{}, err
	}
	r.store(ctx, job)
	return job, nil
~~~

~~~text
--- FAIL: TestAStampedeLoadsOnce (0.11s)
    cache_test.go:127: the database was read 100 times, want 1
~~~

A hundred concurrent misses, a hundred database reads. Imagine that for your most popular key, every time it expires. Restore `loads.Do`.

**Explain it:** why does a write delete the cached copy instead of updating it? Draw the race that still lets a stale value in, and say what bounds it. What is a stampede, and how does singleflight stop it? Why must a cache "fail open", and what makes it fail *fast*?

**Read.** The AWS whitepaper *Database Caching Strategies Using Redis*, the section on caching patterns, and *Scaling Memcache at Facebook* (NSDI 2013), §3.2.1 on leases. Carry this question in: Facebook's leases solve both the stale-set race and the stampede. How?

---

## Step 8: Background jobs

**The problem.** Some work belongs to no request:
- sent outbox rows pile up forever;
- expired idempotency keys pile up (only the ones reused get cleaned);
- and some jobs get **stuck**.

Here's how a job gets stuck. A worker reports `running`, then its machine dies, and RabbitMQ eventually gives up on the command (its delivery limit), or the command was in a memory bus that died with its process. The job says `running` forever, and a client polling it waits forever.

Phase 2 already had one background job, sweeping keys, as a hand-written goroutine with a ticker. Now there are several, and they share a new problem: **every API instance runs them**. Ten instances, ten sweeps a minute, all deleting the same rows at the same moment.

**New ideas.**

- A **background job** (or *maintenance task*) is periodic work a service does on its own schedule. It needs:
  - a schedule, plus **jitter**, so instances started together don't all fire at once;
  - an error policy, so one failure doesn't stop the next run;
  - a **panic** policy: a panic in a goroutine nobody waits on kills the whole process;
  - visibility: a log line and metrics for each run.
- **Idempotent, resumable tasks.** Write every task so that running it twice is harmless and stopping it halfway is fine, because the next run carries on. Then the scheduling around it can be simple.
- **Batching.** Delete or update in chunks (`LIMIT 1000`), not all at once. One giant `DELETE` holds locks and writes write-ahead log for a long time; a thousand small ones let other work in between.
- **Advisory locks, again.** To stop instances doing the same round of work at the same time, each run first tries to take a lock named after the task. `pg_try_advisory_xact_lock` doesn't wait: it returns `false` at once if someone else holds the lock, and the lock is released when the transaction ends, even if the process holding it crashes. This is a small **distributed lock**. Phase 4 shows where locks like this break and what a **lease** adds.
- **The reaper** finds `running` jobs with no change for longer than `ABANDON_AFTER` and fails them with a clear reason. It goes through the service, so the change gets its history event and outbox messages like any other. If the worker reports back at the last moment, compare-and-swap decides: the first outcome wins. Choose `ABANDON_AFTER` longer than any legitimate run, including retries. Otherwise you'll fail jobs that were about to succeed.
- **Indexes.** Without an index, a query that filters rows reads the **whole table**: a **sequential scan**. A **B-tree index** is a sorted structure the database keeps alongside the table, and lookups and ranges in it take a few page reads instead of millions. Every index costs disk space and makes every write slower, because the index must be updated too. A **partial index** (`WHERE state = 'running'`) indexes only the rows a query actually looks for.
- **`EXPLAIN ANALYZE`** runs a query and shows the **plan** the database chose (which scans, which joins, in what order) with real timings and row counts. It's the first tool to reach for when a query is slow.
- **`CREATE INDEX CONCURRENTLY`** builds an index without blocking writes to the table. It can't run inside a transaction, so goose must be told not to wrap the migration in one.

### A runner for periodic tasks

Create `internal/background/background.go`:

<!-- file: internal/background/background.go -->
~~~go
// Package background runs periodic maintenance tasks inside a service:
// deleting expired rows, failing abandoned jobs. Each task runs on its own
// timer until the service shuts down.
package background

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// Task is one periodic job. Run returns how many items it handled. A task
// must be safe to run twice in a row, and safe to stop halfway: the next
// run picks up whatever is left.
type Task struct {
	Name  string
	Every time.Duration
	Run   func(ctx context.Context) (int, error)
}

// Runner runs tasks and records how each run went.
type Runner struct {
	logger *slog.Logger
	runs   *prometheus.CounterVec
	items  *prometheus.CounterVec
	wg     sync.WaitGroup
}

func New(logger *slog.Logger) *Runner {
	return &Runner{
		logger: logger,
		runs: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "background_task_runs_total",
			Help: "Background task runs, by task and result (ok, error or panic).",
		}, []string{"task", "result"}),
		items: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "background_task_items_total",
			Help: "Items handled by background tasks.",
		}, []string{"task"}),
	}
}

func (r *Runner) Collectors() []prometheus.Collector {
	return []prometheus.Collector{r.runs, r.items}
}

// Start runs each task every task.Every until ctx is done. The first run
// waits a random part of the interval, so instances that start together
// don't all run their tasks at the same moment.
func (r *Runner) Start(ctx context.Context, tasks ...Task) {
	for _, task := range tasks {
		r.wg.Add(1)
		go func() {
			defer r.wg.Done()
			wait := rand.N(task.Every)
			for {
				select {
				case <-ctx.Done():
					return
				case <-time.After(wait):
				}
				r.runOnce(ctx, task)
				wait = task.Every
			}
		}()
	}
}

// Wait blocks until every task has stopped.
func (r *Runner) Wait() { r.wg.Wait() }

// runOnce runs a task, and turns a panic into a logged failure: a panic in
// a goroutine nobody waits on would otherwise end the whole process.
func (r *Runner) runOnce(ctx context.Context, task Task) {
	defer func() {
		if p := recover(); p != nil {
			r.runs.WithLabelValues(task.Name, "panic").Inc()
			r.logger.Error("background task panicked", "task", task.Name, "panic", fmt.Sprint(p))
		}
	}()
	n, err := task.Run(ctx)
	if err != nil {
		r.runs.WithLabelValues(task.Name, "error").Inc()
		if ctx.Err() == nil {
			r.logger.Warn("background task failed", "task", task.Name, "error", err)
		}
		return
	}
	r.runs.WithLabelValues(task.Name, "ok").Inc()
	r.items.WithLabelValues(task.Name).Add(float64(n))
	if n > 0 {
		r.logger.Info("background task done", "task", task.Name, "items", n)
	}
}
~~~

`rand.N(task.Every)` picks the first delay uniformly between zero and one interval: that's the jitter. Create `internal/background/background_test.go`:

<!-- file: internal/background/background_test.go -->
~~~go
package background

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

func TestTasksRunRepeatedlyUntilStopped(t *testing.T) {
	runner := New(slog.New(slog.NewTextHandler(&syncBuffer{}, nil)))
	var runs atomic.Int32
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx, Task{Name: "count", Every: 10 * time.Millisecond, Run: func(context.Context) (int, error) {
		runs.Add(1)
		return 1, nil
	}})
	time.Sleep(100 * time.Millisecond)
	cancel()
	runner.Wait()

	n := runs.Load()
	if n < 5 {
		t.Fatalf("ran %d times in 100ms, want at least 5", n)
	}
	if got := testutil.ToFloat64(runner.items.WithLabelValues("count")); got != float64(n) {
		t.Fatalf("items metric = %v, want %d", got, n)
	}
}

func TestAPanicIsLoggedAndTheTaskRunsAgain(t *testing.T) {
	logs := &syncBuffer{}
	runner := New(slog.New(slog.NewTextHandler(logs, nil)))
	var runs atomic.Int32
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx,
		Task{Name: "broken", Every: 10 * time.Millisecond, Run: func(context.Context) (int, error) {
			runs.Add(1)
			panic("nil map")
		}},
		Task{Name: "failing", Every: 10 * time.Millisecond, Run: func(context.Context) (int, error) {
			return 0, errors.New("database unreachable")
		}},
	)
	time.Sleep(100 * time.Millisecond)
	cancel()
	runner.Wait()

	if runs.Load() < 2 {
		t.Fatalf("the panicking task ran %d times; it must keep being scheduled", runs.Load())
	}
	for _, want := range []string{"background task panicked", "nil map", "database unreachable"} {
		if !strings.Contains(logs.String(), want) {
			t.Errorf("logs missing %q:\n%s", want, logs.String())
		}
	}
}
~~~

`testutil.ToFloat64` reads a metric's current value, so the test can check the counter as well as the behaviour.

### One instance at a time

Create `internal/pgstore/exclusive.go`:

<!-- file: internal/pgstore/exclusive.go -->
~~~go
package pgstore

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Exclusive wraps a background task so that, across every instance sharing
// the database, at most one runs it at a time. The others skip their turn.
//
// It uses a PostgreSQL advisory lock: a lock on a number that means
// whatever the application decides, here the hash of the task's name.
// pg_try_advisory_xact_lock doesn't wait: it returns false at once if
// another session holds the lock. The lock belongs to the transaction, so
// it is released when the transaction ends, even if this process dies.
//
// The lock prevents overlap, not repetition: two instances can still run
// the task one after the other. Tasks must be safe to repeat.
func Exclusive(pool *pgxpool.Pool, name string, task func(context.Context) (int, error)) func(context.Context) (int, error) {
	return func(ctx context.Context) (int, error) {
		tx, err := pool.Begin(ctx)
		if err != nil {
			return 0, err
		}
		defer tx.Rollback(context.WithoutCancel(ctx))

		var locked bool
		if err := tx.QueryRow(ctx, `SELECT pg_try_advisory_xact_lock(hashtext($1))`, name).Scan(&locked); err != nil {
			return 0, err
		}
		if !locked {
			return 0, nil // another instance is running this task
		}
		return task(ctx)
	}
}
~~~

`hashtext` is a PostgreSQL function that turns the task's name into a number: advisory locks are locks on numbers. Create `internal/pgstore/exclusive_test.go`:

<!-- file: internal/pgstore/exclusive_test.go -->
~~~go
package pgstore

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"

	"runway/internal/pgstore/pgtest"
)

func TestExclusiveRunsATaskOnceAtATime(t *testing.T) {
	pool := pgtest.Pool(t, Migrate)
	var running, ran atomic.Int32
	// The first run holds the lock until every other caller has tried and
	// skipped. (Sleeping instead would assume they all try within the
	// sleep, which a loaded machine doesn't promise.)
	release := make(chan struct{})
	task := Exclusive(pool, "test-task", func(context.Context) (int, error) {
		if running.Add(1) > 1 {
			t.Error("two runs overlapped")
		}
		<-release
		running.Add(-1)
		ran.Add(1)
		return 1, nil
	})

	var wg sync.WaitGroup
	var skipped atomic.Int32
	for range 5 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			n, err := task(context.Background())
			if err != nil {
				t.Error(err)
			}
			if n == 0 {
				if skipped.Add(1) == 4 {
					close(release) // the other four have skipped
				}
			}
		}()
	}
	wg.Wait()
	if ran.Load() != 1 {
		t.Fatalf("the task ran %d times, want 1: the others should have skipped", ran.Load())
	}

	// Once the first run has finished, the lock is free again.
	if n, err := task(context.Background()); n != 1 || err != nil {
		t.Fatalf("second round = %d, %v; want 1, nil", n, err)
	}
}
~~~

### Finding abandoned jobs, quickly

Create the index first, `internal/pgstore/migrations/0006_running_index.sql`:

<!-- file: internal/pgstore/migrations/0006_running_index.sql -->
~~~sql
-- +goose NO TRANSACTION
-- CREATE INDEX CONCURRENTLY builds the index without blocking writes to
-- jobs, but it can't run inside a transaction, hence the line above.

-- +goose Up
-- The abandoned-job check looks for running jobs by updated_at. Only a
-- tiny fraction of jobs are running at any time, so a partial index holds
-- just those rows.
CREATE INDEX CONCURRENTLY IF NOT EXISTS jobs_running_updated_at
    ON jobs (updated_at) WHERE state = 'running';

-- +goose Down
DROP INDEX CONCURRENTLY IF EXISTS jobs_running_updated_at;
~~~

The query it serves goes in `internal/pgstore/pgstore.go`. Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
// History returns a job's events, oldest first.
~~~

to:

~~~go
// Abandoned returns up to limit running jobs that haven't changed since
// before, oldest first. The partial index jobs_running_updated_at answers
// this without reading the finished jobs.
func (s *Store) Abandoned(ctx context.Context, before time.Time, limit int) ([]jobs.ID, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT id FROM jobs
		WHERE state = 'running' AND updated_at < $1
		ORDER BY updated_at
		LIMIT $2`, before, limit)
	if err != nil {
		return nil, fmt.Errorf("find abandoned jobs: %w", err)
	}
	return pgx.CollectRows(rows, pgx.RowTo[jobs.ID])
}

// History returns a job's events, oldest first.
~~~

`pgx.RowTo[jobs.ID]` scans each one-column row straight into a `jobs.ID`. Test it, with one job of each kind. Add at the end of `internal/pgstore/pgstore_test.go`:

<!-- append: internal/pgstore/pgstore_test.go -->
~~~go
func TestAbandonedFindsOnlyOldRunningJobs(t *testing.T) {
	ctx := context.Background()
	store := New(pgtest.Pool(t, Migrate))
	add := func(state jobs.State, at time.Time) jobs.ID {
		job, _ := jobs.New("resize", time.Second, at)
		job, err := store.Create(ctx, job)
		if err != nil {
			t.Fatal(err)
		}
		if state != jobs.StateQueued {
			queued := job.State
			_ = job.Start(at)
			if err := store.Update(ctx, job, queued); err != nil {
				t.Fatal(err)
			}
		}
		return job.ID
	}
	old := add(jobs.StateRunning, t0)
	add(jobs.StateRunning, t0.Add(time.Hour)) // running, but recently changed
	add(jobs.StateQueued, t0)                 // old, but not running

	ids, err := store.Abandoned(ctx, t0.Add(time.Minute), 10)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(ids, []jobs.ID{old}) {
		t.Fatalf("abandoned = %v, want [%d]", ids, old)
	}
}
~~~

### The reaper, in the domain

Deciding that a job is abandoned is a domain rule, so it lives in the service. The service only needs one thing from storage, and says exactly what in a small interface of its own. In `internal/jobs/service.go`, change:

<!-- edit: internal/jobs/service.go -->
~~~go
// transition applies change with compare-and-swap.
~~~

to:

~~~go
// AbandonedFinder finds running jobs that haven't changed since before.
type AbandonedFinder interface {
	Abandoned(ctx context.Context, before time.Time, limit int) ([]ID, error)
}

// FailAbandoned fails running jobs that no worker has reported on for
// longer than after: their worker most likely died, and its command was
// given up on. It handles up to 100 jobs and returns how many it failed.
// If a job finishes meanwhile, compare-and-swap lets the finish win.
func (s *Service) FailAbandoned(ctx context.Context, finder AbandonedFinder, after time.Duration) (int, error) {
	ids, err := finder.Abandoned(ctx, s.now().Add(-after), 100)
	if err != nil {
		return 0, err
	}
	for n, id := range ids {
		if err := s.MarkFailed(ctx, id, "abandoned: no worker reported back"); err != nil {
			return n, err
		}
	}
	return len(ids), nil
}

// transition applies change with compare-and-swap.
~~~

`AbandonedFinder` isn't added to `Repository`: `memstore` has no use for it, and a port should hold only what its users need (the **interface segregation** principle). Add a test that uses a fake finder, so it runs without a database. At the end of `internal/jobs/service_test.go`:

<!-- append: internal/jobs/service_test.go -->
~~~go
type finder []jobs.ID

func (f finder) Abandoned(context.Context, time.Time, int) ([]jobs.ID, error) { return f, nil }

func TestFailAbandonedFailsOnlyUnfinishedJobs(t *testing.T) {
	ctx := context.Background()
	repo := memstore.New()
	svc := jobs.NewService(repo)
	stuck, _ := svc.Create(ctx, "stuck", time.Second)
	done, _ := svc.Create(ctx, "done", time.Second)
	_ = svc.MarkStarted(ctx, stuck.ID)
	_ = svc.MarkCompleted(ctx, done.ID)

	n, err := svc.FailAbandoned(ctx, finder{stuck.ID, done.ID}, time.Minute)
	if err != nil || n != 2 {
		t.Fatalf("FailAbandoned = %d, %v", n, err)
	}
	if got, _ := svc.Get(ctx, stuck.ID); got.State != jobs.StateFailed || got.FailureReason != "abandoned: no worker reported back" {
		t.Fatalf("stuck job = %s %q", got.State, got.FailureReason)
	}
	if got, _ := svc.Get(ctx, done.ID); got.State != jobs.StateCompleted {
		t.Fatalf("a finished job was changed to %s", got.State)
	}
}
~~~

The fake returns a finished job as well as a stuck one: the reaper must leave the finished one alone, and it does, because `MarkFailed` ignores finished jobs.

### Cleaning up the outbox

In `internal/outbox/outbox.go`, change:

<!-- edit: internal/outbox/outbox.go -->
~~~go
// Pending counts messages not yet sent.
~~~

to:

~~~go
// DeletePublished deletes up to 1000 messages that were sent before
// before, and reports how many it deleted. Small batches keep each DELETE
// short, so it never holds locks for long; the next run takes the rest.
func DeletePublished(ctx context.Context, pool *pgxpool.Pool, before time.Time) (int, error) {
	tag, err := pool.Exec(ctx, `
		DELETE FROM outbox WHERE id IN (
			SELECT id FROM outbox WHERE published_at < $1 LIMIT 1000
		)`, before)
	return int(tag.RowsAffected()), err
}

// Pending counts messages not yet sent.
~~~

`DELETE` has no `LIMIT` of its own in PostgreSQL, so the subquery picks the batch.

### Run the tasks from the API

In `cmd/api/main.go`, add the import. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/breaker"
	"runway/internal/bus"
~~~

to:

~~~go
	"runway/internal/background"
	"runway/internal/breaker"
	"runway/internal/bus"
~~~

Add the setting. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	CacheTimeout     time.Duration
	DBMaxConns       int
~~~

to:

~~~go
	CacheTimeout     time.Duration
	AbandonAfter     time.Duration
	DBMaxConns       int
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
~~~

to:

~~~go
	if cfg.AbandonAfter, err = envconfig.Duration(getenv, "ABANDON_AFTER", 2*time.Minute); err != nil {
		return config{}, err
	}
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
~~~

The reaper needs the store itself (the cache doesn't implement `Abandoned`), so keep a variable for it. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	var service *jobs.Service
	if pool == nil {
~~~

to:

~~~go
	var service *jobs.Service
	var store *pgstore.Store
	if pool == nil {
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
		repo, closeCache, err := withCache(ctx, cfg, pgstore.New(pool, pgstore.WithOutbox(eventing.OutboxMessages(producer != nil))), metrics)
~~~

to:

~~~go
		store = pgstore.New(pool, pgstore.WithOutbox(eventing.OutboxMessages(producer != nil)))
		repo, closeCache, err := withCache(ctx, cfg, store, metrics)
~~~

Replace Phase 2's hand-written sweep loop with the runner. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	// A background job: forget expired idempotency keys once a minute.
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-stopConsuming.Done():
				return
			case <-ticker.C:
				removed, err := sweepKeys(stopConsuming)
				if err != nil {
					logger.Warn("sweeping idempotency keys failed", "error", err)
				} else if removed > 0 {
					logger.Info("swept idempotency keys", "removed", removed)
				}
			}
		}
	}()
~~~

to:

~~~go
	runner := background.New(logger)
	metrics.MustRegister(runner.Collectors()...)
	runner.Start(stopConsuming, backgroundTasks(cfg, pool, store, service, sweepKeys)...)
~~~

At shutdown, wait for running tasks along with the consumers. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	go func() {
		consumers.Wait()
		close(done)
	}()
~~~

to:

~~~go
	go func() {
		consumers.Wait()
		runner.Wait()
		close(done)
	}()
~~~

And list the tasks, after `run`. Change:

<!-- edit: cmd/api/main.go -->
~~~go
func busName(cfg config) string {
~~~

to:

~~~go
// backgroundTasks lists the maintenance this instance runs. With a shared
// database, every instance runs the same tasks, so each is made Exclusive:
// one instance does each round of the work, and the others skip it.
func backgroundTasks(cfg config, pool *pgxpool.Pool, store *pgstore.Store, service *jobs.Service, sweepKeys func(context.Context) (int, error)) []background.Task {
	sweep := background.Task{Name: "sweep-idempotency-keys", Every: time.Minute, Run: sweepKeys}
	if pool == nil {
		return []background.Task{sweep}
	}
	tasks := []background.Task{
		sweep,
		{Name: "delete-sent-outbox", Every: time.Minute, Run: func(ctx context.Context) (int, error) {
			return outbox.DeletePublished(ctx, pool, time.Now().Add(-time.Hour))
		}},
		{Name: "fail-abandoned-jobs", Every: 30 * time.Second, Run: func(ctx context.Context) (int, error) {
			return service.FailAbandoned(ctx, store, cfg.AbandonAfter)
		}},
	}
	for i := range tasks {
		tasks[i].Run = pgstore.Exclusive(pool, tasks[i].Name, tasks[i].Run)
	}
	return tasks
}

func busName(cfg config) string {
~~~

Sent outbox rows are kept for an hour before deletion. That leaves time to look at what was sent, in `psql`, when something goes wrong.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

### Run it: an orphaned job

Use RabbitMQ and a real worker, with a short `ABANDON_AFTER` so you don't wait two minutes. Create a 5-second job and kill the worker a second in:

~~~bash
export AMQP_URL=amqp://guest:guest@localhost:5672/ DATABASE_URL=postgres://runway:runway@localhost:5432/runway
ABANDON_AFTER=5s go run ./cmd/api &
go run ./cmd/worker &
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"orphan","duration_ms":5000}'
sleep 1; pkill -9 -f 'cmd/worker|/worker$'
~~~

Poll the job (use your ID) for up to a minute:

~~~text
{"id":218,"state":"running","description":"orphan",...}
...24 seconds later...
{"id":218,"state":"failed","description":"orphan","duration_ms":5000,"failure_reason":"abandoned: no worker reported back",...}
~~~

The API logged `{"msg":"background task done","task":"fail-abandoned-jobs","items":1}`, and the job's history shows exactly what happened:

~~~text
  state  |               reason               
---------+------------------------------------
 queued  | 
 running | 
 failed  | abandoned: no worker reported back
(3 rows)
~~~

(How long it took depends on where the reaper's 30-second cycle was: between 5 and about 35 seconds.)

But the command is still in RabbitMQ: the dead worker never acknowledged it. Start a worker again and it runs the job and reports `completed`, which the API **ignores**, because the job had already finished as `failed`. The work was done and the record says it wasn't. That's the price of a reaper whose timeout is too short. With the default two minutes, the new worker would have finished long before. Make the timeout generous, and make it match how your workers actually retry.

### Run it: why the index matters

Put a million finished jobs in the table, and a thousand old `running` ones, then ask PostgreSQL how it runs the reaper's query, first without the index:

~~~bash
docker compose exec -T postgres psql -U runway <<'SQL'
INSERT INTO jobs (description, duration_ms, state, created_at, updated_at)
SELECT 'bulk', 100,
       CASE WHEN g % 1000 = 0 THEN 'running' ELSE 'completed' END,
       now() - g * interval '1 second', now() - g * interval '1 second'
FROM generate_series(1, 1000000) AS g;
ANALYZE jobs;
DROP INDEX jobs_running_updated_at;
EXPLAIN ANALYZE SELECT id FROM jobs WHERE state = 'running' AND updated_at < now() - interval '2 minutes' ORDER BY updated_at LIMIT 100;
SQL
~~~

`generate_series(1, 1000000)` produces a million rows to insert. `ANALYZE` refreshes the **statistics** the planner uses to guess how many rows each step returns. And `<<'SQL'` ... `SQL` is a shell **here-document**: everything between the markers goes to `psql` as its input.

~~~text
 Limit  (cost=19658.33..19669.99 rows=100 width=16) (actual time=42.874..49.105 rows=100 loops=1)
   ->  Gather Merge  (cost=19658.33..19726.46 rows=584 width=16) (actual time=42.871..49.093 rows=100 loops=1)
         Workers Planned: 2
         Workers Launched: 2
         ->  Sort  (cost=18658.30..18659.03 rows=292 width=16) (actual time=39.701..39.705 rows=77 loops=3)
               Sort Key: updated_at
               Sort Method: top-N heapsort  Memory: 32kB
               ->  Parallel Seq Scan on jobs  (cost=0.00..18647.14 rows=292 width=16) (actual time=0.076..39.461 rows=333 loops=3)
                     Filter: ((state = 'running'::text) AND (updated_at < (now() - '00:02:00'::interval)))
                     Rows Removed by Filter: 333072
 Execution Time: 49.145 ms
~~~

(A few lines are left out here and below: each worker's own sort details, and the planning time.)

Read a plan from the most indented line outwards:
1. **Parallel Seq Scan**: three processes (two workers plus the leader, `loops=3`) each read a third of the table. Each threw away 333,072 rows to keep 333 (`Rows Removed by Filter`).
2. **Sort** each kept the 100 oldest.
3. **Gather Merge** combined the three sorted lists, and **Limit** stopped at 100.

That's about a million rows read to return 100, in 49 ms, every 30 seconds, and growing with the table. Now restore the index (by hand here; the migration did it before) and ask again:

~~~bash
docker compose exec -T postgres psql -U runway <<'SQL'
CREATE INDEX jobs_running_updated_at ON jobs (updated_at) WHERE state = 'running';
EXPLAIN ANALYZE SELECT id FROM jobs WHERE state = 'running' AND updated_at < now() - interval '2 minutes' ORDER BY updated_at LIMIT 100;
SELECT pg_size_pretty(pg_relation_size('jobs')) AS table_size, pg_size_pretty(pg_relation_size('jobs_running_updated_at')) AS partial_index;
SQL
~~~

~~~text
 Limit  (cost=0.28..5.89 rows=100 width=16) (actual time=0.029..0.160 rows=100 loops=1)
   ->  Index Scan using jobs_running_updated_at on jobs  (cost=0.28..39.53 rows=700 width=16) (actual time=0.028..0.152 rows=100 loops=1)
         Index Cond: (updated_at < (now() - '00:02:00'::interval))
 Execution Time: 0.179 ms

 table_size | partial_index 
------------+---------------
 81 MB      | 40 kB
~~~

From 49 ms to 0.18 ms: **270 times faster**. The index is already sorted by `updated_at`, so there's no sort step, and it stops after 100 entries. And it's 40 kB, because it holds only the thousand `running` rows; an index on every row's `updated_at` would be about as big as the primary key's index, 21 MB. Clean up, and give the table its statistics back:

~~~bash
docker compose exec postgres psql -U runway -c "DELETE FROM jobs WHERE description = 'bulk'" -c 'VACUUM ANALYZE jobs'
~~~

The million IDs you just used up are gone for good, so your next job IDs will be above a million. That's fine: IDs are increasing, not consecutive. (`VACUUM` reclaims the space the deleted rows took. In PostgreSQL a `DELETE` only marks a row as dead; the space is reused after a vacuum, which normally runs automatically.)

**Break it: no recover.** In `runOnce`, delete the `defer func() { ... recover() ... }()` block (and the now-unused `"fmt"` import), and run the runner's tests:

~~~text
panic: nil map

goroutine 8 [running]:
runway/internal/background.TestAPanicIsLoggedAndTheTaskRunsAgain.func1(...)
	.../internal/background/background_test.go:63 +0x2f
runway/internal/background.(*Runner).runOnce(...)
~~~

The whole test binary died, not just the test. In the API, that would be the whole server, every request in flight included, because of one maintenance task. Restore the `recover`. (Note what it doesn't do: it doesn't fix the bug. The task panics again next run, and the `panic` result in `background_task_runs_total` is how you find out.)

**Explain it:** why must background tasks be idempotent and resumable? What does `pg_try_advisory_xact_lock` guarantee, what doesn't it, and what happens to the lock if the instance holding it crashes? Read the two plans aloud: where did the 49 ms go, and why is the partial index so small? Why must `ABANDON_AFTER` be longer than a worker's whole retry cycle?

**Read.** Markus Winand, *Use The Index, Luke!*, chapters 1 and 2 (*Anatomy of an Index*, *The Where Clause*), and the PostgreSQL manual, §14.1 *Using EXPLAIN* and §11.8 *Partial Indexes*. Carry this question in: Runway also looks jobs up by `id`. Why didn't you have to create an index for that?

---

## Step 9: A circuit breaker around the database

**The problem.** A database rarely just *stops*. More often it **hangs**: a long lock, a full disk, a network path that drops packets. Connections stay open, and queries simply never answer. Simulate that: `docker compose pause` freezes the container's processes, while the kernel keeps its network ports accepting connections.

~~~bash
export DATABASE_URL=postgres://runway:runway@localhost:5432/runway
go run ./cmd/api &
docker compose pause postgres
for i in 1 2 3; do curl -s -w " %{http_code} %{time_total}s\n" http://127.0.0.1:8080/jobs/2; done
docker compose unpause postgres
~~~

~~~text
{"error":"internal error"}
 500 2.003757s
{"error":"internal error"}
 500 2.003168s
{"error":"internal error"}
 500 2.001899s
~~~

Three things are wrong:
1. Every request holds a connection, a goroutine and the client's patience for the full 2-second request timeout.
2. Then it answers **500**, which tells the client "the server is broken; don't bother retrying". The truth is "temporarily unavailable; try again shortly".
3. The load balancer in front still thinks this instance is healthy and keeps sending it traffic.

**New ideas.**

- **A breaker around the database.** Phase 2 put a circuit breaker around dispatch. The same idea applies here: after a few failures in a row, stop sending queries for a cooldown period and fail at once, then let one trial query through to test the water.
- **What counts as a failure.** "Job not found" and "lost the compare-and-swap" are *correct answers from a healthy database*. A caller who gave up (`context.Canceled`) says nothing about the database either. Only errors that mean "the database isn't working" should open the breaker. Count the wrong ones, and a burst of `404`s would take your service offline.
- **The domain names the condition.** `breaker.ErrOpen` is a detail of one package. The domain gets its own error, `jobs.ErrUnavailable`, and the HTTP and gRPC layers map *that* to `503` and `Unavailable`. They never need to know a breaker exists.
- **Graceful degradation.** Put the breaker **under** the cache: then, while the database is failing, cached jobs can still be read. Part of the service keeps working.
- **Liveness vs readiness.**
  - A **liveness** probe asks "is this process alive?" If it fails, the platform restarts the process.
  - A **readiness** probe asks "should this instance receive traffic right now?" If it fails, the load balancer stops sending it requests, but leaves it running.

  A database outage must fail **readiness**, never liveness: restarting every API instance because the database is down fixes nothing, and turns one outage into two. `GET /health` stays a liveness check; a new `GET /ready` checks the database. Phase 5's Kubernetes will call both.

### The domain's error

In `internal/jobs/repository.go`, change:

<!-- edit: internal/jobs/repository.go -->
~~~go
var (
	ErrNotFound = errors.New("job not found")
	ErrConflict = errors.New("job was changed by another request")
)
~~~

to:

~~~go
var (
	ErrNotFound = errors.New("job not found")
	ErrConflict = errors.New("job was changed by another request")
	// ErrUnavailable means storage can't be reached right now. The request
	// may succeed if retried later.
	ErrUnavailable = errors.New("job storage is unavailable")
)
~~~

### A breaker that wraps a repository

Another decorator. In `internal/breaker/breaker.go`, add the import. Change:

<!-- edit: internal/breaker/breaker.go -->
~~~go
import (
	"context"
	"errors"
~~~

to:

~~~go
import (
	"context"
	"errors"
	"fmt"
~~~

and add the type before the dispatcher. Change:

<!-- edit: internal/breaker/breaker.go -->
~~~go
// Dispatcher wraps a jobs.Dispatcher with a breaker.
~~~

to:

~~~go
// Repository wraps a jobs.Repository with a breaker. When storage keeps
// failing, calls return jobs.ErrUnavailable at once instead of each one
// waiting for its deadline.
type Repository struct {
	Next    jobs.Repository
	Breaker *Breaker
}

// call runs fn through the breaker. Only failures of the storage count
// against it: a missing job, a lost compare-and-swap or a caller that gave
// up are normal answers from a healthy database.
func (r Repository) call(fn func() error) error {
	var result error
	err := r.Breaker.Do(func() error {
		result = fn()
		if result == nil || errors.Is(result, jobs.ErrNotFound) || errors.Is(result, jobs.ErrConflict) ||
			errors.Is(result, context.Canceled) {
			return nil
		}
		return result
	})
	if errors.Is(err, ErrOpen) {
		return fmt.Errorf("%w: %w", jobs.ErrUnavailable, err)
	}
	return result
}

func (r Repository) Create(ctx context.Context, job jobs.Job) (jobs.Job, error) {
	var created jobs.Job
	err := r.call(func() error {
		var err error
		created, err = r.Next.Create(ctx, job)
		return err
	})
	return created, err
}

func (r Repository) Get(ctx context.Context, id jobs.ID) (jobs.Job, error) {
	var job jobs.Job
	err := r.call(func() error {
		var err error
		job, err = r.Next.Get(ctx, id)
		return err
	})
	return job, err
}

func (r Repository) Update(ctx context.Context, job jobs.Job, expected jobs.State) error {
	return r.call(func() error { return r.Next.Update(ctx, job, expected) })
}

// Dispatcher wraps a jobs.Dispatcher with a breaker.
~~~

The trick in `call` is two errors. `result` is the real answer, which the caller gets. What the function hands the breaker is `nil` for healthy answers, so the breaker only counts real failures. `fmt.Errorf("%w: %w", ...)` wraps **both** errors, so `errors.Is` finds `jobs.ErrUnavailable` and `breaker.ErrOpen`.

Create `internal/breaker/repository_test.go`:

<!-- file: internal/breaker/repository_test.go -->
~~~go
package breaker

import (
	"context"
	"errors"
	"testing"
	"time"

	"runway/internal/jobs"
	"runway/internal/memstore"
)

// broken is a repository whose every call fails, and counts the calls.
type broken struct {
	jobs.Repository
	calls int
}

func (b *broken) Get(context.Context, jobs.ID) (jobs.Job, error) {
	b.calls++
	return jobs.Job{}, errors.New("connection refused")
}

func TestRepositoryFailsFastWhenStorageKeepsFailing(t *testing.T) {
	next := &broken{}
	repo := Repository{Next: next, Breaker: New(3, time.Minute, time.Now)}

	for range 10 {
		_, _ = repo.Get(context.Background(), 1)
	}
	if next.calls != 3 {
		t.Fatalf("storage was called %d times, want 3: the breaker should open after 3 failures", next.calls)
	}
	if _, err := repo.Get(context.Background(), 1); !errors.Is(err, jobs.ErrUnavailable) {
		t.Fatalf("error = %v, want ErrUnavailable", err)
	}
}

// A missing job is a normal answer from a healthy database.
func TestRepositoryIgnoresNormalAnswers(t *testing.T) {
	b := New(3, time.Minute, time.Now)
	repo := Repository{Next: memstore.New(), Breaker: b}

	for range 10 {
		if _, err := repo.Get(context.Background(), 99); !errors.Is(err, jobs.ErrNotFound) {
			t.Fatalf("error = %v, want ErrNotFound", err)
		}
	}
	if b.State() != Closed {
		t.Fatalf("breaker is %s after only not-found answers, want closed", b.State())
	}
}
~~~

### 503, and a readiness probe

In `internal/httpapi/handler.go`, map the new error. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	case errors.Is(err, jobs.ErrInvalidTransition), errors.Is(err, jobs.ErrConflict):
		writeError(w, http.StatusConflict, err.Error())
	default:
~~~

to:

~~~go
	case errors.Is(err, jobs.ErrInvalidTransition), errors.Is(err, jobs.ErrConflict):
		writeError(w, http.StatusConflict, err.Error())
	case errors.Is(err, jobs.ErrUnavailable), errors.Is(err, context.DeadlineExceeded):
		// Not the client's fault, and likely to pass: say so, and when
		// to try again.
		h.logger.Warn("storage unavailable", "method", r.Method, "path", r.URL.Path, "error", err)
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusServiceUnavailable, "temporarily unavailable; retry later")
	default:
~~~

A request that ran out of time (`DeadlineExceeded`) is also a `503` now: the service was too slow, which isn't the client's fault.

Add the readiness option. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	requestTimeout time.Duration
	idempotency    idempotency.Keys
}
~~~

to:

~~~go
	requestTimeout time.Duration
	idempotency    idempotency.Keys
	ready          func(context.Context) error
}

// WithReadiness adds GET /ready, which answers 200 when check passes and
// 503 when it fails. A load balancer sends traffic only to ready
// instances. GET /health stays a pure liveness check: the process is up.
func WithReadiness(check func(context.Context) error) Option {
	return func(c *config) { c.ready = check }
}
~~~

Register the route. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	mux.HandleFunc("GET /health", h.health)
~~~

to:

~~~go
	mux.HandleFunc("GET /health", h.health)
	if cfg.ready != nil {
		mux.HandleFunc("GET /ready", h.readiness(cfg.ready))
	}
~~~

And add the handler. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
type createJobRequest struct {
~~~

to:

~~~go
// readiness runs check with a short deadline of its own, so a hung
// dependency makes the probe fail quickly instead of hanging it.
func (h *handlers) readiness(check func(context.Context) error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), time.Second)
		defer cancel()
		if err := check(ctx); err != nil {
			h.logger.Warn("not ready", "error", err)
			writeJSON(w, http.StatusServiceUnavailable, healthResponse{Status: "unavailable"})
			return
		}
		writeJSON(w, http.StatusOK, healthResponse{Status: "ok"})
	}
}

type createJobRequest struct {
~~~

Test both. Add at the end of `internal/httpapi/handler_test.go`:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
type unavailableService struct{ JobService }

func (unavailableService) Get(context.Context, jobs.ID) (jobs.Job, error) {
	return jobs.Job{}, jobs.ErrUnavailable
}

func TestUnavailableStorageIs503(t *testing.T) {
	response := do(t, NewHandler(unavailableService{}), http.MethodGet, "/jobs/1", "")
	if response.Code != http.StatusServiceUnavailable || response.Header().Get("Retry-After") != "1" {
		t.Fatalf("got %d with Retry-After %q, want 503 and 1", response.Code, response.Header().Get("Retry-After"))
	}
}

func TestReadiness(t *testing.T) {
	var failure error
	h := newTestHandler(WithReadiness(func(context.Context) error { return failure }))
	if got := do(t, h, http.MethodGet, "/ready", ""); got.Code != http.StatusOK {
		t.Fatalf("ready = %d, want 200", got.Code)
	}
	failure = errors.New("database unreachable")
	if got := do(t, h, http.MethodGet, "/ready", ""); got.Code != http.StatusServiceUnavailable {
		t.Fatalf("ready = %d, want 503", got.Code)
	}
	if got := do(t, h, http.MethodGet, "/health", ""); got.Code != http.StatusOK {
		t.Fatalf("health = %d; liveness must not depend on the database", got.Code)
	}
}
~~~

gRPC gets the same mapping. In `internal/grpcapi/server.go`, change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
	case errors.Is(err, jobs.ErrDispatchFailed):
~~~

to:

~~~go
	case errors.Is(err, jobs.ErrUnavailable):
		return status.Error(codes.Unavailable, "temporarily unavailable; retry later")
	case errors.Is(err, jobs.ErrDispatchFailed):
~~~

### Wire it in

In `cmd/api/main.go`, put the breaker between the store and the cache. Change:

<!-- edit: cmd/api/main.go -->
~~~go
		repo, closeCache, err := withCache(ctx, cfg, store, metrics)
~~~

to:

~~~go
		// The breaker sits under the cache, so cached jobs can still be
		// read while the database is failing.
		dbBreaker := breaker.New(cfg.BreakerThreshold, cfg.BreakerCooldown, time.Now)
		metrics.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Name: "db_breaker_state",
			Help: "The database circuit breaker: 0 closed, 1 open, 2 half-open.",
		}, func() float64 { return float64(dbBreaker.State()) }))
		guarded := breaker.Repository{Next: store, Breaker: dbBreaker}
		repo, closeCache, err := withCache(ctx, cfg, guarded, metrics)
~~~

The layers, from the outside in, are now: **service → cache → breaker → PostgreSQL**. Each is a `jobs.Repository`, and each was added without changing the others.

Add the readiness check when there's a database. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
		httpapi.WithIdempotency(keys),
	)
~~~

to:

~~~go
	options := []httpapi.Option{
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
		httpapi.WithIdempotency(keys),
	}
	if pool != nil {
		options = append(options, httpapi.WithReadiness(func(ctx context.Context) error { return pool.Ping(ctx) }))
	}
	handler := httpapi.NewHandler(service, options...)
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

### Run it: freeze the database again

With the cache this time. Read job 1 once, so it's cached, then freeze PostgreSQL:

~~~bash
export DATABASE_URL=postgres://runway:runway@localhost:5432/runway REDIS_URL=redis://localhost:6379/0
go run ./cmd/api &
curl -s -o /dev/null http://127.0.0.1:8080/jobs/1
docker compose pause postgres
for i in 1 2 3 4 5 6 7 8; do curl -s -w " %{http_code} %{time_total}s\n" http://127.0.0.1:8080/jobs/2; done
curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://127.0.0.1:8080/jobs/1
curl -s -w " %{http_code}\n" http://127.0.0.1:8080/ready
curl -s -w " %{http_code}\n" http://127.0.0.1:8080/health
~~~

~~~text
{"error":"temporarily unavailable; retry later"}
 503 2.003276s
{"error":"temporarily unavailable; retry later"}
 503 2.001853s
{"error":"temporarily unavailable; retry later"}
 503 2.003037s
{"error":"temporarily unavailable; retry later"}
 503 2.003006s
{"error":"temporarily unavailable; retry later"}
 503 2.003609s
{"error":"temporarily unavailable; retry later"}
 503 0.004216s
{"error":"temporarily unavailable; retry later"}
 503 0.002112s
{"error":"temporarily unavailable; retry later"}
 503 0.002466s
200 0.003766s
{"status":"unavailable"}
 503
{"status":"ok"}
 200
~~~

Step by step:
1. The first five requests still waited out their deadline, but now answered `503` with `Retry-After`. Each timeout was a failure.
2. The fifth opened the breaker (`db_breaker_state 1`), and from then on requests failed in **2 milliseconds**: no connection held, nothing piling up.
3. The cached job 1 was still served (`200`), because the cache sits above the breaker.
4. `/ready` said `503`, so a load balancer would stop routing here. `/health` still said `200`, so nothing would restart the process.

The log says why, for whoever is on call (trimmed to the useful fields):

~~~text
{"level":"WARN","msg":"storage unavailable","method":"GET","path":"/jobs/2","error":"get job 2: timeout: context deadline exceeded"}
~~~

Now `docker compose unpause postgres` and wait out the cooldown (10 s). The next request is the trial, it succeeds, and everything is back: `200` in a few milliseconds, `/ready` is `200`, `db_breaker_state 0`.

**Break it: count every error.** In `Repository.call`, replace the `if result == nil || ... { return nil }` block with a plain `return result`, so every error counts as a failure:

~~~text
--- FAIL: TestRepositoryIgnoresNormalAnswers (0.00s)
    repository_test.go:46: error = job storage is unavailable: circuit breaker is open, want ErrNotFound
~~~

Three requests for jobs that don't exist, and the service declared its own database unavailable. A client could do that to you on purpose, just by asking for missing IDs. Restore the check.

**Explain it:** which errors should open a database breaker, and which must not? Why does the breaker sit under the cache rather than above it? What's the difference between liveness and readiness, and what goes wrong if a database outage fails liveness?

**Read.** *Release It!* (Nygard), Ch. 5, *Stability Patterns*: Circuit Breaker, Bulkheads, Fail Fast. Then the Kubernetes documentation page *Configure Liveness, Readiness and Startup Probes*. Carry this question in: what should `/ready` check, and what should it deliberately leave out?

---

## Step 10: The audit log, in Rust

**The problem.** The `job_events` table is a history, but it isn't an **audit trail**. Anyone with write access to the database can `UPDATE` or `DELETE` an event, and nothing would show it. An audit trail must be:
- **append-only**: records are added, never changed;
- **tamper-evident**: a change to any record can be detected;
- **separate** from the system it audits, so one mistake or one compromised account can't rewrite both.

You already built most of that. The Rust Bridge's `klog` is an append-only file of checksummed records that detects corruption and survives torn writes. What's missing is the connection: every job event, from Kafka, into `klog`, with nothing lost even when either side crashes.

**New ideas.**

- **Processes talking through pipes.** The simplest way for a Go program to use a Rust program: start it as a **child process** and talk over its standard input and output. Go writes one line per event; `klog ingest` appends it, waits for `fsync`, and answers `ok OFFSET`. No network protocol, no shared library, and each side is tested on its own.
- **Acknowledgement before progress.** The feed commits its Kafka offsets only after `klog` has confirmed **every** line of a batch. This is the same rule as acking after the work in Phase 2, and committing after projecting in step 6. If `klog` dies, the feed stops without committing, and the restart re-reads those events. Nothing is lost. A line *can* be written twice (if the feed dies between `klog`'s `ok` and the commit), so each line carries the event's message ID, and duplicates are visible to anyone who reads the log.
- **Checksums detect accidents, not attackers.** CRC-32C catches torn writes and flipped bits. Someone who edits the file deliberately can simply recompute the checksum. Making the log resistant to *deliberate* tampering needs each record to cover the one before it (a **hash chain**), or a signature. That's one of this phase's stretch goals, and Phase 6 returns to it.
- **The helper-process test.** To test code that runs a child process without depending on the real child (here, a Rust build), a Go test can run **its own test binary** as the child. An environment variable tells the binary to act as the fake instead of running tests. The `os/exec` package's own tests use this trick.

### Bring klog into the project

Copy your Rust Bridge crate into the practice folder, as `audit/`. Cargo's build output doesn't belong in Git, so ignore it:

~~~bash
cp -r ../../rust-bridge/practice audit
rm -rf audit/target
~~~

<!-- continue: ../rust-bridge/TEACHING.md into audit -->

Create `.gitignore` in the practice folder:

<!-- file: .gitignore -->
~~~text
audit/target/
~~~

### klog learns to ingest

In `audit/src/main.rs`, document the new command and import the I/O traits it needs. Change:

<!-- edit: audit/src/main.rs -->
~~~rust
//!   klog check FILE

use std::error::Error;
use std::process::ExitCode;
~~~

to:

~~~rust
//!   klog check FILE
//!   klog ingest FILE

use std::error::Error;
use std::io::{BufRead, Write};
use std::process::ExitCode;
~~~

`BufRead` gives standard input its `lines()` method, and `Write` gives standard output `flush()`. In Rust, a trait's methods can only be called where the trait is in scope.

Add the command to the `match`. Change:

<!-- edit: audit/src/main.rs -->
~~~rust
        _ => {
            return Err("usage: klog append FILE TEXT... | klog cat FILE | klog check FILE".into());
        }
~~~

to:

~~~rust
        [command, path] if command == "ingest" => ingest(path)?,
        _ => {
            return Err(
                "usage: klog append FILE TEXT... | klog cat FILE | klog check FILE | klog ingest FILE"
                    .into(),
            );
        }
~~~

(The longer usage string no longer fits on one line, and `cargo fmt` wraps it like this.) And add the function at the end of the file:

<!-- append: audit/src/main.rs -->
~~~rust
/// Appends each line of standard input as one record. Once a record is on
/// disk, it prints "ok OFFSET", so the sender knows that line is safe and
/// can move on. The sender waits for each answer before sending the next
/// line, so the answer must leave at once: flush makes sure of it.
fn ingest(path: &str) -> Result<(), Box<dyn Error>> {
    let (mut log, recovery) = Log::open(path)?;
    report(&recovery);
    let mut out = std::io::stdout().lock();
    for line in std::io::stdin().lock().lines() {
        let offset = log.append(line?.as_bytes())?;
        writeln!(out, "ok {offset}")?;
        out.flush()?;
    }
    Ok(())
}
~~~

- `stdin().lock().lines()` reads one line at a time and yields a `Result` for each, because reading can fail; `line?` passes a failure up.
- `log.append` is the same `append` as before: it returns only after `sync_data`, so `ok` means **on disk**.
- When Go closes the pipe, `lines()` ends, the loop ends, and `klog` exits cleanly.

Try it by hand:

<!-- run: cd audit && cargo fmt --check && cargo clippy -q --all-targets -- -D warnings && cargo test -q && cargo build -q && printf 'one\ntwo\n' | ./target/debug/klog ingest ingest-check.log | grep -c '^ok' | grep -qx 2 && rm ingest-check.log -->
~~~bash
cd audit
cargo build -q
printf 'job 1 queued\njob 1 running\n' | ./target/debug/klog ingest /tmp/ingest.log
./target/debug/klog cat /tmp/ingest.log
cd ..
~~~

~~~text
ok 0
ok 20
0: job 1 queued
1: job 1 running
~~~

The second record starts at byte 20: the first record's 12 bytes of text plus 8 bytes of framing (the length and the CRC, from the Rust Bridge).

### The Go side

Create `internal/audit/audit.go`:

<!-- file: internal/audit/audit.go -->
~~~go
// Package audit keeps a permanent record of every job event in klog, the
// checksummed append-only log built in the Rust Bridge.
//
// Go and Rust talk the simplest way two programs can: Go starts
// `klog ingest FILE` and writes one line per event to its standard input;
// klog appends the line, waits until it's on disk, and answers "ok OFFSET"
// on its standard output.
package audit

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"runway/internal/messages"
)

// Log is a running `klog ingest` process.
type Log struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	acks  *bufio.Scanner
}

// Start runs `bin ingest path`. klog's error messages go to this process's
// standard error.
func Start(bin, path string) (*Log, error) {
	cmd := exec.Command(bin, "ingest", path)
	cmd.Stderr = os.Stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start klog: %w", err)
	}
	return &Log{cmd: cmd, stdin: stdin, acks: bufio.NewScanner(stdout)}, nil
}

// Append sends one line and waits until klog confirms it is on disk.
func (l *Log) Append(line string) error {
	if strings.ContainsAny(line, "\r\n") {
		return errors.New("an audit line must not contain a line break")
	}
	if _, err := io.WriteString(l.stdin, line+"\n"); err != nil {
		return fmt.Errorf("write to klog: %w", err)
	}
	if !l.acks.Scan() {
		err := l.acks.Err()
		if err == nil {
			err = io.ErrUnexpectedEOF
		}
		return fmt.Errorf("klog stopped before confirming a line: %w", err)
	}
	if answer := l.acks.Text(); !strings.HasPrefix(answer, "ok ") {
		return fmt.Errorf("klog answered %q", answer)
	}
	return nil
}

// Close ends klog's input, so it finishes and exits, and waits for it.
func (l *Log) Close() error {
	_ = l.stdin.Close()
	return l.cmd.Wait()
}

// Line formats a JobChanged event as one audit line. It includes the
// message ID, so a line written twice (delivery is at least once) can be
// recognised as a duplicate when the log is read.
func Line(msg messages.Envelope) (string, error) {
	var event messages.JobChanged
	if err := messages.Decode(msg, messages.TypeJobChanged, &event); err != nil {
		return "", err
	}
	line := fmt.Sprintf("%s job=%d state=%s", msg.OccurredAt.UTC().Format(time.RFC3339Nano), event.JobID, event.State)
	if event.Reason != "" {
		line += fmt.Sprintf(" reason=%q", event.Reason)
	}
	return line + " id=" + msg.ID, nil
}
~~~

`Append` refuses a line containing a line break: it would arrive at `klog` as **two** records, and the second would get an `ok` that `Append` never reads, so every answer after it would be one behind. Every protocol needs a rule like this one about what the data itself may not contain.

Create `internal/audit/audit_test.go`:

<!-- file: internal/audit/audit_test.go -->
~~~go
package audit

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"runway/internal/messages"
)

// When FAKE_KLOG is set, this test binary acts as `klog ingest FILE`
// instead of running the tests, so the tests don't need the Rust build.
// It writes each line to FILE and answers "ok N". With FAKE_KLOG_DIE_AFTER
// set to n, it exits without answering after n lines, like a crash.
func TestMain(m *testing.M) {
	if os.Getenv("FAKE_KLOG") != "" {
		fakeKlog(os.Args[2])
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func fakeKlog(path string) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		os.Exit(2)
	}
	dieAfter, _ := strconv.Atoi(os.Getenv("FAKE_KLOG_DIE_AFTER"))
	lines := bufio.NewScanner(os.Stdin)
	for n := 0; lines.Scan(); n++ {
		if dieAfter > 0 && n == dieAfter {
			os.Exit(3)
		}
		fmt.Fprintln(file, lines.Text())
		fmt.Printf("ok %d\n", n)
	}
}

func start(t *testing.T) (*Log, string) {
	t.Helper()
	t.Setenv("FAKE_KLOG", "1")
	path := filepath.Join(t.TempDir(), "audit.log")
	log, err := Start(os.Args[0], path)
	if err != nil {
		t.Fatal(err)
	}
	return log, path
}

func TestEveryLineIsConfirmed(t *testing.T) {
	log, path := start(t)
	for _, line := range []string{"first", "second"} {
		if err := log.Append(line); err != nil {
			t.Fatal(err)
		}
	}
	if err := log.Close(); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); string(data) != "first\nsecond\n" {
		t.Fatalf("log holds %q", data)
	}
}

func TestADeadKlogIsAnError(t *testing.T) {
	t.Setenv("FAKE_KLOG_DIE_AFTER", "1")
	log, _ := start(t)
	defer log.Close()
	if err := log.Append("first"); err != nil {
		t.Fatal(err)
	}
	err := log.Append("second")
	if err == nil || !strings.Contains(err.Error(), "klog stopped before confirming") {
		t.Fatalf("error = %v, want klog stopped before confirming", err)
	}
}

func TestLineRejectsLineBreaks(t *testing.T) {
	log, _ := start(t)
	defer log.Close()
	if err := log.Append("one\ntwo"); err == nil {
		t.Fatal("a line with a line break was accepted: it would become two records")
	}
}

func TestLineFormat(t *testing.T) {
	at := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	msg, _ := messages.New(messages.TypeJobChanged, messages.JobChanged{JobID: 7, State: "failed", Reason: "disk full"}, at)
	line, err := Line(msg)
	want := `2026-10-05T12:00:00Z job=7 state=failed reason="disk full" id=` + msg.ID
	if err != nil || line != want {
		t.Fatalf("line = %q, %v\nwant %q", line, err, want)
	}
}
~~~

`TestMain` runs before the tests. With `FAKE_KLOG` set, the binary is a fake `klog` and never runs the tests at all. `t.Setenv` sets the variable for this test only, and the child process inherits it.

### The feed command

Create `cmd/auditfeed/main.go`:

<!-- file: cmd/auditfeed/main.go -->
~~~go
// Command auditfeed copies every job event from Kafka into klog, the
// checksummed append-only log from the Rust Bridge.
//
// It commits its Kafka offsets only after klog has confirmed every line in
// a batch is on disk. If klog or this process dies, the unconfirmed events
// are read again on restart, so none are lost; some may be written twice,
// and their message IDs show which.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"runway/internal/audit"
	"runway/internal/envconfig"
	"runway/internal/messages"
	"runway/internal/stream"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer) error {
	brokers := getenv("KAFKA_BROKERS")
	if brokers == "" {
		return errors.New("KAFKA_BROKERS must be set")
	}
	bin, path := getenv("KLOG_BIN"), getenv("AUDIT_LOG")
	if bin == "" {
		bin = "klog"
	}
	if path == "" {
		path = "audit.log"
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	list := strings.Split(brokers, ",")
	if err := stream.EnsureTopic(ctx, list, messages.JobEventsTopic, 3); err != nil {
		return err
	}
	consumer, err := stream.NewConsumer(list, "runway-audit", messages.JobEventsTopic, logger)
	if err != nil {
		return err
	}
	defer consumer.Close()

	auditLog, err := audit.Start(bin, path)
	if err != nil {
		return err
	}
	logger.Info("auditing", "topic", messages.JobEventsTopic, "log", path)
	runErr := consumer.Run(ctx, func(_ context.Context, msg messages.Envelope) error {
		line, err := audit.Line(msg)
		if err != nil {
			return err
		}
		return auditLog.Append(line)
	})
	if err := auditLog.Close(); err != nil && runErr == nil {
		runErr = fmt.Errorf("klog: %w", err)
	}
	return runErr
}
~~~

It has its own consumer group, `runway-audit`. It reads the same topic as the projector, independently, from the beginning, at its own pace. That's step 6's promise kept: adding a reader didn't touch the API.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

~~~bash
go test -v ./internal/audit/
~~~

~~~text
--- PASS: TestEveryLineIsConfirmed (0.00s)
--- PASS: TestADeadKlogIsAnError (0.00s)
--- PASS: TestLineRejectsLineBreaks (0.00s)
--- PASS: TestLineFormat (0.00s)
ok  	runway/internal/audit	0.017s
~~~

### Run it

Start the API with Kafka, and the feed:

~~~bash
export DATABASE_URL=postgres://runway:runway@localhost:5432/runway KAFKA_BROKERS=localhost:9092
go run ./cmd/api &
KLOG_BIN=audit/target/debug/klog AUDIT_LOG=audit.log go run ./cmd/auditfeed &
curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"audited","duration_ms":100}'
audit/target/debug/klog cat audit.log | tail -4
audit/target/debug/klog check audit.log
~~~

~~~text
28: 2026-10-05T19:33:32.188693759Z job=214 state=completed id=U4AF5V3K6R7FXSDHRKJLORBYQM
29: 2026-10-05T19:41:17.840369Z job=1000219 state=queued id=A3UAH3PY73H5IFT27L5OU5WZKO
30: 2026-10-05T19:41:17.869520356Z job=1000219 state=running id=3ER44FTXJXUBCU27XCEKGM7T2N
31: 2026-10-05T19:41:17.97041766Z job=1000219 state=completed id=6JORVSQ5KGNAQMMJBRGX4PAZRI
32 records, all checksums valid
~~~

The feed started with no committed offsets, so it first wrote every event still in the topic (records 0 to 28, from step 6's jobs), then the new job's three. The job ID is above a million because of step 8's experiment. `kafka-consumer-groups.sh --describe --group runway-audit` shows lag 0 on all three partitions.

**Break it: kill klog.** With the API and the feed running, kill the Rust process, then create a job:

~~~bash
pkill -x klog
curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"while klog was down","duration_ms":100}'
~~~

The feed exits with status 1:

~~~text
partition 0, offset 14: write to klog: write |1: broken pipe
~~~

`broken pipe` is what writing to a pipe whose reader has gone looks like (`|1` is how Go names the pipe). The feed stopped at the first event it couldn't confirm and committed nothing past it. Start the feed again, exactly as before:

~~~text
32: 2026-10-05T19:41:42.303102Z job=1000220 state=queued id=A2IPWPOK77SR6FIUWQEQJN4T5H
33: 2026-10-05T19:41:42.33282696Z job=1000220 state=running id=4XEHGU5PRZZ2W7HB63LXGQGGFR
34: 2026-10-05T19:41:42.434720421Z job=1000220 state=completed id=7EVN3DHI46E4AVZ5HX3DODLZR4
35 records, all checksums valid
~~~

All three events of the job created while `klog` was dead are there: Kafka held them until the feed could confirm them. To check for duplicates, count message IDs that appear twice:

~~~bash
audit/target/debug/klog cat audit.log | awk '{print $NF}' | sort | uniq -d | wc -l
~~~

~~~text
0
~~~

(`$NF` is awk's last field, the `id=...`; `uniq -d` prints only repeated lines.) Zero this time: `klog` died *before* confirming anything, so nothing was written twice. Duplicates need the other window, where the feed dies after `klog`'s `ok` but before the commit. It's narrow, but it exists, and the IDs are how you'd find it.

**Explain it:** why does the feed commit only after `klog` confirms, and what does that guarantee? When can a line be written twice, and how would you detect it? What does CRC-32C protect against, and what doesn't it? Why must an audit line never contain a line break?

**Read.** *The Linux Programming Interface* (Kerrisk), Ch. 44, *Pipes and FIFOs*, §44.1–44.4. Then the *Certificate Transparency* overview (certificate.transparency.dev, *How CT works*), on logs that can prove nobody rewrote them. Carry this question in: what would `klog` need so that an auditor could prove no record was changed or removed?

---

## Step 11: Backup, restore and crash recovery

**The problem.** Everything so far trusts that PostgreSQL's disk is still there. Disks fail, people run `DELETE` without a `WHERE`, and a bad migration drops a column. **A backup you've never restored is a hope, not a backup.** This step is a drill: take a backup, lose data on purpose, restore, and find out exactly what you got back and what you didn't.

There's no new Go code in this step. Everything here is commands you run.

**New ideas.**

- **RPO and RTO.** The **recovery point objective** is how much data you can afford to lose: everything since the last backup. The **recovery time objective** is how long you can afford to be down while restoring. Every backup method is a trade-off between the two and cost.
- A **logical backup** (`pg_dump`) writes the data out as SQL, or in PostgreSQL's compact *custom* format. It reads everything inside one `REPEATABLE READ` transaction, so the dump is a **consistent snapshot**, even while the API keeps writing. `pg_restore` loads it into a database. Its RPO is "since the last dump", and on big databases its RTO is long.
- A **physical backup** copies the database's files, and **WAL archiving** keeps every write-ahead-log segment written since. Replaying the WAL on top of the copy gives **point-in-time recovery**: restore to 14:03:07, just before the bad `DELETE`. Tools such as pgBackRest and WAL-G do this in production. The RPO shrinks to seconds.
- The **write-ahead log (WAL)** is why a *committed* transaction survives a crash at all. Before changing any data page, PostgreSQL appends a description of the change to the WAL and, at `COMMIT`, waits for the WAL to reach the disk with `fsync`. After a crash, it **replays** the WAL from the last checkpoint. It's the same idea as `klog`: an append-only log, checked record by record, read until the first record that isn't valid.
- **A restore travels back in time, and the rest of the world doesn't.** Kafka, the audit log and your clients all remember things that happened *after* the backup. A restore that doesn't account for them causes new problems.

### Take a backup

Run the API and the audit feed (as in step 10), then dump the database:

~~~bash
docker compose exec -T postgres pg_dump -U runway --format=custom runway > runway.dump
wc -c runway.dump
docker compose exec postgres psql -U runway -Atc "SELECT 'jobs: ' || count(*) || ', highest id: ' || max(id) FROM jobs"
~~~

~~~text
21527 runway.dump
jobs: 219, highest id: 1000220
~~~

(`-T` stops Compose from allocating a terminal, so the binary dump goes into the file unchanged. `||` joins strings in SQL.) Now the world moves on: create two more jobs after the backup.

~~~bash
for i in 1 2; do curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"after the backup","duration_ms":50}'; echo; done
~~~

~~~text
{"id":1000221,"state":"queued","description":"after the backup",...}
{"id":1000222,"state":"queued","description":"after the backup",...}
~~~

### Restore it

Pretend the database is lost. Restore the backup into a **new** database beside it, so you can compare the two (in a real incident you'd restore onto a new server):

~~~bash
docker compose exec postgres createdb -U runway runway_restore
docker compose exec -T postgres pg_restore -U runway --dbname=runway_restore < runway.dump
docker compose exec postgres psql -U runway -d runway_restore -Atc "SELECT 'jobs: ' || count(*) || ', highest id: ' || max(id) FROM jobs"
~~~

~~~text
jobs: 219, highest id: 1000220
~~~

Exactly the backup, and nothing after it. The two jobs created after the dump are gone from the restored database. **But not from everywhere.** Their events are in Kafka, and in the audit log. Ask the audit log which jobs it knows about that the restored database doesn't:

~~~bash
audit/target/debug/klog cat audit.log | grep -o 'job=[0-9]*' | cut -d= -f2 | sort -u > audit-ids
docker compose exec -T postgres psql -U runway -d runway_restore -Atc "SELECT id FROM jobs" | sort -u > db-ids
comm -23 audit-ids db-ids
~~~

~~~text
1000221
1000222
~~~

(`comm -23` prints the lines found only in the first file. Both must be sorted the same way, which is why both go through plain `sort`.) The audit log just told you exactly what the restore lost. That's one reason to keep a stream of events **outside** the database: it's evidence for reconciling after a disaster, such as telling the two clients whose jobs vanished.

Now look at a subtler problem. What ID will the restored database give the next job?

~~~bash
docker compose exec postgres psql -U runway -d runway_restore -Atc "SELECT nextval(pg_get_serial_sequence('jobs', 'id'))"
~~~

~~~text
1000221
~~~

**The same ID as a job that already exists in the audit log, Kafka and a client's records**, but it would be a different job. Every consumer that keys on job ID would now merge two unrelated jobs. Before a restored database takes traffic, move its identity past every ID the outside world has seen:

~~~bash
docker compose exec postgres psql -U runway -d runway_restore -Atc "SELECT setval(pg_get_serial_sequence('jobs', 'id'), 1000222)" -c "SELECT nextval(pg_get_serial_sequence('jobs', 'id'))"
~~~

~~~text
1000222
1000223
~~~

(`nextval` used one ID itself, so the gap is harmless.) Write both checks into your recovery runbook: find what was lost, and move the IDs past everything already published. Unsent outbox rows restored from the backup are fine, by the way: they'll be sent again, and every receiver is idempotent.

### Where durability comes from

Look at the settings that make commits durable, and at how much WAL a thousand inserts write:

~~~bash
docker compose exec -T postgres psql -U runway <<'SQL'
SHOW fsync;
SHOW synchronous_commit;
CREATE TEMP TABLE lsn AS SELECT pg_current_wal_lsn() AS before;
INSERT INTO jobs (description, duration_ms, state, created_at, updated_at)
SELECT 'wal', 100, 'completed', now(), now() FROM generate_series(1, 1000);
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), before)) AS wal_written FROM lsn;
DELETE FROM jobs WHERE description = 'wal';
SQL
~~~

~~~text
 fsync 
-------
 on
(1 row)

 synchronous_commit 
--------------------
 on
(1 row)

 wal_written 
-------------
 276 kB
(1 row)
~~~

A **log sequence number** (LSN) is a position in the WAL, so the difference between two of them is how many bytes were written. 1,000 small rows wrote 276 kB of WAL: each row plus its index entries, plus bookkeeping. Every write you make is written at least twice, once to the log and later to the table. `synchronous_commit = on` means `COMMIT` waits for the WAL `fsync`. Turning it off makes commits faster and risks losing the last few hundred milliseconds of commits in a crash (though never corrupting the database). That trade-off is the database's version of the decisions you made for `klog`.

Now crash it for real. Commit one row, then kill the server with SIGKILL, with no chance to shut down cleanly:

~~~bash
docker compose exec postgres psql -U runway -Atc "INSERT INTO jobs (description, duration_ms, state, created_at, updated_at) VALUES ('survives a crash', 100, 'queued', now(), now()) RETURNING id"
docker compose kill -s KILL postgres
docker compose start postgres
docker compose logs postgres | tail -20
~~~

~~~text
LOG:  database system was interrupted; last known up at 2026-10-05 19:37:20 UTC
LOG:  database system was not properly shut down; automatic recovery in progress
LOG:  redo starts at 0/28FB1A0
LOG:  invalid record length at 0/119ABEF8: expected at least 24, got 0
LOG:  redo done at 0/119ABED0 system usage: CPU: user: 1.83 s, system: 0.47 s, elapsed: 2.32 s
LOG:  database system is ready to accept connections
~~~

(Each line's `postgres-1 |` prefix, timestamp and process ID are trimmed.) Read it as a story:
1. PostgreSQL noticed it hadn't shut down cleanly.
2. It started replaying the WAL from the last checkpoint ("redo").
3. It read until it found a record that wasn't valid: `invalid record length ... got 0`. That isn't an error. It's the **end of the log**, found exactly the way `klog` finds a torn tail.
4. It finished replaying and opened for business.

Your row is there:

~~~bash
docker compose exec postgres psql -U runway -Atc "SELECT id, description FROM jobs WHERE description = 'survives a crash'"
~~~

~~~text
1001223|survives a crash
~~~

Recovery took 2.3 seconds here, because step 8's million-row insert and delete were still in the WAL since the last checkpoint. That's a real trade-off: **checkpoints** (writing dirty pages to the table files so that the WAL before them is no longer needed) cost I/O while running, and save time during recovery.

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

Finally, run the tests once with the server variables unset. Every integration test should say `SKIP`, and none should fail. A test that only works when its server is there is a test that breaks on someone else's laptop.

<!-- run: env -u RUNWAY_AMQP_URL -u RUNWAY_DATABASE_URL -u RUNWAY_REDIS_URL -u RUNWAY_KAFKA_BROKERS go test -count=1 ./... -->
~~~bash
env -u RUNWAY_AMQP_URL -u RUNWAY_DATABASE_URL -u RUNWAY_REDIS_URL -u RUNWAY_KAFKA_BROKERS go test ./...
~~~

**Explain it:** define RPO and RTO, and give each for nightly `pg_dump`s and for WAL archiving. Why is a `pg_dump` consistent even while the API writes? After the restore, what did the audit log tell you, and why must the identity be moved forward before the database takes traffic? Read the recovery log aloud: what does `invalid record length ... got 0` mean?

**Read.** The PostgreSQL manual, Ch. 25 *Backup and Restore* (§25.1 and §25.3, *Continuous Archiving and Point-in-Time Recovery*) and Ch. 28 *Reliability and the Write-Ahead Log*, §28.1–28.3. Then DDIA Ch. 3, the sections on B-trees, *Making B-trees reliable*, and *Comparing B-Trees and LSM-Trees*. Carry this question in: `klog` and PostgreSQL both recover by replaying a log. What does PostgreSQL do that `klog` doesn't, and why does it need to?

---

## Rebuild it yourself

Close the guide. In your own `runway` repository, rebuild Phase 3 from these contracts:
- the migrations, in order, and why each exists;
- the repository and key-store contracts;
- the outbox table and the relay's rules (order, batch, at least once, `SKIP LOCKED`);
- the job-events topic: key, partitions, message type and version;
- the inbox, and the projection's per-group counts;
- the cache's TTL policy, its key format, and its fail-open breaker;
- the background tasks, their intervals, and the advisory lock;
- the database breaker and what counts as a failure;
- the `klog ingest` protocol: one line in, `ok OFFSET` out.

Use TDD throughout: the contract tests and the isolation tests first. Then repeat the four key experiments on *your* code, and record the evidence:
1. kill the API between commit and send;
2. replay a projection under a new group;
3. freeze the database and watch the breaker;
4. restore a backup and reconcile it against the audit log.

## Checkpoint

You're ready for Phase 4 when you can, without the guide:

1. Write SQL to create, read and update rows with parameters, and explain exactly why parameters stop SQL injection.
2. Explain what a migration is, why the API takes an advisory lock to run them, and why `CREATE INDEX CONCURRENTLY` can't run in a transaction.
3. Size a connection pool with Little's law, and read `db_pool_waits_total` after a burst.
4. State ACID, draw the lost-update timeline, and give three fixes with their costs.
5. Explain the dual-write problem and how the transactional outbox closes it, including why it's at least once.
6. Explain how `INSERT ... ON CONFLICT DO NOTHING` makes claiming a key atomic across instances.
7. Compare a RabbitMQ queue and a Kafka topic in five ways, and explain partitions, keys, consumer groups, offsets, lag and replay.
8. Explain the inbox pattern and when a consumer needs one.
9. Explain cache-aside, the stale-set race, stampedes and singleflight, and why a cache must fail open.
10. Read an `EXPLAIN ANALYZE` plan, and explain why a partial index fits the reaper's query.
11. Say which errors should open a database breaker, and the difference between liveness and readiness.
12. Explain the `klog ingest` protocol, and when an audit line can be written twice.
13. Define RPO and RTO, restore a `pg_dump`, reconcile it, and explain what the WAL replay in the recovery log did.

## If it goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| Tests say `SKIP` | The `RUNWAY_*` variable for that server isn't set | Export the variables from Setup, in the shell that runs the tests |
| `connect to PostgreSQL: ... connection refused` | PostgreSQL isn't running or isn't healthy yet | `docker compose up -d --wait postgres`; check `docker compose ps` |
| `failed SASL auth: ... password authentication failed` | Wrong password in `DATABASE_URL`, or the volume was created earlier with a different password | Fix the URL; `docker compose down -v` deletes the old volume, and its data |
| `tls error: server refused TLS connection` above another error | pgx tried TLS first; the local server has none | Harmless here; read the next line for the real error. Phase 6 adds TLS |
| `FATAL: sorry, too many clients already` | More connections than `max_connections` | Lower `DB_MAX_CONNS` per instance, or run fewer instances; a proxy such as PgBouncer for many |
| `partial migration error ... duplicate key value ... pg_type_typname_nsp_index` | Two instances migrated at once without the lock | Add the goose session locker (step 5) |
| `migrate: failed to initialize: terminated signal received` | An instance was stopped while it waited for the migration lock | Expected if you stop it within a minute; otherwise check which instance holds the lock |
| Jobs stay `queued` with a database | The relay isn't running, or the broker is unreachable | Check `outbox_pending`, and the API's `outbox relay failed` warnings |
| A Kafka consumer hangs on shutdown | `AllowRebalance` isn't called after every poll | Call it on every path out of the poll, including cancellation (step 6) |
| A projector logs nothing for several seconds at start-up | It's joining the consumer group | Normal: joins take a few seconds. Check the group with `kafka-consumer-groups.sh --describe` |
| Counts in the projection are too high | Events were counted twice: no inbox, or the inbox insert is outside the transaction | Inbox and count in one transaction (step 6) |
| `connect to Redis: ... connection refused` at start-up | `REDIS_URL` is set but Redis isn't running | `docker compose up -d --wait redis`, or unset `REDIS_URL` |
| Reads stay slow after Redis comes back | The cache breaker is still open | Wait `BREAKER_COOLDOWN`; check `cache_breaker_state` |
| Every request answers 503 in milliseconds | The database breaker is open | Check `db_breaker_state` and `/ready`; fix the database, then wait out the cooldown |
| A job was failed as abandoned, then its worker finished it | `ABANDON_AFTER` is shorter than a real run plus its retries | Make it longer than a worker's whole retry cycle |
| `write to klog: write |1: broken pipe` | The `klog` child process died | Check `klog`'s error on standard error; restart the feed, and it re-reads the uncommitted events |
| `start klog: exec: "klog": executable file not found` | `KLOG_BIN` isn't set and `klog` isn't on `PATH` | `KLOG_BIN=audit/target/debug/klog`, after `cargo build` in `audit/` |

## Reading list for this phase

| When | Reading | Question to carry in |
|---|---|---|
| Step 1 | PostgreSQL *Tutorial* Ch. 2–3, *Constraints* §5.5; DDIA Ch. 2 | Which rules belong in the domain, which in the database? |
| Step 2 | PostgreSQL §19.3.1; HikariCP *About Pool Sizing* | What should `DB_MAX_CONNS` be for ten instances? |
| Step 3 | DDIA Ch. 7; PostgreSQL Ch. 13, §13.2 | Which anomalies can still happen in Runway? |
| Step 4 | microservices.io *Transactional outbox*; PostgreSQL *The Locking Clause* | What changes with two brokers? |
| Step 5 | Brandur Leach, *Implementing Stripe-like Idempotency Keys in Postgres*; PostgreSQL `ON CONFLICT` | What does a key protect against, and what not? |
| Step 6 | Kreps, *The Log*; DDIA Ch. 11; Kafka docs, *Design* | Tables or stream: which is the truth? |
| Step 7 | AWS *Database Caching Strategies Using Redis*; *Scaling Memcache at Facebook* §3.2.1 | How do leases fix both races? |
| Step 8 | *Use The Index, Luke!* Ch. 1–2; PostgreSQL §14.1, §11.8 | Why didn't `id` need an index? |
| Step 9 | Nygard, *Release It!* Ch. 5; Kubernetes probes docs | What should `/ready` check, and leave out? |
| Step 10 | Kerrisk, *TLPI* Ch. 44; Certificate Transparency, *How CT works* | How would an auditor prove nothing was removed? |
| Step 11 | PostgreSQL Ch. 25 and Ch. 28; DDIA Ch. 3 | What does PostgreSQL's recovery do that `klog`'s doesn't? |
| After the phase | *Database Internals* (Petrov), Part I, Ch. 1–2 and Ch. 5; the Raft paper's introduction (you'll need it in Phase 4) | What breaks when there are two copies of the database? |
