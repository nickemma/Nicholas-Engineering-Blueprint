// Package memstore keeps jobs in this process's memory. Everything it holds
// is lost when the process exits.
package memstore

import (
	"context"
	"sync"

	"kestrel/internal/jobs"
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
