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
