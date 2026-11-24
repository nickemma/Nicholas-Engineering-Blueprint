# 03 Collapse concurrent misses with singleflight

> Caching · Week 1

## The problem

When a popular key expires, many readers can fetch the same job from PostgreSQL at once. That burst is a cache stampede.

## The mental model

~~~text
several callers miss the same key
    ├─ leader   → recheck Redis → load once → fill
    └─ waiters  → share the result or stop on their own deadline
~~~

## The pattern

A singleflight group shares work for the same key within a process. Recheck the cache inside the shared call. A reader can miss and arrive at the group just after another caller has filled the key and left. Give the shared fill a deadline of its own and let each reader stop waiting on its own context. [Go singleflight API](https://pkg.go.dev/golang.org/x/sync/singleflight#Group.DoChan)

## Build it

### Give the repository a group

Import singleflight and add a group to the repository instance. Keep the same repository instance for requests within the process.

<!-- edit: internal/cache/repository.go -->
~~~go
	"switchyard/caching/internal/jobs"
~~~

Replace it with the group-enabled version.

~~~go
	"golang.org/x/sync/singleflight"
	"switchyard/caching/internal/jobs"
~~~

<!-- edit: internal/cache/repository.go -->
~~~go
type Repository struct {
	origin Origin
	cache  Cache
	ttl    time.Duration
	logger *slog.Logger
}
~~~

Replace it with the group-enabled version.

~~~go
type Repository struct {
	origin Origin
	cache  Cache
	ttl    time.Duration
	logger *slog.Logger
	loads  singleflight.Group
}
~~~

### Share the fill and its result

Replace the read file with the version below. Register the same job ID with `DoChan` and handle the caller's cancellation separately from completion of the fill.

Create `internal/cache/read.go`.

<!-- file: internal/cache/read.go -->
~~~go
package cache

import (
	"context"
	"errors"

	"switchyard/caching/internal/jobs"
)

func (r *Repository) Load(ctx context.Context, id string) (jobs.Job, error) {
	if !jobs.ValidID(id) {
		return jobs.Job{}, errors.New("invalid job ID")
	}
	if cached, hit := r.lookup(ctx, id); hit {
		return cached, nil
	}
	if err := ctx.Err(); err != nil {
		return jobs.Job{}, err
	}

	result := r.loads.DoChan(id, func() (any, error) {
		// The shared fill has its own deadline. One departing waiter does
		// not cancel the result for every other waiter.
		fillCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), fillTimeout)
		defer cancel()
		if cached, hit := r.lookup(fillCtx, id); hit {
			return cached, nil
		}
		return r.fill(fillCtx, id)
	})
	select {
	case <-ctx.Done():
		return jobs.Job{}, ctx.Err()
	case received := <-result:
		if received.Err != nil {
			return jobs.Job{}, received.Err
		}
		return received.Val.(jobs.Job), nil
	}
}
~~~

### Hold the origin long enough to observe the burst

Use a `synctest` bubble to wait until every reader has reached a blocking point. Release the origin and verify both the responses and the number of origin calls. Cancel the first waiter in a separate run and check that the second still receives the result.

Create `internal/cache/repository_test.go`.

<!-- file: internal/cache/repository_test.go -->
~~~go
package cache

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"switchyard/caching/internal/jobs"
)

type originProbe struct {
	Origin
	read  func(context.Context, string) (jobs.Job, error)
	reads atomic.Int64
}

func (p *originProbe) Load(ctx context.Context, id string) (jobs.Job, error) {
	p.reads.Add(1)
	return p.read(ctx, id)
}

type memoryCache struct{ values sync.Map }

func (m *memoryCache) Get(_ context.Context, id string) (jobs.Job, bool, error) {
	if value, ok := m.values.Load(id); ok {
		return value.(jobs.Job), true, nil
	}
	return jobs.Job{}, false, nil
}

func (m *memoryCache) Put(_ context.Context, job jobs.Job, _ time.Duration) error {
	m.values.Store(job.ID, job)
	return nil
}

func (m *memoryCache) Delete(_ context.Context, id string) error {
	m.values.Delete(id)
	return nil
}

func TestColdBurst(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		const requests = 32
		releaseOrigin := make(chan struct{})
		want := jobs.Job{ID: "burst", State: "queued", Revision: 1}
		probe := &originProbe{read: func(ctx context.Context, _ string) (jobs.Job, error) {
			select {
			case <-releaseOrigin:
				return want, nil
			case <-ctx.Done():
				return jobs.Job{}, ctx.Err()
			}
		}}
		logger := slog.New(slog.NewTextHandler(io.Discard, nil))
		repo := New(probe, &memoryCache{}, time.Second, logger)
		results := make(chan error, requests)

		for range requests {
			go func() {
				got, err := repo.Load(t.Context(), want.ID)
				if err == nil && got != want {
					err = errors.New("read returned the wrong job")
				}
				results <- err
			}()
		}
		synctest.Wait()
		close(releaseOrigin)
		for range requests {
			if err := <-results; err != nil {
				t.Fatal(err)
			}
		}
		if calls := probe.reads.Load(); calls != 1 {
			t.Fatalf("stampede: origin reads = %d, want 1", calls)
		}
		t.Logf("cold burst: %d concurrent misses, %d origin read", requests, probe.reads.Load())
	})
}

func TestCancelledWaiter(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		releaseOrigin := make(chan struct{})
		probe := &originProbe{read: func(ctx context.Context, id string) (jobs.Job, error) {
			select {
			case <-releaseOrigin:
				return jobs.Job{ID: id, State: "queued", Revision: 1}, nil
			case <-ctx.Done():
				return jobs.Job{}, ctx.Err()
			}
		}}
		logger := slog.New(slog.NewTextHandler(io.Discard, nil))
		repo := New(probe, &memoryCache{}, time.Second, logger)
		first, cancel := context.WithCancel(t.Context())
		defer cancel()
		stopped, kept := make(chan error, 1), make(chan error, 1)
		go func() {
			_, err := repo.Load(first, "job")
			stopped <- err
		}()
		synctest.Wait()
		go func() {
			_, err := repo.Load(t.Context(), "job")
			kept <- err
		}()
		synctest.Wait()

		cancel()
		if err := <-stopped; !errors.Is(err, context.Canceled) {
			t.Fatalf("cancelled waiter: %v", err)
		}
		close(releaseOrigin)
		if err := <-kept; err != nil || probe.reads.Load() != 1 {
			t.Fatalf("remaining waiter: %v, origin reads = %d", err, probe.reads.Load())
		}
		t.Log("cancelling the first caller preserved the shared fill")
	})
}
~~~

## Check it

~~~bash
go test -race -count=1 -v -run 'TestColdBurst|TestCancelledWaiter' ./internal/cache
~~~

<!-- run: go test -race -count=1 -v -run 'TestColdBurst|TestCancelledWaiter' ./internal/cache -->

The reference reports `cold burst: 32 concurrent misses, 1 origin read`. The live tests repeat the burst with Redis and PostgreSQL. Each application replica owns a separate group, so additional replicas can each begin their own fill.
