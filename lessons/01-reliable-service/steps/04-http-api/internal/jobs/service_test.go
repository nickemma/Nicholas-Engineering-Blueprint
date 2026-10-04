package jobs_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"kestrel/internal/jobs"
	"kestrel/internal/memstore"
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
