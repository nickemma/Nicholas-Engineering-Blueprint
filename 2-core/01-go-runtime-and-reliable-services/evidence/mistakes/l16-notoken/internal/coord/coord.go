// Package coord hands jobs to worker processes and notices when a worker
// vanishes. Workers register, take one job at a time on a lease, keep the
// lease alive with heartbeats, and report the job done. A reconcile loop
// compares what should be true (every running job is held by a live lease)
// with what is, and repairs the difference: a job whose lease expired goes
// back to be run again.
package coord

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"switchyard/internal/jobs"
)

var (
	// ErrUnknownWorker means the worker isn't registered, or was forgotten
	// after going quiet. It should register again.
	ErrUnknownWorker = errors.New("unknown worker; register again")

	// ErrLeaseLost means the caller no longer holds the job: its lease
	// expired and the job was handed back, or the job ended.
	ErrLeaseLost = errors.New("lease lost: the job is no longer yours")
)

// Jobs is what the coordinator needs from the jobs service.
type Jobs interface {
	Get(ctx context.Context, id jobs.ID) (jobs.Job, error)
	Start(ctx context.Context, id jobs.ID) (jobs.Job, error)
	Finish(ctx context.Context, id jobs.ID, workErr error) (jobs.Job, error)
	Requeue(ctx context.Context, id jobs.ID) (jobs.Job, error)
}

// Registration tells a new worker its name and how often to report in.
type Registration struct {
	WorkerID  string
	LeaseTTL  time.Duration
	Heartbeat time.Duration
}

// Lease is one worker's right to run one job until Expires. Token is
// different for every lease ever granted, so a report from an old lease
// can always be told apart from the current one: a fencing token.
type Lease struct {
	Job      jobs.Job
	Token    int64
	WorkerID string
	Expires  time.Time
}

// Held names a job a worker is running, and the lease it runs it under.
type Held struct {
	Job   jobs.ID
	Token int64
}

// Stats is a snapshot for metrics.
type Stats struct {
	Workers    int
	Leases     int
	HandedBack int
}

type Coordinator struct {
	jobs    Jobs
	pending <-chan jobs.ID
	ttl     time.Duration
	now     func() time.Time
	log     *slog.Logger

	wake      chan struct{} // a job was handed back
	stop      chan struct{} // closed by Close
	closeOnce sync.Once

	mu         sync.Mutex
	workerSeq  int
	tokenSeq   int64
	workers    map[string]time.Time // worker ID → last time it called in
	leases     map[jobs.ID]Lease
	finished   map[jobs.ID]int64 // job → token of the lease that completed it
	handBack   []jobs.ID
	handedBack int
}

// New returns a coordinator that takes new jobs from pending. A lease that
// isn't renewed within ttl expires.
func New(service Jobs, pending <-chan jobs.ID, ttl time.Duration, now func() time.Time, logger *slog.Logger) *Coordinator {
	return &Coordinator{
		jobs:     service,
		pending:  pending,
		ttl:      ttl,
		now:      now,
		log:      logger,
		wake:     make(chan struct{}, 1),
		stop:     make(chan struct{}),
		workers:  make(map[string]time.Time),
		leases:   make(map[jobs.ID]Lease),
		finished: make(map[jobs.ID]int64),
	}
}

// Register adds a worker and gives it an ID.
func (c *Coordinator) Register(name string) Registration {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.workerSeq++
	id := fmt.Sprintf("%s-%d", name, c.workerSeq)
	c.workers[id] = c.now()
	return Registration{WorkerID: id, LeaseTTL: c.ttl, Heartbeat: c.ttl / 3}
}

// seen records that a worker called in, or reports that it's unknown.
func (c *Coordinator) seen(worker string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.workers[worker]; !ok {
		return ErrUnknownWorker
	}
	c.workers[worker] = c.now()
	return nil
}

// Lease gives the worker a job, waiting up to wait for one. Jobs handed
// back by the reconcile loop go first. It reports false if no job came.
func (c *Coordinator) Lease(ctx context.Context, worker string, wait time.Duration) (Lease, bool, error) {
	if err := c.seen(worker); err != nil {
		return Lease{}, false, err
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	for {
		id, ok := c.takeHandedBack()
		if !ok {
			select {
			case id = <-c.pending:
			case <-c.wake:
				continue
			case <-timer.C:
				return Lease{}, false, nil
			case <-c.stop:
				return Lease{}, false, nil
			case <-ctx.Done():
				return Lease{}, false, ctx.Err()
			}
		}
		job, err := c.jobs.Start(context.WithoutCancel(ctx), id)
		if err != nil {
			// Cancelled while it waited: there's nothing to run.
			continue
		}
		c.mu.Lock()
		c.tokenSeq++
		lease := Lease{Job: job, Token: c.tokenSeq, WorkerID: worker, Expires: c.now().Add(c.ttl)}
		c.leases[id] = lease
		c.mu.Unlock()
		return lease, true, nil
	}
}

func (c *Coordinator) takeHandedBack() (jobs.ID, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.handBack) == 0 {
		return 0, false
	}
	id := c.handBack[0]
	c.handBack = c.handBack[1:]
	return id, true
}

// Heartbeat renews the leases the worker still holds, and returns the jobs
// it must stop: cancelled ones, and ones whose lease it has lost.
func (c *Coordinator) Heartbeat(ctx context.Context, worker string, held []Held) ([]jobs.ID, error) {
	if err := c.seen(worker); err != nil {
		return nil, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	var stop []jobs.ID
	for _, h := range held {
		lease, ok := c.leases[h.Job]
		if !ok || lease.Token != h.Token {
			stop = append(stop, h.Job)
			continue
		}
		job, err := c.jobs.Get(ctx, h.Job)
		if err != nil || job.State != jobs.StateRunning {
			delete(c.leases, h.Job)
			stop = append(stop, h.Job)
			continue
		}
		lease.Expires = c.now().Add(c.ttl)
		c.leases[h.Job] = lease
	}
	return stop, nil
}

// Complete records that the job ran to the end under the lease with this
// token. Checking the lease and finishing the job happen under one lock,
// so the reconcile loop can't hand the job back halfway through. A repeat
// of a report that already succeeded succeeds again, doing nothing: the
// worker may not have heard the first answer.
func (c *Coordinator) Complete(ctx context.Context, job jobs.ID, token int64) (jobs.Job, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if done, ok := c.finished[job]; ok && done == token {
		return c.jobs.Get(ctx, job)
	}
	_, ok := c.leases[job]
	if !ok {
		return jobs.Job{}, ErrLeaseLost
	}
	delete(c.leases, job)
	finished, err := c.jobs.Finish(context.WithoutCancel(ctx), job, nil)
	if err != nil {
		return finished, err
	}
	c.finished[job] = token
	return finished, nil
}

// Reconcile makes one pass: every expired lease is removed, and its job,
// if still running, is handed back to be run again. Workers that have gone
// quiet are forgotten.
func (c *Coordinator) Reconcile(ctx context.Context) {
	now := c.now()
	c.mu.Lock()
	defer c.mu.Unlock()
	for id, lease := range c.leases {
		if now.Before(lease.Expires) {
			continue
		}
		delete(c.leases, id)
		if _, err := c.jobs.Requeue(ctx, id); err != nil {
			continue // it isn't running any more: cancelled while its worker was silent
		}
		c.handBack = append(c.handBack, id)
		c.handedBack++
		c.log.Warn("lease expired; job handed back", "job_id", id, "worker", lease.WorkerID)
		select {
		case c.wake <- struct{}{}:
		default:
		}
	}
	for worker, last := range c.workers {
		if now.Sub(last) > c.ttl {
			delete(c.workers, worker)
			c.log.Warn("worker went quiet; forgotten", "worker", worker)
		}
	}
}

// Run reconciles every interval until ctx is done.
func (c *Coordinator) Run(ctx context.Context, every time.Duration) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.Reconcile(ctx)
		}
	}
}

// Close makes waiting Lease calls return at once, for shutdown.
func (c *Coordinator) Close() {
	c.closeOnce.Do(func() { close(c.stop) })
}

func (c *Coordinator) Stats() Stats {
	c.mu.Lock()
	defer c.mu.Unlock()
	return Stats{Workers: len(c.workers), Leases: len(c.leases), HandedBack: c.handedBack}
}
