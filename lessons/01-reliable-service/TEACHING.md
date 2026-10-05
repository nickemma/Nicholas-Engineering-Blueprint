# Phase 1 teaching: make one service reliable

Phase 0 answered one request. Real services answer many requests at once from callers who send bad input, give up halfway, or hit the service while it is restarting. This phase turns the Phase 0 server into a small **jobs service** that stays correct under all of that, and is organised the way production Go services are.

**The goal:** a client can submit a job, look it up, and run it. The service rejects bad input precisely, never runs a job twice, stops slow work at a deadline, explains itself through logs and metrics, and shuts down without dropping requests that are already in flight.

**Time:** about 4 weeks at 12–15 hours a week.

**Before you start:** finish Phase 0, including its checkpoint. You need the same tools (Go 1.26+, Git, curl).

**What you'll have at the end:** a layered Go service (domain → service → repository → HTTP) built test-first; a race you caused, saw the race detector catch, and fixed; a lost-update bug fixed with compare-and-swap; request deadlines; structured logs and Prometheus metrics; graceful shutdown with a test that proves it.

## How this guide works

The step parts are the same as Phase 0: **the problem, new ideas, the code, run it, break it, explain it, read.** You type all the code yourself, in your `practice/` folder, as you read. The first time a file appears you get the whole file; after that you get precise edits ("change this to that", "add this at the end"). CI builds the code from this guide on every change, so every step is known to work. There's no finished version to copy, by design.

| Step | What you add |
|---|---|
| 1 | What a job is; legal state changes; tests first |
| 2 | A storage interface and an in-memory store; your first data race |
| 3 | Use cases, dependency injection, and a race a mutex can't fix |
| 4 | HTTP routes, strict JSON, and mapping errors to status codes |
| 5 | Wiring everything in `main`; configuration; server timeouts |
| 6 | Request deadlines and cancellation |
| 7 | Structured logs, metrics, panic recovery, middleware order |
| 8 | Signals and graceful shutdown |

## Setup

From the repository root:

~~~bash
cd lessons/01-reliable-service
mkdir -p practice
cd practice
go mod init runway
~~~

The module is called `runway` this time because the code is split into packages that import each other by path, such as `runway/internal/jobs`.

### The contract

Write this table into your notes **before** coding. It is what callers may rely on, and every test in this phase checks one row of it.

| Request | Success | Errors |
|---|---|---|
| `GET /health` | `200` `{"status":"ok"}` | — |
| `POST /jobs` with `{"description": "...", "duration_ms": 300}` | `201`, the job in state `queued`, and a `Location: /jobs/{id}` header | `400` bad JSON, missing or invalid fields, unknown fields; `413` body over 1 KiB; `415` not `application/json` |
| `GET /jobs/{id}` | `200` and the job | `400` id not a positive integer; `404` no such job |
| `POST /jobs/{id}/run` | `200` and the job in state `completed` | `404` no such job; `409` job not queued; `504` the work passed the request deadline (the job is now `failed`) |
| Any other method on these paths | — | `405` with an `Allow` header |

A job's `duration_ms` (0–5000) is how long its simulated work takes. That's how you'll create slow requests on purpose.

### The shape of the code

~~~mermaid
flowchart LR
    C[Client] --> H[httpapi<br/>routes, JSON, status codes]
    H --> S[jobs.Service<br/>use cases]
    S --> D[jobs.Job<br/>rules and states]
    S --> R{{jobs.Repository<br/>interface}}
    M[memstore.Store<br/>map + mutex] -. implements .-> R
    MAIN[cmd/api main<br/>wires it all] --> H
    MAIN --> S
    MAIN --> M
~~~

~~~text
cmd/api/main.go             the composition root: builds everything and starts the server
internal/jobs/job.go        domain: Job, states, rules            (step 1)
internal/jobs/repository.go the storage interface the domain needs (step 2)
internal/memstore/store.go  an in-memory implementation of it      (step 2)
internal/jobs/service.go    use cases: Create, Get, Run            (step 3)
internal/httpapi/           HTTP: handlers, JSON, middleware       (steps 4, 6, 7)
~~~

Each layer only knows about the one below it, through an interface where it matters. The domain knows nothing about HTTP or storage. That **layered architecture** is why, in Phase 3, you'll swap the in-memory store for PostgreSQL without touching a handler. `internal/` is special in Go: code outside this module can't import it, so these packages are private to the service.

---

## Step 1: The domain, written test-first
<!-- run: go mod init runway -->


**The problem.** In Phase 0 the rules lived inside handlers. A job service has more rules: a description must be 1–200 characters, the duration must be in range, and a job can go from `queued` to `running`, but never from `completed` back to `running`. If those rules live in HTTP code, every new entry point (a CLI, a queue consumer in Phase 2) has to copy them, and copies drift. The rules belong in one place that knows nothing about HTTP: the **domain**.

**New ideas.**

- **Test-driven development (TDD)** from Phase 0 is now the default. For each rule, write the test, run it and watch it fail, then write the code.
- A **state machine** lists the states and the transitions allowed between them:

  ~~~mermaid
  stateDiagram-v2
      [*] --> queued
      queued --> running: Start
      running --> completed: Complete
      running --> failed: Fail
  ~~~

  Anything not drawn is illegal. Writing the allowed transitions as **data** (a map) instead of scattered `if` statements makes the rules readable and testable in one table.
- An **entity** has an identity that stays the same while its data changes. A job is an entity: job 7 is still job 7 after it completes.
- A **value object** is defined only by its value and is always valid. `Description` is a value object: the only way to get one is `NewDescription`, which validates it. Any function that receives a `Description` knows it's valid without checking again. These two ideas come from **domain-driven design (DDD)**; this is its "tactical" half.
- **Errors are values** in Go. `errors.New` makes a **sentinel** error you can compare against. `fmt.Errorf("%w: ...", ErrInvalidTransition, ...)` *wraps* it with more detail, and `errors.Is(err, ErrInvalidTransition)` still finds it inside.
- A **method** is a function attached to a type: `func (j *Job) Start(...)`. The `*Job` **pointer receiver** means the method can change the job. `func (j Job) CanTransitionTo(...)` has a **value receiver**: it gets a copy, so it can only read.
- `type ID int64` makes a new type. An `ID` can't be passed by accident where some other `int64` is expected.

**Write the test first.** Create `internal/jobs/job_test.go`:

<!-- file: internal/jobs/job_test.go -->
~~~go
package jobs

import (
	"errors"
	"strings"
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)

func TestNewDescription(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		want    Description
		wantErr error
	}{
		{"plain", "resize images", "resize images", nil},
		{"trims spaces", "  resize  ", "resize", nil},
		{"empty", "", "", ErrInvalidDescription},
		{"only spaces", "   ", "", ErrInvalidDescription},
		{"200 characters", strings.Repeat("a", 200), Description(strings.Repeat("a", 200)), nil},
		{"201 characters", strings.Repeat("a", 201), "", ErrInvalidDescription},
		{"counts characters, not bytes", strings.Repeat("é", 200), Description(strings.Repeat("é", 200)), nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NewDescription(tt.raw)
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("error = %v, want %v", err, tt.wantErr)
			}
			if got != tt.want {
				t.Fatalf("description = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestNewJobIsQueued(t *testing.T) {
	job, err := New("resize", time.Second, t0)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if job.State != StateQueued {
		t.Fatalf("state = %s, want %s", job.State, StateQueued)
	}
	if !job.CreatedAt.Equal(t0) || !job.UpdatedAt.Equal(t0) {
		t.Fatalf("timestamps = %v/%v, want %v", job.CreatedAt, job.UpdatedAt, t0)
	}
}

func TestNewJobRejectsBadDuration(t *testing.T) {
	for _, d := range []time.Duration{-time.Millisecond, MaxDuration + time.Millisecond} {
		if _, err := New("resize", d, t0); !errors.Is(err, ErrInvalidDuration) {
			t.Errorf("New(duration=%v) error = %v, want %v", d, err, ErrInvalidDuration)
		}
	}
}

func TestTransitions(t *testing.T) {
	tests := []struct {
		from  State
		to    State
		legal bool
	}{
		{StateQueued, StateRunning, true},
		{StateQueued, StateCompleted, false},
		{StateQueued, StateFailed, false},
		{StateRunning, StateCompleted, true},
		{StateRunning, StateFailed, true},
		{StateRunning, StateQueued, false},
		{StateCompleted, StateRunning, false},
		{StateCompleted, StateFailed, false},
		{StateFailed, StateRunning, false},
	}
	for _, tt := range tests {
		t.Run(string(tt.from)+"->"+string(tt.to), func(t *testing.T) {
			job := Job{State: tt.from}
			if got := job.CanTransitionTo(tt.to); got != tt.legal {
				t.Fatalf("CanTransitionTo = %v, want %v", got, tt.legal)
			}
		})
	}
}

func TestLifecycle(t *testing.T) {
	job, _ := New("resize", 0, t0)
	later := t0.Add(time.Minute)

	if err := job.Start(later); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := job.Complete(later); err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if job.State != StateCompleted || !job.UpdatedAt.Equal(later) {
		t.Fatalf("job = %+v, want completed at %v", job, later)
	}
	if err := job.Complete(later); !errors.Is(err, ErrInvalidTransition) {
		t.Fatalf("second Complete error = %v, want %v", err, ErrInvalidTransition)
	}
}

func TestFailRecordsReason(t *testing.T) {
	job, _ := New("resize", 0, t0)
	_ = job.Start(t0)
	if err := job.Fail("deadline exceeded", t0); err != nil {
		t.Fatalf("Fail: %v", err)
	}
	if job.State != StateFailed || job.FailureReason != "deadline exceeded" {
		t.Fatalf("job = %+v, want failed with reason", job)
	}
}
~~~

Run `go test ./...`. It fails to compile: `undefined: Description`, `undefined: New`, and so on. That's the **red** step. The test describes code that doesn't exist yet.

Notice what the tests pin down: the trimming rule, both sides of the 200-character boundary, characters vs bytes, every legal *and* illegal transition, and that time comes in as a parameter (`t0`) rather than being read from the clock. A function that calls `time.Now()` inside can't be tested for exact timestamps.

**Now make it pass.** Create `internal/jobs/job.go`:

<!-- file: internal/jobs/job.go -->
~~~go
// Package jobs is the domain: what a job is, which states it can be in, and
// which changes between states are allowed. It knows nothing about HTTP or
// storage.
package jobs

import (
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

// ID identifies a job. It is its own type so an ID can't be confused with
// any other integer.
type ID int64

// State is where a job is in its lifecycle.
type State string

const (
	StateQueued    State = "queued"
	StateRunning   State = "running"
	StateCompleted State = "completed"
	StateFailed    State = "failed"
)

const (
	MaxDescriptionLength = 200
	MaxDuration          = 5 * time.Second
)

var (
	ErrInvalidDescription = errors.New("description must be between 1 and 200 characters")
	ErrInvalidDuration    = errors.New("duration must be between 0 and 5s")
	ErrInvalidTransition  = errors.New("invalid state transition")
)

// Description is a value object: a string that is known to be valid,
// because the only way to make one is NewDescription.
type Description string

func NewDescription(raw string) (Description, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || utf8.RuneCountInString(trimmed) > MaxDescriptionLength {
		return "", ErrInvalidDescription
	}
	return Description(trimmed), nil
}

// Job is an entity: it has an identity that stays the same while its state
// changes.
type Job struct {
	ID            ID
	Description   Description
	Duration      time.Duration
	State         State
	FailureReason string
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// New returns a queued job. The repository assigns its ID.
func New(description Description, duration time.Duration, now time.Time) (Job, error) {
	if duration < 0 || duration > MaxDuration {
		return Job{}, ErrInvalidDuration
	}
	return Job{
		Description: description,
		Duration:    duration,
		State:       StateQueued,
		CreatedAt:   now,
		UpdatedAt:   now,
	}, nil
}

// allowed lists every legal state change. Anything not listed is refused.
var allowed = map[State][]State{
	StateQueued:  {StateRunning},
	StateRunning: {StateCompleted, StateFailed},
}

func (j Job) CanTransitionTo(next State) bool {
	for _, state := range allowed[j.State] {
		if state == next {
			return true
		}
	}
	return false
}

func (j *Job) transition(next State, now time.Time) error {
	if !j.CanTransitionTo(next) {
		return fmt.Errorf("%w: %s to %s", ErrInvalidTransition, j.State, next)
	}
	j.State = next
	j.UpdatedAt = now
	return nil
}

func (j *Job) Start(now time.Time) error {
	return j.transition(StateRunning, now)
}

func (j *Job) Complete(now time.Time) error {
	return j.transition(StateCompleted, now)
}

func (j *Job) Fail(reason string, now time.Time) error {
	if err := j.transition(StateFailed, now); err != nil {
		return err
	}
	j.FailureReason = reason
	return nil
}
~~~

How to read it:

- `const ( ... )` groups constants. `StateQueued State = "queued"` gives the constant the type `State`, so you can't accidentally pass any old string where a state is expected.
- `var allowed = map[State][]State{...}`: a **map** from a state to a **slice** (list) of the states you may move to. `allowed[StateCompleted]` isn't in the map, so it returns an empty slice: no transitions out of `completed`. The rule "terminal states are final" falls out of the data without any special code.
- `transition` is lowercase, so it's private to the package. Callers must use `Start`, `Complete` or `Fail`, which name intentions, not raw states.
- `Fail` calls `transition` and only records the reason if the transition succeeded. A guard clause again.
- `time.Duration` is Go's type for lengths of time. `5 * time.Second` reads like English.

**Run it.**

~~~bash
go test -v ./...
~~~

You'll see each subtest pass, including names like `TestTransitions/queued->running`. That's **green**.

**Break it.**

1. Add `StateCompleted: {StateRunning},` to `allowed`. Predict which tests fail, then run them. `TestTransitions/completed->running` and the second-`Complete` check in `TestLifecycle` both catch it. One line of data changed the rules, and the table caught it immediately.
2. Change `utf8.RuneCountInString(trimmed)` to `len(trimmed)`. The "counts characters, not bytes" case fails: 200 `é` characters are 400 bytes.

**Explain it:** why do the domain functions take `now time.Time` as a parameter instead of calling `time.Now()`? What does making `Description` a type buy you, compared with a plain `string`?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Step 2: A repository, and your first data race

**The problem.** Jobs must be stored somewhere. But if the service talks to "a map" directly, then swapping in a database in Phase 3 means rewriting the service. And the moment two requests arrive at once, a plain map breaks in a way you can't see by reading the code.

**New ideas: ports and adapters.**

- An **interface** in Go is a list of method signatures. Any type that has those methods **satisfies** the interface automatically. Nothing needs to declare "implements".
- The domain defines the interface it needs, `Repository`, and a separate package provides an implementation. This is the **repository pattern**. Seen from the domain, `Repository` is a **port** (a socket the domain exposes), and `memstore.Store` is an **adapter** that plugs into it. Phase 3 adds a second adapter for PostgreSQL. The dependency points **inward**: `memstore` imports `jobs`, never the other way round.
- Every method takes a `context.Context` first. A context carries a cancellation signal and an optional deadline from the caller. The in-memory store doesn't need it much yet, but a database call does. Putting it in the interface now means Phase 3 doesn't change the signature.

Create `internal/jobs/repository.go`:

<!-- file: internal/jobs/repository.go -->
~~~go
package jobs

import (
	"context"
	"errors"
)

var (
	ErrNotFound = errors.New("job not found")
	ErrConflict = errors.New("job was changed by another request")
)

// Repository is the port the domain needs for storage. The domain defines
// it; storage packages implement it. Phase 1 uses an in-memory store and
// Phase 3 adds PostgreSQL without changing this interface.
type Repository interface {
	// Create stores a new job, assigns its ID, and returns the stored job.
	Create(ctx context.Context, job Job) (Job, error)

	// Get returns the job with this ID, or ErrNotFound.
	Get(ctx context.Context, id ID) (Job, error)

	// Update replaces the stored job only if its current state is still
	// expected. Otherwise it returns ErrConflict and changes nothing. This
	// compare-and-swap stops two requests from both acting on the same
	// old state.
	Update(ctx context.Context, job Job, expected State) error
}
~~~

`Update` takes an `expected` state. Step 3 explains why that parameter is the most important line in this phase.

**New ideas: concurrency.**

- A **goroutine** is a function running concurrently with the rest of the program, started with `go f()`. Go's HTTP server runs each request in its own goroutine. Goroutines are cheap: thousands are normal.
- Goroutines in one process **share memory**. If two of them touch the same map at the same time and at least one is writing, that's a **data race**. The result is undefined: values can be lost or duplicated, and Go's map deliberately crashes the program if it detects concurrent writes.
- A **mutex** (mutual exclusion lock) lets only one goroutine at a time into a **critical section**. `sync.RWMutex` has two modes: `Lock` for writers (exclusive) and `RLock` for readers (many readers at once, no writers).
- `defer s.mu.Unlock()` releases the lock when the function returns, by **any** path. You can't forget to unlock on an early return.
- A goroutine is not a process. Goroutines share one address space, so they share memory. Processes don't, which is why Phase 2 needs a network to connect them.

Create `internal/memstore/store.go`:

<!-- file: internal/memstore/store.go -->
~~~go
// Package memstore keeps jobs in this process's memory. Everything it holds
// is lost when the process exits.
package memstore

import (
	"context"
	"sync"

	"runway/internal/jobs"
)

// Store implements jobs.Repository. Its mutex protects the map and the ID
// counter: every read and write of either holds the lock. Like a real
// database client, it refuses to start work for a context that is already
// cancelled.
type Store struct {
	mu     sync.RWMutex
	nextID jobs.ID
	jobs   map[jobs.ID]jobs.Job
}

func New() *Store {
	return &Store{jobs: make(map[jobs.ID]jobs.Job)}
}

func (s *Store) Create(ctx context.Context, job jobs.Job) (jobs.Job, error) {
	if err := ctx.Err(); err != nil {
		return jobs.Job{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	s.nextID++
	job.ID = s.nextID
	s.jobs[job.ID] = job
	return job, nil
}

func (s *Store) Get(ctx context.Context, id jobs.ID) (jobs.Job, error) {
	if err := ctx.Err(); err != nil {
		return jobs.Job{}, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	job, ok := s.jobs[id]
	if !ok {
		return jobs.Job{}, jobs.ErrNotFound
	}
	return job, nil
}

func (s *Store) Update(ctx context.Context, job jobs.Job, expected jobs.State) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	current, ok := s.jobs[job.ID]
	if !ok {
		return jobs.ErrNotFound
	}
	if current.State != expected {
		return jobs.ErrConflict
	}
	s.jobs[job.ID] = job
	return nil
}
~~~

Details that matter:

- `job, ok := s.jobs[id]` is the "comma ok" form. Reading a missing key returns the zero value, and `ok` tells you whether the key was really there.
- Jobs are stored **by value** (`map[jobs.ID]jobs.Job`, not `*jobs.Job`). `Get` returns a copy, so a caller can't change stored data without going through `Update`. If the map held pointers, two goroutines could modify the same job outside the lock.
- `ctx.Err()` is non-nil once the context is cancelled or past its deadline. Checking it first means a request that has already been abandoned doesn't do any more work.
- The lock covers only the map and counter, never slow work. A lock held during slow work makes every other request wait.

Create the store's tests in `internal/memstore/store_test.go`. The one to study closely is `TestConcurrentCreateIDsAreUnique`:

<!-- file: internal/memstore/store_test.go -->
~~~go
package memstore

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"runway/internal/jobs"
)

func newJob(t *testing.T) jobs.Job {
	t.Helper()
	job, err := jobs.New("resize", 0, time.Now())
	if err != nil {
		t.Fatalf("jobs.New: %v", err)
	}
	return job
}

func TestCreateAssignsIDsAndGetReturnsJob(t *testing.T) {
	store := New()
	ctx := context.Background()

	first, _ := store.Create(ctx, newJob(t))
	second, _ := store.Create(ctx, newJob(t))
	if first.ID != 1 || second.ID != 2 {
		t.Fatalf("IDs = %d, %d, want 1, 2", first.ID, second.ID)
	}

	got, err := store.Get(ctx, second.ID)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got != second {
		t.Fatalf("Get = %+v, want %+v", got, second)
	}
}

func TestGetUnknownJob(t *testing.T) {
	if _, err := New().Get(context.Background(), 42); !errors.Is(err, jobs.ErrNotFound) {
		t.Fatalf("error = %v, want %v", err, jobs.ErrNotFound)
	}
}

func TestUpdateChecksExpectedState(t *testing.T) {
	store := New()
	ctx := context.Background()
	job, _ := store.Create(ctx, newJob(t))

	_ = job.Start(time.Now())
	if err := store.Update(ctx, job, jobs.StateQueued); err != nil {
		t.Fatalf("first Update: %v", err)
	}
	if err := store.Update(ctx, job, jobs.StateQueued); !errors.Is(err, jobs.ErrConflict) {
		t.Fatalf("stale Update error = %v, want %v", err, jobs.ErrConflict)
	}
	if err := store.Update(ctx, jobs.Job{ID: 99}, jobs.StateQueued); !errors.Is(err, jobs.ErrNotFound) {
		t.Fatalf("unknown Update error = %v, want %v", err, jobs.ErrNotFound)
	}
}

func TestCancelledContextIsRefused(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := New().Create(ctx, newJob(t)); !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v, want %v", err, context.Canceled)
	}
}

// Run with -race. Without the mutex, the race detector reports concurrent
// map writes here, and the IDs may repeat.
func TestConcurrentCreateIDsAreUnique(t *testing.T) {
	store := New()
	ctx := context.Background()
	const n = 200

	ids := make(chan jobs.ID, n)
	var wg sync.WaitGroup
	for range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			job, err := store.Create(ctx, newJob(t))
			if err != nil {
				t.Errorf("Create: %v", err)
				return
			}
			ids <- job.ID
		}()
	}
	wg.Wait()
	close(ids)

	seen := make(map[jobs.ID]bool)
	for id := range ids {
		if seen[id] {
			t.Fatalf("ID %d was assigned twice", id)
		}
		seen[id] = true
		if _, err := store.Get(ctx, id); err != nil {
			t.Fatalf("Get(%d): %v", id, err)
		}
	}
	if len(seen) != n {
		t.Fatalf("got %d IDs, want %d", len(seen), n)
	}
}
~~~

- `for range n` loops `n` times.
- `go func() { ... }()` starts an anonymous function as a goroutine. The final `()` calls it.
- A `sync.WaitGroup` counts running goroutines: `Add(1)` before starting each one, `Done()` when it finishes, and `Wait()` blocks until the count is zero.
- `ids := make(chan jobs.ID, n)` is a **channel**: a pipe goroutines use to pass values safely. Its buffer holds `n` values, so senders never block. `close(ids)` marks it finished, so the `for id := range ids` loop ends.
- In a goroutine, use `t.Errorf` (record the failure and continue), not `t.Fatalf`, which must only be called from the test's own goroutine.

**Run it**, with and without the **race detector**:

~~~bash
go test ./...
go test -race ./...
~~~

`-race` builds the program with instrumentation that watches every memory access at run time and reports any unsynchronised conflict. It makes tests slower, so it isn't the default, but CI always uses it.

**Break it: cause the race.** In `Create`, delete the two lines `s.mu.Lock()` and `defer s.mu.Unlock()`, then run `go test -race ./internal/memstore`:

~~~text
==================
WARNING: DATA RACE
Read at 0x00c0000c86d8 by goroutine 11:
  runway/internal/memstore.(*Store).Create()
      /.../internal/memstore/store.go:30 +0x94
  runway/internal/memstore.TestConcurrentCreateIDsAreUnique.func1()
      /.../internal/memstore/store_test.go:85 +0x1b8

Previous write at 0x00c0000c86d8 by goroutine 13:
  runway/internal/memstore.(*Store).Create()
      /.../internal/memstore/store.go:30 +0xaf
  ...
==================
~~~

How to read the report: one goroutine **read** memory at line 30 (`s.nextID++` reads the counter, adds one, and writes it back), while another goroutine had **written** the same address at the same line. `++` isn't one indivisible step: two goroutines can both read 4, both write 5, and two jobs get ID 5. Without `-race` the test may still pass on your machine, which is exactly why races are dangerous. Restore the lock and run again: clean.

**A race report is proof of a bug. A clean run is not proof there are none.** The detector only sees interleavings that actually happened during the run.

**Read.** Now that you've seen shared memory go wrong, read OSTEP Ch. 26–28 (*Concurrency: An Introduction*, *Thread API*, *Locks*), then Ch. 29, 30 and 32, and CSAPP §12.1 and §12.3–12.7. Carry this question in: what exactly does the lock make into "one step", and what does it leave outside?

**Explain it:** why does the `jobs` package define `Repository` instead of `memstore` defining it? Why store jobs by value rather than by pointer?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Step 3: The service, and a race a mutex can't fix

**The problem.** Something has to coordinate: validate input, create a job, run it, record the result. That's a **use case**, and it belongs neither in the domain (which doesn't do I/O) nor in HTTP handlers (which only translate). And running a job hides a race that the store's mutex does **not** prevent.

**New ideas.**

- A **service** holds the use cases and calls the domain and the repository.
- **Dependency injection (DI)** means a component receives its dependencies instead of creating them. `NewService(repo Repository, ...)` takes any repository. Tests pass one with a fixed clock, or one with an artificial delay. In Go, DI is just passing values to constructors; you don't need a framework.
- **Functional options** handle optional settings without a long parameter list. `Option` is a function that changes the `Service`; `WithClock(...)` returns one; `NewService` applies them after setting defaults. Adding a setting later doesn't change any existing caller.
- `WorkFunc` is a **function type**. The default work is `Simulate`, which waits for the job's duration. In Phase 2, real work arrives through a queue and nothing else changes.
- **`select`** waits on several channel operations and runs whichever is ready first. `Simulate` waits for either the timer to fire or the context to be cancelled.

Create `internal/jobs/service.go`:

<!-- file: internal/jobs/service.go -->
~~~go
package jobs

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// ErrWorkFailed wraps whatever stopped a job's work.
var ErrWorkFailed = errors.New("job work failed")

// WorkFunc does a job's actual work. It must stop when ctx is done.
type WorkFunc func(ctx context.Context, job Job) error

// Simulate is the default work: wait for the job's duration, or stop early
// if ctx is cancelled or its deadline passes.
func Simulate(ctx context.Context, job Job) error {
	timer := time.NewTimer(job.Duration)
	defer timer.Stop()

	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Service holds the use cases. Its dependencies are passed in, never
// created inside, so tests can replace them.
type Service struct {
	repo Repository
	now  func() time.Time
	work WorkFunc
}

// Option changes one setting of a Service.
type Option func(*Service)

// WithClock replaces the clock, for tests.
func WithClock(now func() time.Time) Option {
	return func(s *Service) { s.now = now }
}

// WithWork replaces the work function, for tests or real work.
func WithWork(work WorkFunc) Option {
	return func(s *Service) { s.work = work }
}

func NewService(repo Repository, opts ...Option) *Service {
	s := &Service{
		repo: repo,
		now:  func() time.Time { return time.Now().UTC() },
		work: Simulate,
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

func (s *Service) Create(ctx context.Context, description string, duration time.Duration) (Job, error) {
	d, err := NewDescription(description)
	if err != nil {
		return Job{}, err
	}
	job, err := New(d, duration, s.now())
	if err != nil {
		return Job{}, err
	}
	return s.repo.Create(ctx, job)
}

func (s *Service) Get(ctx context.Context, id ID) (Job, error) {
	return s.repo.Get(ctx, id)
}

// Run moves a queued job to running, does its work, and records the
// outcome. Two concurrent Run calls on one job can't both start it: the
// second Update sees that the state is no longer queued and gets ErrConflict.
func (s *Service) Run(ctx context.Context, id ID) (Job, error) {
	job, err := s.repo.Get(ctx, id)
	if err != nil {
		return Job{}, err
	}
	if err := job.Start(s.now()); err != nil {
		return job, err
	}
	if err := s.repo.Update(ctx, job, StateQueued); err != nil {
		return Job{}, err
	}

	workErr := s.work(ctx, job)
	if workErr != nil {
		_ = job.Fail(failureReason(workErr), s.now())
	} else {
		_ = job.Complete(s.now())
	}

	// Record the outcome even if ctx was cancelled: the work has already
	// happened or been abandoned, and the stored state must say which.
	if err := s.repo.Update(context.WithoutCancel(ctx), job, StateRunning); err != nil {
		return Job{}, err
	}
	if workErr != nil {
		return job, fmt.Errorf("%w: %w", ErrWorkFailed, workErr)
	}
	return job, nil
}

func failureReason(err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "deadline exceeded"
	case errors.Is(err, context.Canceled):
		return "cancelled"
	default:
		return err.Error()
	}
}
~~~

### The check-then-act race

Look at the first half of `Run`: **Get** the job, **check** it's queued (`job.Start`), then **Update** it. Each of those store calls holds the mutex. But between them, nothing does:

~~~mermaid
sequenceDiagram
    participant A as Request A
    participant S as Store
    participant B as Request B
    A->>S: Get(1) → queued
    B->>S: Get(1) → queued
    A->>A: Start() ok
    B->>B: Start() ok
    A->>S: Update(running)
    B->>S: Update(running)
    Note over A,B: Both run the job: the work happens twice
~~~

The mutex makes each **call** safe. It doesn't make the **sequence** of calls one step. This is called a **check-then-act** race, or a **lost update**. The fix is **compare-and-swap**: `Update(ctx, job, StateQueued)` means "store this only if the state is *still* queued". The store checks and writes under one lock, so the second request gets `ErrConflict`. This is also called **optimistic concurrency control**. Phase 3 does the same thing in SQL with `UPDATE ... WHERE state = $expected`.

Create `internal/jobs/service_test.go`. Study `slowGetRepository` and `TestConcurrentRunStartsJobOnce` closely:

<!-- file: internal/jobs/service_test.go -->
~~~go
package jobs_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"runway/internal/jobs"
	"runway/internal/memstore"
)

var fixedNow = time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)

func fixedClock() time.Time { return fixedNow }

func instantWork(context.Context, jobs.Job) error { return nil }

func TestCreateValidatesAndStores(t *testing.T) {
	svc := jobs.NewService(memstore.New(), jobs.WithClock(fixedClock))
	ctx := context.Background()

	job, err := svc.Create(ctx, "  resize  ", time.Second)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if job.ID == 0 || job.Description != "resize" || job.State != jobs.StateQueued || !job.CreatedAt.Equal(fixedNow) {
		t.Fatalf("job = %+v", job)
	}

	if _, err := svc.Create(ctx, "", 0); !errors.Is(err, jobs.ErrInvalidDescription) {
		t.Fatalf("empty description error = %v", err)
	}
	if _, err := svc.Create(ctx, "resize", time.Hour); !errors.Is(err, jobs.ErrInvalidDuration) {
		t.Fatalf("long duration error = %v", err)
	}
}

func TestRunCompletesJob(t *testing.T) {
	svc := jobs.NewService(memstore.New(), jobs.WithClock(fixedClock), jobs.WithWork(instantWork))
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)

	done, err := svc.Run(ctx, job.ID)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if done.State != jobs.StateCompleted {
		t.Fatalf("state = %s, want completed", done.State)
	}
	stored, _ := svc.Get(ctx, job.ID)
	if stored.State != jobs.StateCompleted {
		t.Fatalf("stored state = %s, want completed", stored.State)
	}
}

func TestRunTwiceIsRefused(t *testing.T) {
	svc := jobs.NewService(memstore.New(), jobs.WithWork(instantWork))
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)

	if _, err := svc.Run(ctx, job.ID); err != nil {
		t.Fatalf("first Run: %v", err)
	}
	if _, err := svc.Run(ctx, job.ID); !errors.Is(err, jobs.ErrInvalidTransition) {
		t.Fatalf("second Run error = %v, want %v", err, jobs.ErrInvalidTransition)
	}
}

func TestRunUnknownJob(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	if _, err := svc.Run(context.Background(), 7); !errors.Is(err, jobs.ErrNotFound) {
		t.Fatalf("error = %v, want %v", err, jobs.ErrNotFound)
	}
}

func TestRunRecordsDeadlineAsFailure(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	job, _ := svc.Create(context.Background(), "slow", 2*time.Second)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	failed, err := svc.Run(ctx, job.ID)
	if !errors.Is(err, jobs.ErrWorkFailed) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error = %v, want work failed by deadline", err)
	}
	if failed.State != jobs.StateFailed || failed.FailureReason != "deadline exceeded" {
		t.Fatalf("job = %+v, want failed by deadline", failed)
	}
	stored, _ := svc.Get(context.Background(), job.ID)
	if stored.State != jobs.StateFailed {
		t.Fatalf("stored state = %s, want failed even though ctx was cancelled", stored.State)
	}
}

// slowGetRepository wraps a real repository and pauses after every Get. That
// widens the gap between Run's Get and its Update, so a race that would
// otherwise happen once in a thousand runs happens every time.
type slowGetRepository struct {
	jobs.Repository
}

func (r slowGetRepository) Get(ctx context.Context, id jobs.ID) (jobs.Job, error) {
	job, err := r.Repository.Get(ctx, id)
	time.Sleep(5 * time.Millisecond)
	return job, err
}

// The store's mutex protects the map, but Get-then-Update is two separate
// operations. Only the compare-and-swap in Update makes Run safe when two
// requests race for the same job.
func TestConcurrentRunStartsJobOnce(t *testing.T) {
	var mu sync.Mutex
	runs := 0
	countingWork := func(context.Context, jobs.Job) error {
		mu.Lock()
		runs++
		mu.Unlock()
		time.Sleep(10 * time.Millisecond)
		return nil
	}
	svc := jobs.NewService(slowGetRepository{memstore.New()}, jobs.WithWork(countingWork))
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)

	const callers = 20
	errs := make(chan error, callers)
	var wg sync.WaitGroup
	for range callers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := svc.Run(ctx, job.ID)
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)

	succeeded := 0
	for err := range errs {
		switch {
		case err == nil:
			succeeded++
		case errors.Is(err, jobs.ErrConflict), errors.Is(err, jobs.ErrInvalidTransition):
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	if succeeded != 1 || runs != 1 {
		t.Fatalf("succeeded = %d, work ran %d times; want 1 and 1", succeeded, runs)
	}
}
~~~

`slowGetRepository` **embeds** `jobs.Repository`: it gets all of that interface's methods for free and overrides only `Get`. This is the decorator pattern, and it's only possible because the service depends on the interface. Dependency injection isn't a ceremony; it's what lets this test exist.

The service test file uses `package jobs_test`, a separate **external test package**. It can only use what `jobs` exports, exactly as other packages do. It can also import `memstore` without an import cycle.

**Break it: remove the compare-and-swap.** In `memstore`'s `Update`, delete the `if current.State != expected { ... }` block (and change `current, ok` to `_, ok`), then run `go test ./internal/jobs`:

~~~text
--- FAIL: TestConcurrentRunStartsJobOnce (0.02s)
    service_test.go:153: succeeded = 20, work ran 20 times; want 1 and 1
FAIL
~~~

Twenty requests all ran the same job. **`go test -race` passes in this broken version**, because every map access is still locked. The race detector finds *data* races (unsynchronised memory access). This is a *logic* race, and only a test that checks the outcome can catch it. Restore the check.

Without the slow repository the test usually passes even with the bug: the window is microseconds wide. Races that rarely happen in tests happen constantly in production, where there are thousands of requests a second.

### Keeping the record honest after a cancellation

`Run`'s last `Update` uses `context.WithoutCancel(ctx)`: a context that keeps the request's values but is **never** cancelled. Why? Look again at this test from the file you just typed:

~~~go
func TestRunRecordsDeadlineAsFailure(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	job, _ := svc.Create(context.Background(), "slow", 2*time.Second)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	failed, err := svc.Run(ctx, job.ID)
	if !errors.Is(err, jobs.ErrWorkFailed) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("error = %v, want work failed by deadline", err)
	}
	if failed.State != jobs.StateFailed || failed.FailureReason != "deadline exceeded" {
		t.Fatalf("job = %+v, want failed by deadline", failed)
	}
	stored, _ := svc.Get(context.Background(), job.ID)
	if stored.State != jobs.StateFailed {
		t.Fatalf("stored state = %s, want failed even though ctx was cancelled", stored.State)
	}
}
~~~

**Break it.** Change `context.WithoutCancel(ctx)` to plain `ctx` and run this test:

~~~text
--- FAIL: TestRunRecordsDeadlineAsFailure (0.02s)
    service_test.go:87: error = context deadline exceeded, want work failed by deadline
~~~

The deadline stopped the work, which is right. But the same expired context also made the store refuse the final write, so the job is **stuck in `running` forever**. Nothing will ever retry it, and nothing reports it. Cancellation should stop *work*; it shouldn't stop you writing down what happened. Restore it.

`fmt.Errorf("%w: %w", ErrWorkFailed, workErr)` wraps **two** errors, so `errors.Is` finds either: callers can check "did the work fail?" and "was it a deadline?" separately.

**Explain it:** draw the check-then-act race. Why doesn't the mutex prevent it? Why doesn't `-race` detect it? What does `WithoutCancel` protect against?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Step 4: The HTTP API

**The problem.** Callers speak HTTP and JSON. The handlers must turn requests into service calls and results into precise status codes, and they must reject malformed input *before* it reaches the service. They must not contain business rules.

**New ideas.**

- Since Go 1.22, a route pattern can include the **method** and **wildcards**: `GET /jobs/{id}`. `r.PathValue("id")` reads the wildcard. If the path matches but the method doesn't, the router answers `405` with an `Allow` header itself. In Phase 0 you wrote that check by hand.
- The handler package defines the interface it **consumes**, `JobService`, with only the three methods it calls. Go's rule of thumb: *accept interfaces, return concrete types.* The service doesn't need to know this interface exists.
- **Strict decoding** treats every request body as hostile:
  - `http.MaxBytesReader` stops reading after 1 KiB, so a 1 GB body can't exhaust memory.
  - `DisallowUnknownFields` rejects fields the contract doesn't have. Otherwise a typo like `"descripton"` is silently ignored, and the caller thinks it worked.
  - Decoding a **second** value and requiring `io.EOF` (end of input) rejects `{"a":1}{"b":2}`.
  - The `Content-Type` check means the caller has to say it's sending JSON.
- **Error mapping:** the domain returns errors, the handler chooses status codes. A `400` means "you sent something wrong", a `409` means "you sent something valid, but the current state doesn't allow it", and a `500` means "we broke". Unknown errors get a generic message. Internal details go to the log, never to the caller.
- `errors.As(err, &target)` checks whether an error, or anything it wraps, is of a given **type**, and fills in `target`. Use it when you need fields from the error, such as `typeErr.Field`.

Create `internal/httpapi/json.go`:

<!-- file: internal/httpapi/json.go -->
~~~go
package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strings"
)

const maxBodyBytes = 1 << 10 // 1 KiB

// requestError is a client mistake: it carries the status and a message
// that is safe to show the caller.
type requestError struct {
	status  int
	message string
}

func (e *requestError) Error() string { return e.message }

// decodeJSON reads exactly one JSON object into dst, refusing anything else:
// the wrong content type, an oversized body, unknown fields, or trailing data.
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	mediaType, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if mediaType != "application/json" {
		return &requestError{http.StatusUnsupportedMediaType, "Content-Type must be application/json"}
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(dst); err != nil {
		return describeDecodeError(err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return &requestError{http.StatusBadRequest, "request body must contain a single JSON object"}
	}
	return nil
}

func describeDecodeError(err error) error {
	var syntaxErr *json.SyntaxError
	var typeErr *json.UnmarshalTypeError
	var tooLarge *http.MaxBytesError

	switch {
	case errors.Is(err, io.EOF):
		return &requestError{http.StatusBadRequest, "request body is empty"}
	case errors.As(err, &syntaxErr), errors.Is(err, io.ErrUnexpectedEOF):
		return &requestError{http.StatusBadRequest, "request body is not valid JSON"}
	case errors.As(err, &typeErr):
		return &requestError{http.StatusBadRequest, fmt.Sprintf("field %q has the wrong type", typeErr.Field)}
	case strings.HasPrefix(err.Error(), "json: unknown field "):
		field := strings.TrimPrefix(err.Error(), "json: unknown field ")
		return &requestError{http.StatusBadRequest, "unknown field " + field}
	case errors.As(err, &tooLarge):
		return &requestError{http.StatusRequestEntityTooLarge, fmt.Sprintf("request body must not exceed %d bytes", maxBodyBytes)}
	default:
		return &requestError{http.StatusBadRequest, "request body could not be read"}
	}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Warn("write response", "error", err)
	}
}

type errorResponse struct {
	Error string `json:"error"`
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, errorResponse{Error: message})
}
~~~

`requestError` has an `Error() string` method, so it satisfies Go's built-in `error` interface. A custom error type carries extra data (the status) that a plain string error can't. `any` means "a value of any type".

Create `internal/httpapi/handler.go`:

<!-- file: internal/httpapi/handler.go -->
~~~go
// Package httpapi translates HTTP to and from the jobs use cases. It owns
// status codes, JSON shapes and request limits, and holds no business rules.
package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"runway/internal/jobs"
)

// JobService is what the handlers need. It is defined here, where it is
// used, so tests could pass any implementation.
type JobService interface {
	Create(ctx context.Context, description string, duration time.Duration) (jobs.Job, error)
	Get(ctx context.Context, id jobs.ID) (jobs.Job, error)
	Run(ctx context.Context, id jobs.ID) (jobs.Job, error)
}

type handlers struct {
	jobs JobService
}

// NewHandler builds the routes. Each pattern names a method and a path, so
// the router itself answers 405 for a known path with the wrong method.
func NewHandler(service JobService) http.Handler {
	h := &handlers{jobs: service}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", h.health)
	mux.HandleFunc("POST /jobs", h.createJob)
	mux.HandleFunc("GET /jobs/{id}", h.getJob)
	mux.HandleFunc("POST /jobs/{id}/run", h.runJob)
	return mux
}

type healthResponse struct {
	Status string `json:"status"`
}

func (h *handlers) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, healthResponse{Status: "ok"})
}

type createJobRequest struct {
	Description string `json:"description"`
	DurationMS  int64  `json:"duration_ms"`
}

type jobResponse struct {
	ID            jobs.ID   `json:"id"`
	State         string    `json:"state"`
	Description   string    `json:"description"`
	DurationMS    int64     `json:"duration_ms"`
	FailureReason string    `json:"failure_reason,omitempty"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

func toResponse(job jobs.Job) jobResponse {
	return jobResponse{
		ID:            job.ID,
		State:         string(job.State),
		Description:   string(job.Description),
		DurationMS:    job.Duration.Milliseconds(),
		FailureReason: job.FailureReason,
		CreatedAt:     job.CreatedAt,
		UpdatedAt:     job.UpdatedAt,
	}
}

func (h *handlers) createJob(w http.ResponseWriter, r *http.Request) {
	var req createJobRequest
	if err := decodeJSON(w, r, &req); err != nil {
		h.writeRequestError(w, err)
		return
	}

	job, err := h.jobs.Create(r.Context(), req.Description, time.Duration(req.DurationMS)*time.Millisecond)
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
	w.Header().Set("Location", "/jobs/"+strconv.FormatInt(int64(job.ID), 10))
	writeJSON(w, http.StatusCreated, toResponse(job))
}

func (h *handlers) getJob(w http.ResponseWriter, r *http.Request) {
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	job, err := h.jobs.Get(r.Context(), id)
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toResponse(job))
}

func (h *handlers) runJob(w http.ResponseWriter, r *http.Request) {
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	job, err := h.jobs.Run(r.Context(), id)
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toResponse(job))
}

func parseID(w http.ResponseWriter, r *http.Request) (jobs.ID, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeError(w, http.StatusBadRequest, "job id must be a positive integer")
		return 0, false
	}
	return jobs.ID(id), true
}

func (h *handlers) writeRequestError(w http.ResponseWriter, err error) {
	var reqErr *requestError
	if errors.As(err, &reqErr) {
		writeError(w, reqErr.status, reqErr.message)
		return
	}
	writeError(w, http.StatusBadRequest, "bad request")
}

// writeDomainError maps domain errors to HTTP statuses. Unknown errors become
// a 500 with a generic message: internal details are logged, never sent.
func (h *handlers) writeDomainError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, jobs.ErrInvalidDescription), errors.Is(err, jobs.ErrInvalidDuration):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, jobs.ErrNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, jobs.ErrInvalidTransition), errors.Is(err, jobs.ErrConflict):
		writeError(w, http.StatusConflict, err.Error())
	default:
		slog.Error("unexpected error", "method", r.Method, "path", r.URL.Path, "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
	}
}
~~~

Things to notice:

- `jobResponse` is a separate type from `jobs.Job`. The JSON shape is part of the **HTTP contract**, and the domain type must be free to change without breaking callers. `toResponse` is the translation.
- `omitempty` drops `failure_reason` from the JSON when it's empty.
- `201 Created` plus a `Location` header is the HTTP convention for "I made a new resource, and here's where it lives".
- Every handler follows the same shape: parse, call one service method, map the result, write once, return.

Create `cmd/api/main.go` so you can run it:

<!-- file: cmd/api/main.go -->
~~~go
// Command api runs the Runway jobs service.
package main

import (
	"log"
	"net/http"

	"runway/internal/httpapi"
	"runway/internal/jobs"
	"runway/internal/memstore"
)

func main() {
	store := memstore.New()
	service := jobs.NewService(store)
	handler := httpapi.NewHandler(service)

	log.Println("listening on http://127.0.0.1:8080")
	log.Fatal(http.ListenAndServe("127.0.0.1:8080", handler))
}
~~~

Create `internal/httpapi/handler_test.go`. The table test for bad requests, `TestCreateRejectsBadRequests`, matters most: each row is one line of the contract.

<!-- file: internal/httpapi/handler_test.go -->
~~~go
package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"runway/internal/jobs"
	"runway/internal/memstore"
)

func newTestHandler() http.Handler {
	return NewHandler(jobs.NewService(memstore.New()))
}

func do(t *testing.T, h http.Handler, method, target, body string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, target, strings.NewReader(body))
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	response := httptest.NewRecorder()
	h.ServeHTTP(response, request)
	return response
}

func decode(t *testing.T, r *httptest.ResponseRecorder) jobResponse {
	t.Helper()
	var job jobResponse
	if err := json.Unmarshal(r.Body.Bytes(), &job); err != nil {
		t.Fatalf("decode %q: %v", r.Body.String(), err)
	}
	return job
}

func TestHealth(t *testing.T) {
	response := do(t, newTestHandler(), http.MethodGet, "/health", "")
	if response.Code != http.StatusOK || response.Body.String() != "{\"status\":\"ok\"}\n" {
		t.Fatalf("got %d %q", response.Code, response.Body.String())
	}
}

func TestCreateThenGet(t *testing.T) {
	h := newTestHandler()

	created := do(t, h, http.MethodPost, "/jobs", `{"description":"resize","duration_ms":50}`)
	if created.Code != http.StatusCreated {
		t.Fatalf("POST status = %d, body %s", created.Code, created.Body)
	}
	job := decode(t, created)
	if job.ID != 1 || job.State != "queued" || job.DurationMS != 50 {
		t.Fatalf("created = %+v", job)
	}
	if got := created.Header().Get("Location"); got != "/jobs/1" {
		t.Fatalf("Location = %q, want /jobs/1", got)
	}

	fetched := do(t, h, http.MethodGet, "/jobs/1", "")
	if fetched.Code != http.StatusOK || decode(t, fetched).Description != "resize" {
		t.Fatalf("GET = %d %s", fetched.Code, fetched.Body)
	}
}

func TestCreateRejectsBadRequests(t *testing.T) {
	tests := []struct {
		name        string
		contentType string
		body        string
		wantStatus  int
		wantError   string
	}{
		{"wrong content type", "text/plain", `{"description":"x"}`, http.StatusUnsupportedMediaType, "Content-Type must be application/json"},
		{"empty body", "application/json", ``, http.StatusBadRequest, "request body is empty"},
		{"malformed JSON", "application/json", `{"description":`, http.StatusBadRequest, "request body is not valid JSON"},
		{"wrong type", "application/json", `{"description":42}`, http.StatusBadRequest, `field "description" has the wrong type`},
		{"unknown field", "application/json", `{"description":"x","priority":1}`, http.StatusBadRequest, `unknown field "priority"`},
		{"two objects", "application/json", `{"description":"x"}{"description":"y"}`, http.StatusBadRequest, "request body must contain a single JSON object"},
		{"missing description", "application/json", `{}`, http.StatusBadRequest, jobs.ErrInvalidDescription.Error()},
		{"duration too long", "application/json", `{"description":"x","duration_ms":60000}`, http.StatusBadRequest, jobs.ErrInvalidDuration.Error()},
		{"oversized body", "application/json", `{"description":"` + strings.Repeat("a", 2000) + `"}`, http.StatusRequestEntityTooLarge, "request body must not exceed 1024 bytes"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(tt.body))
			request.Header.Set("Content-Type", tt.contentType)
			response := httptest.NewRecorder()
			newTestHandler().ServeHTTP(response, request)

			if response.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d (body %s)", response.Code, tt.wantStatus, response.Body)
			}
			var got errorResponse
			_ = json.Unmarshal(response.Body.Bytes(), &got)
			if got.Error != tt.wantError {
				t.Fatalf("error = %q, want %q", got.Error, tt.wantError)
			}
		})
	}
}

func TestGetErrors(t *testing.T) {
	h := newTestHandler()
	tests := []struct {
		target string
		want   int
	}{
		{"/jobs/99", http.StatusNotFound},
		{"/jobs/abc", http.StatusBadRequest},
		{"/jobs/0", http.StatusBadRequest},
		{"/jobs/-3", http.StatusBadRequest},
	}
	for _, tt := range tests {
		if got := do(t, h, http.MethodGet, tt.target, "").Code; got != tt.want {
			t.Errorf("GET %s = %d, want %d", tt.target, got, tt.want)
		}
	}
}

func TestRouterRejectsWrongMethod(t *testing.T) {
	response := do(t, newTestHandler(), http.MethodDelete, "/jobs/1", "")
	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", response.Code)
	}
	if allow := response.Header().Get("Allow"); !strings.Contains(allow, "GET") {
		t.Fatalf("Allow = %q, want it to list GET", allow)
	}
}

func TestRunCompletesThenConflicts(t *testing.T) {
	h := newTestHandler()
	do(t, h, http.MethodPost, "/jobs", `{"description":"resize","duration_ms":10}`)

	first := do(t, h, http.MethodPost, "/jobs/1/run", "")
	if first.Code != http.StatusOK || decode(t, first).State != "completed" {
		t.Fatalf("first run = %d %s", first.Code, first.Body)
	}
	second := do(t, h, http.MethodPost, "/jobs/1/run", "")
	if second.Code != http.StatusConflict {
		t.Fatalf("second run = %d, want 409", second.Code)
	}
}
~~~

**Run it.** Run `go run ./cmd/api` (the path names the package that has `main`). Then, in a second terminal:

~~~bash
curl -i -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"resize images","duration_ms":300}'
~~~

~~~text
HTTP/1.1 201 Created
Content-Type: application/json
Location: /jobs/1
Content-Length: 166

{"id":1,"state":"queued","description":"resize images","duration_ms":300,"created_at":"2026-10-04T18:28:38.150054508Z","updated_at":"2026-10-04T18:28:38.150054508Z"}
~~~

Then run it, twice:

~~~bash
curl -i -X POST http://127.0.0.1:8080/jobs/1/run
curl -i -X POST http://127.0.0.1:8080/jobs/1/run
~~~

The first takes about 300 ms and returns `200` with `"state":"completed"`. The second returns at once:

~~~text
HTTP/1.1 409 Conflict
{"error":"invalid state transition: completed to running"}
~~~

Now the error paths. Predict each status before running it:

| Command | Status | Body |
|---|---|---|
| `curl -i -X POST .../jobs -H 'Content-Type: application/json' -d '{}'` | 400 | `{"error":"description must be between 1 and 200 characters"}` |
| `... -d '{"description":"x","priority":1}'` | 400 | `{"error":"unknown field \"priority\""}` |
| `curl -i -X POST .../jobs -d '{"description":"x"}'` (no `-H`) | 415 | `{"error":"Content-Type must be application/json"}` |
| a 2,000-character description | 413 | `{"error":"request body must not exceed 1024 bytes"}` |
| `curl -i .../jobs/99` | 404 | `{"error":"job not found"}` |
| `curl -i .../jobs/abc` | 400 | `{"error":"job id must be a positive integer"}` |
| `curl -i -X DELETE .../jobs/1` | 405 | `Allow: GET, HEAD`, plain-text body `Method Not Allowed` |

Three things to learn from these:

- The 415 happens because `curl -d` sends `Content-Type: application/x-www-form-urlencoded` unless you say otherwise.
- The router added `HEAD` to `Allow` by itself: a `GET` pattern also serves `HEAD`.
- The router's own 404 and 405 bodies are plain text, not JSON. Exercise 2 asks you to fix that.

Now stop the server and start it again, then `curl -i http://127.0.0.1:8080/jobs/1`: **404**. The job lived in the old process's memory, and that process is gone. This is by design for Phase 1. Phase 3 makes jobs survive restarts.

**Break it.** Delete `decoder.DisallowUnknownFields()` and send `{"description":"x","priority":1}`. You get `201 Created`. The caller believes they set a priority; the service silently threw it away. Restore it.

**Explain it:** why does `httpapi` define `JobService` rather than using `*jobs.Service` directly? What's the difference between 400, 409 and 500 in this API?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Step 5: The composition root and configuration

**The problem.** `main` hard-codes the address, and `http.ListenAndServe` has **no timeouts**. A client can open a connection and send one header byte per minute, tying up resources forever. Doing that with thousands of connections at once is the "Slowloris" attack. And none of `main` can be tested.

**New ideas.**

- The **composition root** is the one place where concrete types are created and wired together. Everything below it receives its dependencies. If you want to know what the program is made of, read `main`.
- **Configuration from the environment.** An **environment variable** is a named string the operating system gives a process when it starts: `LISTEN_ADDR=0.0.0.0:9000 go run ./cmd/api`. The same build then runs on a laptop, in a container, or in Kubernetes, with only the environment changing. This is one of the "twelve-factor app" rules.
- `run(getenv func(string) string)` takes the environment **as a function**. In production you pass `os.Getenv`; in tests you pass a function backed by a map. No global state is read, so it's testable.
- An `http.Server` with explicit **timeouts**:
  - `ReadHeaderTimeout` limits how long a client may take to send its headers (this defeats Slowloris);
  - `ReadTimeout` and `WriteTimeout` bound the whole request and response;
  - `IdleTimeout` closes kept-alive connections nobody is using.

<!-- file: cmd/api/main.go -->
~~~go
// Command api runs the Runway jobs service.
//
// main is the composition root: the one place that builds every concrete
// dependency and wires them together. Nothing below it creates its own.
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"runway/internal/httpapi"
	"runway/internal/jobs"
	"runway/internal/memstore"
)

func main() {
	if err := run(os.Getenv); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type config struct {
	ListenAddr string
}

func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{
		ListenAddr: "127.0.0.1:8080",
	}
	if v := getenv("LISTEN_ADDR"); v != "" {
		if _, _, err := net.SplitHostPort(v); err != nil {
			return config{}, fmt.Errorf("LISTEN_ADDR must look like host:port, got %q", v)
		}
		cfg.ListenAddr = v
	}
	return cfg, nil
}

// run builds the service from its configuration and serves it. Taking the
// environment as a parameter instead of calling os.Getenv inside is what
// makes it testable.
func run(getenv func(string) string) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}

	service := jobs.NewService(memstore.New())
	handler := httpapi.NewHandler(service)

	server := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("listening on http://%s", cfg.ListenAddr)
	return server.ListenAndServe()
}
~~~

`fmt.Fprintln(os.Stderr, err)` writes to **standard error**, the stream for problems. Standard output is for normal output. `os.Exit(1)` ends the process with a **non-zero exit status**, which tells the shell, CI or Kubernetes that it failed.


Create `cmd/api/main_test.go`:

<!-- file: cmd/api/main_test.go -->
~~~go
package main

import "testing"

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestLoadConfig(t *testing.T) {
	cfg, err := loadConfig(env(nil))
	if err != nil || cfg.ListenAddr != "127.0.0.1:8080" {
		t.Fatalf("defaults = %+v, %v", cfg, err)
	}

	cfg, err = loadConfig(env(map[string]string{"LISTEN_ADDR": "0.0.0.0:9000"}))
	if err != nil || cfg.ListenAddr != "0.0.0.0:9000" {
		t.Fatalf("override = %+v, %v", cfg, err)
	}

	if _, err := loadConfig(env(map[string]string{"LISTEN_ADDR": "8080"})); err == nil {
		t.Error("LISTEN_ADDR without a host:port form was accepted")
	}
}
~~~

**Run it.**

~~~bash
LISTEN_ADDR=127.0.0.1:9090 go run ./cmd/api
~~~

It listens on 9090. `VAR=value command` sets the variable for that one command only.

**Break it.** Run `LISTEN_ADDR=8080 go run ./cmd/api`:

~~~text
LISTEN_ADDR must look like host:port, got "8080"
exit status 1
~~~

The service refused to start with bad configuration. **Fail fast** at startup is far better than half-working until the first request.

**Explain it:** what is the composition root, and why does only `main` create concrete types? What does `ReadHeaderTimeout` defend against?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Step 6: Deadlines and cancellation

**The problem.** Run a job with `duration_ms: 5000` and the request takes five seconds. If the work hung forever, so would the request, holding a goroutine, memory and a connection the whole time. Every request needs an upper bound, and when the caller gives up, the work should stop too.

**New ideas.**

- A **deadline** is a point in time after which the work is pointless. `context.WithTimeout(parent, d)` returns a child context that is cancelled when `d` passes **or** when the parent is cancelled, whichever comes first.
- Contexts form a **tree**. Cancelling a parent cancels every descendant. The HTTP server cancels `r.Context()` when the client disconnects. The middleware adds a deadline below that, and `Simulate`'s `select` watches `ctx.Done()`. So one signal reaches the bottom of the call stack.

  ~~~mermaid
  flowchart TD
      A["r.Context()<br/>cancelled if the client disconnects"] --> B["withTimeout: WithTimeout 2s<br/>cancelled at the deadline"]
      B --> C["Service.Run(ctx)"]
      C --> D["Simulate: select on ctx.Done()"]
  ~~~

- **Middleware** is a function that takes a handler and returns a new handler that does something before or after the original. It's the **decorator pattern** again, this time for HTTP.
- **504 Gateway Timeout** tells the caller "this took too long on our side", which is different from a client-side timeout.

Create `internal/httpapi/middleware.go`:

<!-- file: internal/httpapi/middleware.go -->
~~~go
package httpapi

import (
	"context"
	"net/http"
	"time"
)

// withTimeout gives every request a deadline. Handlers pass r.Context() down,
// so the work below them stops when the deadline passes.
func withTimeout(d time.Duration, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), d)
		defer cancel()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
~~~

`defer cancel()` releases the timer the context holds, even if the request finishes early. Always call the `cancel` you're given; `go vet` warns if you don't. `http.HandlerFunc(...)` turns an ordinary function into an `http.Handler`.

In `handler.go`, `NewHandler` gains functional options, the same pattern as the service.

Make these changes to `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
// NewHandler builds the routes. Each pattern names a method and a path, so
// the router itself answers 405 for a known path with the wrong method.
func NewHandler(service JobService) http.Handler {
~~~

to:

~~~go
type config struct {
	requestTimeout time.Duration
}

// Option configures the handler built by NewHandler.
type Option func(*config)

// WithRequestTimeout bounds how long any one request may run.
func WithRequestTimeout(d time.Duration) Option {
	return func(c *config) { c.requestTimeout = d }
}

// NewHandler builds the routes and gives every request a deadline.
func NewHandler(service JobService, opts ...Option) http.Handler {
	cfg := config{requestTimeout: 2 * time.Second}
	for _, opt := range opts {
		opt(&cfg)
	}

~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	return mux
~~~

to:

~~~go
	return withTimeout(cfg.requestTimeout, mux)
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	job, err := h.jobs.Run(r.Context(), id)
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toResponse(job))
}

func parseID(w http.ResponseWriter, r *http.Request) (jobs.ID, bool) {
~~~

to:

~~~go
	job, err := h.jobs.Run(r.Context(), id)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, toResponse(job))
	case errors.Is(err, context.DeadlineExceeded):
		writeJSON(w, http.StatusGatewayTimeout, toResponse(job))
	case errors.Is(err, context.Canceled):
		// The client hung up. There is nobody left to answer.
	default:
		h.writeDomainError(w, r, err)
	}
}

func parseID(w http.ResponseWriter, r *http.Request) (jobs.ID, bool) {
~~~


The last change makes `runJob` tell deadline, cancellation and domain errors apart.

`main.go` reads `REQUEST_TIMEOUT` (default `2s`) with a small helper, `durationFromEnv`, and passes `httpapi.WithRequestTimeout(cfg.RequestTimeout)`. The server's `WriteTimeout` becomes the request timeout plus five seconds, so the server never cuts off a response the handler is still allowed to write. Those `main.go` changes follow.



Make these changes to `internal/httpapi/handler_test.go`:

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	"testing"

~~~

to:

~~~go
	"testing"
	"time"

~~~

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
func newTestHandler() http.Handler {
	return NewHandler(jobs.NewService(memstore.New()))
~~~

to:

~~~go
func newTestHandler(opts ...Option) http.Handler {
	return NewHandler(jobs.NewService(memstore.New()), opts...)
~~~

Add this at the end of the file:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
func TestRunPastDeadlineReturns504AndFailsJob(t *testing.T) {
	h := newTestHandler(WithRequestTimeout(50 * time.Millisecond))
	do(t, h, http.MethodPost, "/jobs", `{"description":"slow","duration_ms":2000}`)

	start := time.Now()
	response := do(t, h, http.MethodPost, "/jobs/1/run", "")
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("run took %v; the deadline should have stopped it near 50ms", elapsed)
	}
	if response.Code != http.StatusGatewayTimeout {
		t.Fatalf("status = %d, want 504", response.Code)
	}
	if job := decode(t, response); job.State != "failed" || job.FailureReason != "deadline exceeded" {
		t.Fatalf("job = %+v", job)
	}
	if job := decode(t, do(t, h, http.MethodGet, "/jobs/1", "")); job.State != "failed" {
		t.Fatalf("stored state = %s, want failed", job.State)
	}
}
~~~




Make these changes to `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	ListenAddr string
~~~

to:

~~~go
	ListenAddr     string
	RequestTimeout time.Duration
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		ListenAddr: "127.0.0.1:8080",
~~~

to:

~~~go
		ListenAddr:     "127.0.0.1:8080",
		RequestTimeout: 2 * time.Second,
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	}
	return cfg, nil
}
~~~

to:

~~~go
	}
	var err error
	if cfg.RequestTimeout, err = durationFromEnv(getenv, "REQUEST_TIMEOUT", cfg.RequestTimeout); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func durationFromEnv(getenv func(string) string, name string, fallback time.Duration) (time.Duration, error) {
	v := getenv(name)
	if v == "" {
		return fallback, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration such as 2s, got %q", name, v)
	}
	return d, nil
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	handler := httpapi.NewHandler(service)
~~~

to:

~~~go
	handler := httpapi.NewHandler(service, httpapi.WithRequestTimeout(cfg.RequestTimeout))
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		WriteTimeout:      15 * time.Second,
~~~

to:

~~~go
		WriteTimeout:      cfg.RequestTimeout + 5*time.Second,
~~~




Make these changes to `cmd/api/main_test.go`:

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go
import "testing"
~~~

to:

~~~go
import (
	"testing"
	"time"
)
~~~

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go
	if err != nil || cfg.ListenAddr != "127.0.0.1:8080" {
~~~

to:

~~~go
	if err != nil || cfg.ListenAddr != "127.0.0.1:8080" || cfg.RequestTimeout != 2*time.Second {
~~~

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go
	cfg, err = loadConfig(env(map[string]string{"LISTEN_ADDR": "0.0.0.0:9000"}))
	if err != nil || cfg.ListenAddr != "0.0.0.0:9000" {
		t.Fatalf("override = %+v, %v", cfg, err)
~~~

to:

~~~go
	cfg, err = loadConfig(env(map[string]string{"LISTEN_ADDR": "0.0.0.0:9000", "REQUEST_TIMEOUT": "500ms"}))
	if err != nil || cfg.ListenAddr != "0.0.0.0:9000" || cfg.RequestTimeout != 500*time.Millisecond {
		t.Fatalf("overrides = %+v, %v", cfg, err)
~~~

Change:

<!-- edit: cmd/api/main_test.go -->
~~~go
	}
}
~~~

to:

~~~go
	}
	for _, bad := range []string{"soon", "-1s", "0s"} {
		if _, err := loadConfig(env(map[string]string{"REQUEST_TIMEOUT": bad})); err == nil {
			t.Errorf("REQUEST_TIMEOUT=%q was accepted", bad)
		}
	}
}
~~~


**Run it.** Start the server with a 1-second deadline: `REQUEST_TIMEOUT=1s go run ./cmd/api`. Then:

~~~bash
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"slow","duration_ms":3000}'
curl -i -X POST http://127.0.0.1:8080/jobs/1/run
~~~

After about one second:

~~~text
HTTP/1.1 504 Gateway Timeout
{"id":1,"state":"failed","description":"slow","duration_ms":3000,"failure_reason":"deadline exceeded",...}
~~~

The work was stopped at the deadline, and the job is recorded as failed, thanks to step 3's `WithoutCancel`.

**Now let the client give up first.** Create another 1.5-second job (it gets ID 2), then:

~~~bash
curl -s --max-time 0.5 -X POST http://127.0.0.1:8080/jobs/2/run; echo "curl exit=$?"
curl -s http://127.0.0.1:8080/jobs/2
~~~

~~~text
curl exit=28
{"id":2,"state":"failed",...,"failure_reason":"cancelled",...}
~~~

Exit code 28 is curl's "operation timed out". When curl hung up, the server noticed, cancelled `r.Context()`, the work stopped at about 0.5 s, and the job was recorded as `cancelled`. A client-side timeout on its own proves nothing about the server. The stored job state is the evidence that the server stopped too.

**Break it.** In `Simulate`, replace the `select` with `time.Sleep(job.Duration); return nil`. Rerun the 3-second job with `REQUEST_TIMEOUT=1s`. The response now takes the full three seconds and returns `200 completed`. Work that doesn't watch `ctx.Done()` can't be cancelled, whatever deadline you set above it.

**Explain it:** trace a client disconnect from the socket down to `Simulate`. What's the difference between the 504 case and the client-timeout case, from the server's point of view?

**Read.** *Understanding Distributed Systems* (Vitillo), Part IV, the chapters on downstream resiliency and timeouts. Carry this question in: how do you choose a deadline, and what happens to a caller's caller when you exceed it?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Step 7: Logs, metrics and panic recovery

**The problem.** When something goes wrong in production, you can't attach a debugger. You need **logs**, which say what happened to individual requests, and **metrics**, which say how the service is doing overall. And a single bug that panics shouldn't drop the connection without a response or a trace.

**New ideas.**

- A **structured log** is one record per event, as key-value pairs, often JSON. Machines can filter it (`status >= 500`, `route = "POST /jobs/{id}/run"`) without guessing at text. Go's standard `log/slog` writes them.
- **What not to log:** request bodies, descriptions, tokens, names. Logs are copied to many places and kept for a long time, and Phase 6 treats them as sensitive data. Log the *shape* of a request (method, route, status, duration), not its content.
- A **metric** is a number tracked over time:
  - a **counter** only goes up (requests served);
  - a **histogram** sorts observations into buckets (how many requests took under 5 ms, under 10 ms, ...), so you can compute percentiles later.
- **Labels** split a metric: `route`, `method`, `code`. Use the **route pattern** `GET /jobs/{id}`, never the raw path `/jobs/1`, `/jobs/2`, and so on. Every distinct label value is a separate time series, so raw paths would create millions of them (a **cardinality** explosion).
- These are the **golden signals** from Google's SRE book: **latency, traffic, errors and saturation**. The histogram gives latency, the counter gives traffic, and errors are counts where `code` is 5xx. Saturation arrives with queues in Phase 2.
- **Prometheus** scrapes `GET /metrics` on a timer and stores the series. Phase 5 runs Prometheus itself, so for now you just read the endpoint.
- A **panic** is Go's crash for "impossible" situations. `recover()` inside a deferred function stops it from unwinding further. Recovery middleware turns a panic into a logged 500.

The finished `internal/httpapi/middleware.go`:

<!-- file: internal/httpapi/middleware.go -->
~~~go
package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"time"
)

// withTimeout gives every request a deadline. Handlers pass r.Context() down,
// so the work below them stops when the deadline passes.
func withTimeout(d time.Duration, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), d)
		defer cancel()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// statusRecorder remembers the status a handler wrote, so middleware can
// log and count it afterwards.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(status int) {
	s.status = status
	s.ResponseWriter.WriteHeader(status)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

// withRequestLog writes one structured record per request. It logs the
// route pattern rather than the raw path, and never logs bodies.
func withRequestLog(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(recorder, r)
		logger.Info("request",
			"method", r.Method,
			"route", routeOf(r),
			"status", recorder.status,
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}

// withRecover turns a panic in any handler into a 500 instead of a dropped
// connection, and logs it.
func withRecover(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				logger.Error("panic", "method", r.Method, "path", r.URL.Path, "panic", v)
				writeError(w, http.StatusInternalServerError, "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// routeOf returns the pattern the router matched, such as "GET /jobs/{id}".
// The router sets r.Pattern on the request it was given, so middleware that
// passed that same request can read it after calling next. Logging the
// pattern instead of the raw path keeps labels few: /jobs/1 and /jobs/2
// are one route. Unmatched requests have no pattern.
func routeOf(r *http.Request) string {
	if r.Pattern == "" {
		return "unmatched"
	}
	return r.Pattern
}
~~~

`statusRecorder` **embeds** `http.ResponseWriter`: it gets all of the writer's methods and overrides two, so it can see the status as it passes through. It's the same embedding trick as `slowGetRepository`.

Create `internal/httpapi/metrics.go`:

<!-- file: internal/httpapi/metrics.go -->
~~~go
package httpapi

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics owns its own registry instead of using Prometheus's global one,
// so each test (and each service) gets a clean, independent set.
type Metrics struct {
	registry *prometheus.Registry
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
}

func NewMetrics() *Metrics {
	m := &Metrics{
		registry: prometheus.NewRegistry(),
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "HTTP requests by route, method and status code.",
		}, []string{"route", "method", "code"}),
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency by route and method.",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
		}, []string{"route", "method"}),
	}
	m.registry.MustRegister(m.requests, m.duration)
	return m
}

// Handler serves the metrics in Prometheus's text format.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{})
}

func (m *Metrics) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(recorder, r)

		route := routeOf(r)
		m.requests.WithLabelValues(route, r.Method, strconv.Itoa(recorder.status)).Inc()
		m.duration.WithLabelValues(route, r.Method).Observe(time.Since(start).Seconds())
	})
}
~~~

This is the first third-party dependency. Run `go get github.com/prometheus/client_golang@latest`. Go records the exact version in `go.mod` and the checksums in `go.sum`. Commit both: they make the build reproducible.

`NewHandler` gains `WithLogger` and `WithMetrics` options, and wraps the router in a fixed order.

Make these changes to `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	jobs JobService
~~~

to:

~~~go
	jobs   JobService
	logger *slog.Logger
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
type config struct {
	requestTimeout time.Duration
~~~

to:

~~~go
type config struct {
	logger         *slog.Logger
	metrics        *Metrics
	requestTimeout time.Duration
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go

// WithRequestTimeout bounds how long any one request may run.
~~~

to:

~~~go

func WithLogger(logger *slog.Logger) Option {
	return func(c *config) { c.logger = logger }
}

func WithMetrics(metrics *Metrics) Option {
	return func(c *config) { c.metrics = metrics }
}

// WithRequestTimeout bounds how long any one request may run.
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
// NewHandler builds the routes and gives every request a deadline.
~~~

to:

~~~go
// NewHandler builds the routes and wraps them in middleware. The outermost
// middleware runs first on the way in and last on the way out.
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	cfg := config{requestTimeout: 2 * time.Second}
~~~

to:

~~~go
	cfg := config{
		logger:         slog.New(slog.DiscardHandler),
		requestTimeout: 2 * time.Second,
	}
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	h := &handlers{jobs: service}
~~~

to:

~~~go
	h := &handlers{jobs: service, logger: cfg.logger}
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	return withTimeout(cfg.requestTimeout, mux)
~~~

to:

~~~go
	if cfg.metrics != nil {
		mux.Handle("GET /metrics", cfg.metrics.Handler())
	}

	// Logging and metrics must receive the same *http.Request the router
	// does, so they can read the route it matched (r.Pattern). withTimeout
	// makes a copy of the request with r.WithContext, so it goes outside them.
	var handler http.Handler = mux
	if cfg.metrics != nil {
		handler = cfg.metrics.instrument(handler)
	}
	handler = withRequestLog(cfg.logger, handler)
	handler = withTimeout(cfg.requestTimeout, handler)
	handler = withRecover(cfg.logger, handler)
	return handler
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
		// The client hung up. There is nobody left to answer.
~~~

to:

~~~go
		h.logger.Info("client went away during run", "job_id", id)
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
		slog.Error("unexpected error", "method", r.Method, "path", r.URL.Path, "error", err)
~~~

to:

~~~go
		h.logger.Error("unexpected error", "method", r.Method, "path", r.URL.Path, "error", err)
~~~


Wrapping happens inside-out, so the request passes through **recover → timeout → log → metrics → router** on the way in, and back out in reverse:

~~~mermaid
flowchart LR
    REQ[request] --> RC[withRecover] --> TO[withTimeout] --> LG[withRequestLog] --> MT[metrics] --> MUX[router + handler]
~~~

`main.go` now builds a JSON logger, `slog.New(slog.NewJSONHandler(stdout, nil))`, and passes it plus `httpapi.NewMetrics()` to `NewHandler`. Those `main.go` changes follow.



Make these changes to `internal/httpapi/handler_test.go`:

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
import (
	"encoding/json"
	"net/http"
~~~

to:

~~~go
import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
~~~

Add this at the end of the file:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
func TestRequestLogUsesRoutePattern(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&logs, nil))
	h := newTestHandler(WithLogger(logger))

	do(t, h, http.MethodGet, "/jobs/42", "")

	var record map[string]any
	if err := json.Unmarshal(logs.Bytes(), &record); err != nil {
		t.Fatalf("log line %q: %v", logs.String(), err)
	}
	if record["route"] != "GET /jobs/{id}" || record["status"] != float64(404) {
		t.Fatalf("log record = %v", record)
	}
}

func TestMetricsCountRequests(t *testing.T) {
	h := newTestHandler(WithMetrics(NewMetrics()))
	do(t, h, http.MethodGet, "/health", "")
	do(t, h, http.MethodGet, "/health", "")

	body := do(t, h, http.MethodGet, "/metrics", "").Body.String()
	want := `http_requests_total{code="200",method="GET",route="GET /health"} 2`
	if !strings.Contains(body, want) {
		t.Fatalf("metrics missing %q:\n%s", want, body)
	}
}

type panickingService struct{ JobService }

func (panickingService) Get(context.Context, jobs.ID) (jobs.Job, error) { panic("boom") }

func TestPanicBecomes500(t *testing.T) {
	h := NewHandler(panickingService{}, WithLogger(slog.New(slog.NewTextHandler(io.Discard, nil))))
	response := do(t, h, http.MethodGet, "/jobs/1", "")
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", response.Code)
	}
}
~~~




Make these changes to `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"log"
~~~

to:

~~~go
	"io"
	"log/slog"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	if err := run(os.Getenv); err != nil {
~~~

to:

~~~go
	if err := run(os.Getenv, os.Stdout); err != nil {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
// run builds the service from its configuration and serves it. Taking the
// environment as a parameter instead of calling os.Getenv inside is what
// makes it testable.
func run(getenv func(string) string) error {
~~~

to:

~~~go
// run builds the service from its configuration and serves it. It takes
// its environment and output as parameters so tests can supply their own.
func run(getenv func(string) string, stdout io.Writer) error {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		return err
	}

	service := jobs.NewService(memstore.New())
	handler := httpapi.NewHandler(service, httpapi.WithRequestTimeout(cfg.RequestTimeout))
~~~

to:

~~~go
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	service := jobs.NewService(memstore.New())
	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(httpapi.NewMetrics()),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
	)
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	log.Printf("listening on http://%s", cfg.ListenAddr)
~~~

to:

~~~go
	logger.Info("listening", "addr", cfg.ListenAddr)
~~~


**Run it.** Run `REQUEST_TIMEOUT=1s go run ./cmd/api`, make a few requests of each kind, then:

~~~bash
curl -s http://127.0.0.1:8080/metrics | grep '^http_requests_total'
~~~

~~~text
http_requests_total{code="200",method="GET",route="GET /jobs/{id}"} 1
http_requests_total{code="200",method="POST",route="POST /jobs/{id}/run"} 1
http_requests_total{code="201",method="POST",route="POST /jobs"} 2
http_requests_total{code="400",method="GET",route="GET /jobs/{id}"} 1
http_requests_total{code="404",method="GET",route="GET /jobs/{id}"} 1
http_requests_total{code="409",method="POST",route="POST /jobs/{id}/run"} 1
http_requests_total{code="504",method="POST",route="POST /jobs/{id}/run"} 1
~~~

And the server's terminal shows one JSON line per request:

~~~text
{"time":"...","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/run","status":200,"duration_ms":300}
{"time":"...","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/run","status":409,"duration_ms":0}
{"time":"...","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/run","status":504,"duration_ms":1005}
~~~

Read the 504 line: `duration_ms: 1005`, which is the 1-second deadline plus scheduling time. That's the kind of evidence you'll use in incidents.

**Break it: middleware order.** Move `withTimeout` *inside* the logger: put `handler = withTimeout(...)` straight after `var handler http.Handler = mux`. Then run `go test ./internal/httpapi`:

~~~text
--- FAIL: TestRequestLogUsesRoutePattern (0.00s)
    handler_test.go:182: log record = map[... route:unmatched status:404 ...]
--- FAIL: TestMetricsCountRequests (0.00s)
    handler_test.go:194: metrics missing "http_requests_total{code=\"200\",method=\"GET\",route=\"GET /health\"} 2":
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="0.005"} 2
~~~

Every route became `unmatched`. `r.WithContext` returns a **copy** of the request. The router wrote `Pattern` onto the copy, and the logger was still holding the original. Order isn't style: it changes behaviour. Restore it.

**Explain it:** why log the route pattern rather than the path? Name the four golden signals and which metric gives each one.

**Read.** *Site Reliability Engineering* (free at sre.google), Ch. 6, *Monitoring Distributed Systems*. Carry this question in: which of your metrics would page someone at 3 a.m., and which are just for dashboards?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Step 8: Signals and graceful shutdown

**The problem.** Deploying a new version means stopping the old process. If it dies instantly, every request in flight gets a broken connection: a user's job may have run, but they never hear back. A reliable service stops **gracefully**: it stops accepting new work, finishes what it started, and then exits.

**New ideas.**

- A **signal** is a small message from the operating system to a process. Ctrl+C sends **SIGINT** (interrupt). `kill PID` and Kubernetes send **SIGTERM** (please terminate). **SIGKILL** (`kill -9`) can't be caught: the process just vanishes. So graceful shutdown can only ever handle SIGINT and SIGTERM.
- `signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)` returns a context that is cancelled when either signal arrives. Shutdown becomes "wait for `ctx.Done()`", the same idea you've used all phase.
- `server.Shutdown(ctx)`:
  1. closes the listening socket, so new connections are refused;
  2. closes idle connections;
  3. waits for active requests to finish, or until `ctx` expires.

  `server.Close()` drops everything immediately.
- A **grace period** bounds the wait. Kubernetes gives a pod 30 seconds by default between SIGTERM and SIGKILL, so the grace must be shorter than that.
- **File descriptors.** Every open file, socket and pipe a process holds is a numbered **descriptor**. On Linux you can list them under `/proc/PID/fd`. There's a per-process limit (`ulimit -n`), and leaking sockets eventually hits it.
- `run` now takes a `context.Context` and a `ready` callback, and listens with `net.Listen` first. That's so a test can listen on port `0` (meaning "any free port") and learn which port it got.

The finished `cmd/api/main.go`:

Update `cmd/api/main.go` so it matches this:

<!-- file: cmd/api/main.go -->
~~~go
// Command api runs the Runway jobs service.
//
// main is the composition root: the one place that builds every concrete
// dependency and wires them together. Nothing below it creates its own.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"runway/internal/httpapi"
	"runway/internal/jobs"
	"runway/internal/memstore"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, os.Getenv, os.Stdout, nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type config struct {
	ListenAddr     string
	RequestTimeout time.Duration
	ShutdownGrace  time.Duration
}

func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{
		ListenAddr:     "127.0.0.1:8080",
		RequestTimeout: 2 * time.Second,
		ShutdownGrace:  10 * time.Second,
	}
	if v := getenv("LISTEN_ADDR"); v != "" {
		if _, _, err := net.SplitHostPort(v); err != nil {
			return config{}, fmt.Errorf("LISTEN_ADDR must look like host:port, got %q", v)
		}
		cfg.ListenAddr = v
	}
	var err error
	if cfg.RequestTimeout, err = durationFromEnv(getenv, "REQUEST_TIMEOUT", cfg.RequestTimeout); err != nil {
		return config{}, err
	}
	if cfg.ShutdownGrace, err = durationFromEnv(getenv, "SHUTDOWN_GRACE", cfg.ShutdownGrace); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func durationFromEnv(getenv func(string) string, name string, fallback time.Duration) (time.Duration, error) {
	v := getenv(name)
	if v == "" {
		return fallback, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil || d <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration such as 2s, got %q", name, v)
	}
	return d, nil
}

// run starts the server and blocks until ctx is cancelled, then shuts down
// gracefully. Taking its environment, output and context as parameters
// instead of reading globals is what makes it testable.
func run(ctx context.Context, getenv func(string) string, stdout io.Writer, ready func(addr string)) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	service := jobs.NewService(memstore.New())
	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(httpapi.NewMetrics()),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
	)

	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      cfg.RequestTimeout + 5*time.Second,
		IdleTimeout:       60 * time.Second,
	}

	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}
	logger.Info("listening", "addr", listener.Addr().String())
	if ready != nil {
		ready(listener.Addr().String())
	}

	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(listener) }()

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}

	// Stop accepting new connections, then wait for in-flight requests to
	// finish, but never longer than the grace period.
	logger.Info("shutting down", "grace", cfg.ShutdownGrace.String())
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	logger.Info("stopped")
	return nil
}
~~~

How it fits together:

~~~mermaid
sequenceDiagram
    participant OS
    participant Main as run()
    participant Srv as http.Server
    participant H as in-flight handler
    Main->>Srv: Serve(listener) in a goroutine
    OS->>Main: SIGTERM → ctx.Done()
    Main->>Srv: Shutdown(10s grace)
    Srv->>Srv: close listener: new connections refused
    H-->>Srv: finishes and writes its response
    Srv-->>Main: Shutdown returns
    Main->>Main: log "stopped", return nil, exit 0
~~~

- `server.Serve` runs in its own goroutine and sends its result on `serveErr`, so `run` can wait for *either* a serve error *or* a shutdown signal with `select`.
- The shutdown context is built from `context.Background()`, not from `ctx`. `ctx` is already cancelled at this point, and a grace period derived from it would be zero.
- After `Shutdown`, `Serve` returns `http.ErrServerClosed`. That's the normal case, not an error.

The test that proves it, in `cmd/api/main_test.go` below, starts the server on a free port, begins a 300 ms run, cancels the context 100 ms in, and checks three things:

- the in-flight request still gets `200` with `completed`;
- `run` returns `nil`;
- a new request afterwards is refused.


Update `cmd/api/main_test.go` so it matches this:

<!-- file: cmd/api/main_test.go -->
~~~go
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestLoadConfig(t *testing.T) {
	cfg, err := loadConfig(env(nil))
	if err != nil || cfg.ListenAddr != "127.0.0.1:8080" || cfg.RequestTimeout != 2*time.Second {
		t.Fatalf("defaults = %+v, %v", cfg, err)
	}

	cfg, err = loadConfig(env(map[string]string{"LISTEN_ADDR": "0.0.0.0:9000", "REQUEST_TIMEOUT": "500ms"}))
	if err != nil || cfg.ListenAddr != "0.0.0.0:9000" || cfg.RequestTimeout != 500*time.Millisecond {
		t.Fatalf("overrides = %+v, %v", cfg, err)
	}

	if _, err := loadConfig(env(map[string]string{"LISTEN_ADDR": "8080"})); err == nil {
		t.Error("LISTEN_ADDR without a host:port form was accepted")
	}
	for _, bad := range []string{"soon", "-1s", "0s"} {
		if _, err := loadConfig(env(map[string]string{"SHUTDOWN_GRACE": bad})); err == nil {
			t.Errorf("SHUTDOWN_GRACE=%q was accepted", bad)
		}
	}
}

// syncBuffer lets the server goroutine write logs while the test reads them.
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

func TestGracefulShutdownFinishesInFlightRequest(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	addrCh := make(chan string, 1)
	runErr := make(chan error, 1)
	var logs syncBuffer
	go func() {
		runErr <- run(ctx, env(map[string]string{"LISTEN_ADDR": "127.0.0.1:0"}), &logs, func(addr string) { addrCh <- addr })
	}()
	base := "http://" + <-addrCh

	create, err := http.Post(base+"/jobs", "application/json", strings.NewReader(`{"description":"slow","duration_ms":300}`))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	create.Body.Close()

	// Start a 300ms run, then ask the server to stop while it is in flight.
	type result struct {
		status int
		state  string
		err    error
	}
	inFlight := make(chan result, 1)
	go func() {
		resp, err := http.Post(base+"/jobs/1/run", "application/json", nil)
		if err != nil {
			inFlight <- result{err: err}
			return
		}
		defer resp.Body.Close()
		var body struct{ State string }
		_ = json.NewDecoder(resp.Body).Decode(&body)
		inFlight <- result{status: resp.StatusCode, state: body.State}
	}()
	time.Sleep(100 * time.Millisecond)
	cancel()

	got := <-inFlight
	if got.err != nil || got.status != http.StatusOK || got.state != "completed" {
		t.Fatalf("in-flight request: status=%d state=%q err=%v; graceful shutdown should let it finish", got.status, got.state, got.err)
	}
	if err := <-runErr; err != nil {
		t.Fatalf("run returned %v", err)
	}

	if _, err := http.Get(base + "/health"); err == nil {
		t.Fatal("server still accepted a request after shutdown")
	}
	for _, msg := range []string{`"msg":"shutting down"`, `"msg":"stopped"`} {
		if !strings.Contains(logs.String(), msg) {
			t.Errorf("logs missing %s:\n%s", msg, logs.String())
		}
	}
}

func TestRunFailsOnBadConfig(t *testing.T) {
	err := run(context.Background(), env(map[string]string{"REQUEST_TIMEOUT": "fast"}), io.Discard, nil)
	if err == nil || !strings.Contains(err.Error(), "REQUEST_TIMEOUT") {
		t.Fatalf("error = %v, want a REQUEST_TIMEOUT config error", err)
	}
}
~~~

**Run it.** Build the binary so you can find it by name: `go build -o api ./cmd/api && ./api`. Then in a second terminal:

~~~bash
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"slow","duration_ms":1500}' >/dev/null
curl -s -X POST http://127.0.0.1:8080/jobs/1/run & sleep 0.3; kill -TERM $(pgrep -x api); wait
~~~

`&` runs the curl in the background, `kill -TERM` sends SIGTERM to the server 0.3 s later, and `wait` waits for the curl. The curl still prints `"state":"completed"`, and the server logs:

~~~text
{"time":"...","level":"INFO","msg":"shutting down","grace":"10s"}
{"time":"...","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/run","status":200,"duration_ms":1500}
{"time":"...","level":"INFO","msg":"stopped"}
~~~

**Inspect the process while it runs.** Start `./api` again, and in a second terminal:

~~~bash
ps -o pid,ppid,stat,comm -p $(pgrep -x api)
ls -l /proc/$(pgrep -x api)/fd
grep 'open files' /proc/$(pgrep -x api)/limits
~~~

~~~text
    PID    PPID STAT COMMAND
 200842  179296 SNl  api
0 -> /dev/null
1 -> /tmp/api.log
2 -> /tmp/api.log
4 -> socket:[503514]
5 -> anon_inode:[eventpoll]
...
Max open files            1048576              1048576              files
~~~

- Descriptors 0, 1 and 2 are standard input, output and error.
- `socket:[...]` is the listening socket. Each client connection adds another one.
- `eventpoll` is how Go's runtime waits on many sockets at once.
- In `STAT`, the `l` means multi-threaded: the Go runtime runs goroutines on several OS threads.

On macOS, use `lsof -p PID` instead of `/proc`. Your numbers will differ.

**A burst of concurrent requests, using only the shell:**

~~~bash
seq 1 200 | xargs -P 20 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"burst"}' \
  | sort | uniq -c
~~~

~~~text
    200 201
~~~

`xargs -P 20` runs 20 curls at a time; `-w '%{http_code}'` prints each status; `sort | uniq -c` counts them. All 200 were created, with unique IDs (the next job created gets ID 201). The Python Bridge builds a proper load generator that measures latency too.

**Break it.** Replace the `Shutdown` call with `server.Close()` and delete the two `shutdownCtx` lines above it. Run `go test ./cmd/api`:

~~~text
--- FAIL: TestGracefulShutdownFinishesInFlightRequest (0.11s)
    main_test.go:99: in-flight request: status=0 state="" err=Post "http://127.0.0.1:40111/jobs/1/run": EOF; graceful shutdown should let it finish
~~~

`EOF`: the connection was cut mid-request. The job ran on the server, but the client never found out, and might retry it. Restore `Shutdown`.

**Graceful shutdown doesn't mean "never lose work".** If the grace period expires, remaining requests are cut off. If the process gets SIGKILL or the machine loses power, nothing graceful happens at all. And the jobs in memory are lost on every exit. Phase 2 moves work into a durable queue, and Phase 3 into a database.

**Explain it:** what's the difference between SIGINT, SIGTERM and SIGKILL, and which can a program handle? Why is the shutdown context built from `context.Background()`?

**Read.** CSAPP §8.1–8.2 and §8.4–8.5 (processes and signals), and OSTEP Ch. 5 (*Process API*). Carry this question in: what exactly happens, step by step, between pressing Ctrl+C and your `select` waking up?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Rebuild it yourself

Close this guide. In your own `runway` repository (from Phase 0), rebuild Phase 1 from the **contract table**, the **layer diagram** and your notes. Use TDD: a failing test before each piece of code. You may look up Go documentation, but don't copy the lesson code.

Then compare your version with the code in this guide. Differences are fine if your tests prove the same contract. Record what you rebuilt, what you looked up, and every place where your design differs and why.

## Checkpoint

You're ready for the Python Bridge when you can, without the guide:

1. Draw the four layers and say which package may import which, and why.
2. Show a race the race detector catches, and a race it doesn't, and explain the difference.
3. Explain compare-and-swap and why `Update` takes an expected state.
4. Trace a client disconnect from the socket to `Simulate`, and show the stored job state that proves the server stopped.
5. Read `/metrics` and the request log, and answer: how many runs timed out?
6. Demonstrate graceful shutdown with an in-flight request, and explain what it does **not** protect against.
7. Explain which facts live only in memory, and what disappears on restart.

## If it goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `package runway/internal/jobs is not in std` | The module isn't named `runway`, or you're outside it | Check the first line of `go.mod`; run from the folder that contains it |
| `import cycle not allowed` | `jobs` imports `memstore` and `memstore` imports `jobs` | The domain must never import storage. Put tests that need both in `package jobs_test` |
| `use of internal package ... not allowed` | Importing `internal/` from another module | Only code inside this module can use `internal/` |
| `fatal error: concurrent map writes` | A map write without the lock | Lock every map access; run `go test -race` |
| `415 Unsupported Media Type` from curl | `-d` without `-H 'Content-Type: application/json'` | Add the header |
| Every route logged as `unmatched` | Middleware order: something between the logger and the router copied the request | Keep `withTimeout` outside the logger (step 7) |
| A job stuck in `running` | The final `Update` used a cancelled context | Use `context.WithoutCancel(ctx)` for the outcome write |
| `go: missing go.sum entry` | You added an import without fetching it | `go mod tidy` |
| `address already in use` | An old server is still running | `pgrep -x api` and stop it, or set `LISTEN_ADDR` |

## Reading list for this phase

| When | Reading | Question to carry in |
|---|---|---|
| Before step 2 | OSTEP Ch. 26–28 | What is shared between threads, and what does a lock make into one step? |
| After step 2's race | OSTEP Ch. 29, 30, 32; CSAPP §12.1 and §12.3–12.7 | Which interleaving broke it, and how does the lock remove it? |
| After step 6 | Vitillo, *Understanding Distributed Systems*, Part IV (timeouts) | How do deadlines compose across services? |
| After step 7 | *Site Reliability Engineering* Ch. 6 | Which signals matter to a user? |
| Before step 8 | CSAPP §8.1–8.2 and §8.4–8.5; OSTEP Ch. 5 | What does a process receive on Ctrl+C? |
| After the phase | DDIA Ch. 1; *Web Application Hacker's Handbook* Ch. 2; Anderson, *Security Engineering* Ch. 1 | What does "reliable" mean, and how does hostile input change it? |
| Reference | [Go context](https://pkg.go.dev/context), [net/http](https://pkg.go.dev/net/http), [log/slog](https://pkg.go.dev/log/slog), [Prometheus Go client](https://pkg.go.dev/github.com/prometheus/client_golang/prometheus) | — |
