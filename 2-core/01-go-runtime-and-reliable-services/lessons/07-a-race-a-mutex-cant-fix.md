# 07 A race a mutex can't fix

> Module: Go runtime and reliable services · Time: ~5 h · Builds on: 06

## The problem

Something has to coordinate the work: validate input, create a job, run it, record the result. That's a **use case**, and it belongs neither in the domain (which does no I/O) nor in the HTTP layer (which only translates). And running a job hides a race that the store's mutex does **not** prevent, which the race detector can't see, and which happens constantly under real load.

## The mental model

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

Each store call holds the mutex, so each **call** is safe. Nothing makes the **sequence** of calls one step: get, check, write. Between two requests' calls, the world changes. This is a **check-then-act** race, also called a **lost update**.

## The pattern

**Compare-and-swap.** `Update(ctx, job, StateQueued)` means "store this only if the job is *still* queued". The store checks and writes under one lock, so of two racing requests, one wins and the other gets `ErrConflict`. This is **optimistic concurrency control**: no lock is held across the sequence; a conflict is detected at the end, and the loser is told. Core 03 does the same in SQL with `UPDATE ... WHERE state = $expected`.

Two more tools arrive with the service:

- **Dependency injection:** `NewService(repo, ...)` receives its repository instead of creating one, so a test can pass a slow or failing one. In Go, it's just passing values to constructors.
- **Functional options:** `WithClock(...)` and `WithWork(...)` are functions that change the service after its defaults are set. Adding a setting later changes no existing caller.

## Build it

### Step 1: The service

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

- `WorkFunc` is a function type: the work a job does. The default, `Simulate`, waits for the job's duration, or until the context is cancelled, with `select` (Go from zero lesson 10). In lesson 13, real workers run it instead.
- `Run`'s first `Update` passes `StateQueued`: that's the compare-and-swap.
- `fmt.Errorf("%w: %w", ErrWorkFailed, workErr)` wraps **two** errors, so `errors.Is` finds either: "did the work fail?" and "was it a deadline?" are separate questions.
- The last `Update` uses `context.WithoutCancel(ctx)`. Step 3 shows why.

### Step 2: A test that makes the race happen

Create `internal/jobs/service_test.go`. Study `slowGetRepository` and `TestConcurrentRunStartsJobOnce`:

<!-- file: internal/jobs/service_test.go -->
~~~go
package jobs_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"switchyard/internal/jobs"
	"switchyard/internal/memstore"
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

- `package jobs_test` is an **external test package**: it can use only what `jobs` exports, as any other package would, and it can import `memstore` without an import cycle.
- `slowGetRepository` **embeds** `jobs.Repository`: it gets every method of the interface for free and overrides only `Get`, adding a pause. That pause holds the window between "get" and "write" open, so twenty concurrent `Run`s all land inside it. It's only possible because the service depends on an interface: this is what dependency injection is for.

~~~bash
go test -race -v -run Concurrent ./internal/jobs 2>&1 | grep -E "^(--- |ok|FAIL)"
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... && go test -race -count=1 ./... -->

~~~text
--- PASS: TestConcurrentRunStartsJobOnce (0.02s)
ok  	switchyard/internal/jobs	1.034s
~~~

Twenty requests, one winner, nineteen conflicts, and the work ran once.

## Break it

**Remove the compare-and-swap.** In `memstore`'s `Update`, delete the `if current.State != expected { ... }` block (and change `current, ok` to `_, ok`), then run the tests **with** the race detector:

~~~bash
go test -race ./internal/jobs
~~~

~~~text
--- FAIL: TestConcurrentRunStartsJobOnce (0.02s)
    service_test.go:153: succeeded = 20, work ran 20 times; want 1 and 1
FAIL
FAIL	switchyard/internal/jobs	0.054s
FAIL
~~~

All twenty ran the same job, and **`-race` reported nothing**: every map access is still locked. The race detector finds *data* races, unsynchronised access to memory. This is a *logic* race, and only a test that checks the outcome catches it. Without the slow repository, the test usually passes even with the bug, because the window is microseconds wide; in production, with thousands of requests a second, it isn't. Restore the check.

**Write the record with a cancelled context.** `Run`'s final write uses `context.WithoutCancel(ctx)`, a context that keeps the request's values but is never cancelled. This test explains why:

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

Change `context.WithoutCancel(ctx)` to plain `ctx`:

~~~text
--- FAIL: TestRunRecordsDeadlineAsFailure (0.02s)
    service_test.go:87: error = context deadline exceeded, want work failed by deadline
FAIL
FAIL	switchyard/internal/jobs	0.041s
FAIL
~~~

The deadline stopped the work, which is right. But the same expired context made the store refuse the final write, so the job is **stuck in `running` forever**: nothing retries it, nothing reports it. Cancellation should stop *work*; it mustn't stop you recording what happened. Restore it.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race -count=3 ./...
~~~

Then draw the check-then-act race from memory, and explain: why doesn't the mutex prevent it? Why doesn't `-race` detect it? What does `WithoutCancel` protect against?

That proves a job runs once however many requests race for it. It's still only reachable from Go code: the next lesson puts it behind HTTP.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `import cycle not allowed` | `service_test.go` says `package jobs` and imports `memstore` | Use `package jobs_test` |
| `TestConcurrentRunStartsJobOnce` passes even with the check removed | The slow repository isn't used, so the window is too small | Pass `slowGetRepository` to `NewService` |
| A job stays `running` after a timeout | The final `Update` used the cancelled context | `context.WithoutCancel(ctx)` |
| `succeeded = 0` | The job wasn't queued, or `Update` compares against the wrong state | `Update(ctx, job, StateQueued)` for the start |
