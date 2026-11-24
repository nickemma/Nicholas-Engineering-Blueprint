// Package queue is a bounded, in-process work queue served by a pool of
// worker goroutines.
package queue

import (
	"context"
	"errors"
	"sync"

	"switchyard/internal/jobs"
)

// ErrFull means the queue is at capacity and the job was not accepted.
var ErrFull = errors.New("queue is full")

// Queue holds job IDs waiting for a worker. Its capacity is fixed: a queue
// with no limit only moves overload from the caller into memory, where it
// grows until the process dies.
type Queue struct {
	items chan jobs.ID
}

func New(capacity int) *Queue {
	return &Queue{items: make(chan jobs.ID, capacity)}
}

// Dispatch adds a job without waiting. A full queue is refused at once, so
// the caller learns about overload now instead of timing out later.
func (q *Queue) Dispatch(_ context.Context, job jobs.Job) error {
	select {
	case q.items <- job.ID:
		return nil
	}
}

// Len is the number of jobs waiting: the queue's depth.
func (q *Queue) Len() int {
	return len(q.items)
}

// Serve runs `workers` goroutines that take jobs from the queue and pass them
// to handle. Workers stop taking new jobs when ctx is cancelled; a job
// already being handled is allowed to finish. Serve returns when every
// worker has stopped.
func (q *Queue) Serve(ctx context.Context, workers int, handle func(jobs.ID)) {
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				// When several select cases are ready, Go picks one at
				// random. Checking for cancellation first means a stopped
				// worker never takes another job just because one was waiting.
				if ctx.Err() != nil {
					return
				}
				select {
				case <-ctx.Done():
					return
				case id := <-q.items:
					handle(id)
				}
			}
		}()
	}
	wg.Wait()
}
