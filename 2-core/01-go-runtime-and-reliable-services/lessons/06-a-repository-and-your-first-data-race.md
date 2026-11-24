# 06 A repository, and your first data race

> Module: Go runtime and reliable services · Time: ~5 h · Builds on: 05

## The problem

Jobs must be kept somewhere. If the service talks to a map directly, then moving to PostgreSQL in core 03 means rewriting the service. And the moment two requests arrive at once, a plain map breaks in a way you can't see by reading the code: Go's HTTP server runs every request in its own goroutine, all of them sharing the same memory.

## The mental model

~~~text
 jobs (the domain) ── defines ──▶ Repository interface: Create, Get, Update   (the "port")
                                        ▲
                                        │ satisfies (no "implements" needed)
 memstore.Store ── map[ID]Job + RWMutex ┘                                     (an "adapter")
                   core 03 adds a second adapter: PostgreSQL

 request A goroutine ─┐
 request B goroutine ─┼──▶ s.mu.Lock() … one at a time inside … s.mu.Unlock()
 request C goroutine ─┘
~~~

## The pattern

**Ports and adapters.** The domain declares the interface it needs, `Repository`; another package provides it. The dependency points **inward**: `memstore` imports `jobs`, never the other way round, so the domain stays free of storage details. Every method takes a `context.Context` first: it carries the caller's cancellation and deadline, which matters little for a map and a lot for a database (lesson 10).

## Build it

### Step 1: The port

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
// it; storage packages implement it. This module uses an in-memory store, and
// core 03 adds PostgreSQL without changing this interface.
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

`Update` takes the state the caller *expects* the job to be in. The next lesson shows why that parameter is the most important line in this module.

### Step 2: An in-memory adapter

Create `internal/memstore/store.go`:

<!-- file: internal/memstore/store.go -->
~~~go
// Package memstore keeps jobs in this process's memory. Everything it holds
// is lost when the process exits.
package memstore

import (
	"context"
	"sync"

	"switchyard/internal/jobs"
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

- `sync.RWMutex` has two modes: `Lock` for a writer (alone) and `RLock` for readers (many at once, no writer). Go from zero lesson 10 used the plain `sync.Mutex`.
- `defer s.mu.Unlock()` releases the lock however the function returns.
- Jobs are stored **by value**, `map[jobs.ID]jobs.Job`, not pointers. `Get` returns a copy, so no caller can change stored data except through `Update`, under the lock. If the map held pointers, two goroutines could change the same job outside the lock.
- `ctx.Err()` is non-nil once the caller has given up; checking it first means abandoned requests don't do more work.
- The lock covers only the map and the counter, never slow work: a lock held during slow work makes every other request wait.

### Step 3: Tests, including one that runs at once

Create `internal/memstore/store_test.go`. The one to study is `TestConcurrentCreateIDsAreUnique`: a hundred goroutines create jobs at the same moment, and every ID must be different.

<!-- file: internal/memstore/store_test.go -->
~~~go
package memstore

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"switchyard/internal/jobs"
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

In a goroutine, a test uses `t.Errorf` (record and continue), never `t.Fatalf`, which may only be called from the test's own goroutine. Run them with the race detector, which watches every memory access while the tests run:

~~~bash
go test -race ./internal/memstore
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... && go test -race -count=1 ./... -->

~~~text
ok  	switchyard/internal/memstore	1.018s
~~~

## Break it

**Cause the race.** In `Create`, delete the two lines `s.mu.Lock()` and `defer s.mu.Unlock()`, and run the same command:

~~~text
==================
WARNING: DATA RACE
Read at 0x00c0000cc978 by goroutine 31:
  switchyard/internal/memstore.(*Store).Create()
      /home/ada/blueprint/switchyard/internal/memstore/store.go:30 +0x94
  switchyard/internal/memstore.TestConcurrentCreateIDsAreUnique.func1()
      /home/ada/blueprint/switchyard/internal/memstore/store_test.go:85 +0x1b8

Previous write at 0x00c0000cc978 by goroutine 21:
  switchyard/internal/memstore.(*Store).Create()
      /home/ada/blueprint/switchyard/internal/memstore/store.go:30 +0xaf
  switchyard/internal/memstore.TestConcurrentCreateIDsAreUnique.func1()
      /home/ada/blueprint/switchyard/internal/memstore/store_test.go:85 +0x1b8

Goroutine 31 (running) created at:
  switchyard/internal/memstore.TestConcurrentCreateIDsAreUnique()
      /home/ada/blueprint/switchyard/internal/memstore/store_test.go:83 +0x132
  testing.tRunner()
      /usr/local/go/src/testing/testing.go:2195 +0x21c
  testing.(*T).Run.gowrap1()
      /usr/local/go/src/testing/testing.go:2260 +0x38

Goroutine 21 (finished) created at:
  switchyard/internal/memstore.TestConcurrentCreateIDsAreUnique()
      /home/ada/blueprint/switchyard/internal/memstore/store_test.go:83 +0x132
  testing.tRunner()
      /usr/local/go/src/testing/testing.go:2195 +0x21c
  testing.(*T).Run.gowrap1()
      /usr/local/go/src/testing/testing.go:2260 +0x38
==================
==================
WARNING: DATA RACE
Write at 0x00c0000cc930 by goroutine 31:
  runtime.mapassign_fast64()
      /usr/local/go/src/internal/runtime/maps/runtime_fast64.go:182 +0x0
  switchyard/internal/memstore.(*Store).Create()
      /home/ada/blueprint/switchyard/internal/memstore/store.go:32 +0x104
  switchyard/internal/memstore.TestConcurrentCreateIDsAreUnique.func1()
      /home/ada/blueprint/switchyard/internal/memstore/store_test.go:85 +0x1b8

Previous write at 0x00c0000cc930 by goroutine 21:
  runtime.mapassign_fast64()
      /usr/local/go/src/internal/runtime/maps/runtime_fast64.go:182 +0x0
  switchyard/internal/memstore.(*Store).Create()
      /home/ada/blueprint/switchyard/internal/memstore/store.go:32 +0x104
  switchyard/internal/memstore.TestConcurrentCreateIDsAreUnique.func1()
      /home/ada/blueprint/switchyard/internal/memstore/store_test.go:85 +0x1b8

Goroutine 31 (running) created at:
  switchyard/internal/memstore.TestConcurrentCreateIDsAreUnique()
      /home/ada/blueprint/switchyard/internal/memstore/store_test.go:83 +0x132
  testing.tRunner()
      /usr/local/go/src/testing/testing.go:2195 +0x21c
  testing.(*T).Run.gowrap1()
      /usr/local/go/src/testing/testing.go:2260 +0x38

Goroutine 21 (finished) created at:
  switchyard/internal/memstore.TestConcurrentCreateIDsAreUnique()
      /home/ada/blueprint/switchyard/internal/memstore/store_test.go:83 +0x132
  testing.tRunner()
      /usr/local/go/src/testing/testing.go:2195 +0x21c
  testing.(*T).Run.gowrap1()
      /usr/local/go/src/testing/testing.go:2260 +0x38
==================
fatal error: concurrent map writes

goroutine 14 [running]:
internal/runtime/maps.fatal({0x639131?, 0xc2b80accad505ab5?})
	/usr/local/go/src/runtime/panic.go:1197 +0x18
switchyard/internal/memstore.(*Store).Create(0xc0000cc960, {0x7f0488, _}, {0x10, {0x6345d5, 0x6}, 0x0, {0x6345db, 0x6}, {0x0, ...}, ...})
	/home/ada/blueprint/switchyard/internal/memstore/store.go:32 +0x105
switchyard/internal/memstore.TestConcurrentCreateIDsAreUnique.func1()
	/home/ada/blueprint/switchyard/internal/memstore/store_test.go:85 +0x1b9
created by switchyard/internal/memstore.TestConcurrentCreateIDsAreUnique in goroutine 9
	/home/ada/blueprint/switchyard/internal/memstore/store_test.go:83 +0x133
FAIL	switchyard/internal/memstore	0.020s
FAIL
~~~

How to read it: one goroutine **read** a memory address at `store.go`'s `s.nextID++` line, while another had **written** the same address at the same line. `++` isn't one step: two goroutines can both read 4, both write 5, and two jobs get ID 5. Without `-race` the test may well pass, which is exactly why races are dangerous. Restore the lock: clean again.

**A race report proves a bug. A clean run doesn't prove there are none**: the detector only sees the interleavings that happened during that run. That's why concurrent tests run many goroutines, many times.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race -count=3 ./...
~~~

`-count=3` runs every test three times, giving the race detector more interleavings to see. Then answer: why does `jobs` define `Repository`, instead of `memstore`? Why store jobs by value?

Read *Operating Systems: Three Easy Pieces* chapters 26–28 (concurrency, the thread API, locks), with this question: what exactly does the lock make into "one step", and what does it leave outside?

That proves one store is safe for one operation at a time. It doesn't make a *sequence* of operations safe: read a job, decide, write it back. The next lesson breaks exactly that.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `WARNING: DATA RACE` | Shared memory touched by two goroutines without a lock | Lock around every access, reads included |
| `fatal error: concurrent map writes` | Two goroutines wrote the map at once; Go detected it and stopped | The same: the map needs the lock |
| A test hangs | A lock never released, or `Lock` inside a function that already holds it | Use `defer` right after `Lock`; never lock twice |
| `memstore` doesn't compile: `missing method Update` | The method signature differs from the interface | Match `Repository` exactly, `context.Context` first |
| `t.Fatalf` from a goroutine | Not allowed outside the test's own goroutine | Use `t.Errorf` there |
