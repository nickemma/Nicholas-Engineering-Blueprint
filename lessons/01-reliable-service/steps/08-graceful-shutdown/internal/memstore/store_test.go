package memstore

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"kestrel/internal/jobs"
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
