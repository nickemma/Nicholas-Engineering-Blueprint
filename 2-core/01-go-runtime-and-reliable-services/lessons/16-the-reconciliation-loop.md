# 16 The reconciliation loop

> Module: Go runtime and reliable services · Time: ~7 h · Builds on: 15, and lessons 07 and 14

## The problem

Switchyard does everything in one process: it takes requests, stores jobs, and runs them. One process can't use more than one machine, and when it dies, everything stops at once. Real systems split the two halves. The **control plane** decides what should happen: it stores jobs and hands them out. The **data plane** does the work: here, worker processes, as many as you need, on as many machines.

Splitting them brings a new problem, the oldest one in distributed systems. A worker takes a job, and then goes silent. Is it dead (killed, out of memory, its machine unplugged), or just slow (a long garbage-collection pause, an overloaded machine, a network that's dropping packets)? From the outside, **you can't tell**. A job given to a dead worker must be given to someone else, or it's lost. A job given to a slow worker mustn't be finished twice. This lesson builds the machinery that handles both, and then a gate that kills workers at random to prove it.

## The mental model

~~~text
                       control plane (cmd/switchyard)
  POST /jobs ──► jobs ──► pending ──┐
  POST /jobs/{id}/cancel            │ Lease ◄──────────── worker a ── runs job 7 ── Heartbeat every 1 s
                                    │ Heartbeat ◄─────────    "still mine?" "yes" / "stop"
           reconcile loop ──────────┤ Complete(7, token) ◄─   "done, under lease 41"
           every 0.5 s:             │
           "every running job       │                      worker b ── waiting for a job
            has a live lease?"      │
            no → hand it back ──────┘                      worker c ── killed: no more heartbeats
~~~

- A **lease** is a lock that runs out. The control plane gives a worker job 7 for 3 seconds. The worker must renew it, with a **heartbeat**, before it runs out. A dead worker stops renewing, so its lease expires *by itself*: no one has to detect the death.
- A **fencing token** is a number that's different for every lease ever granted. When job 7 is handed to a second worker, it gets a new token. If the first worker was only paused, it wakes up and reports "done under lease 41", but the job now belongs to lease 57. The report is refused. Without the token, the control plane can't tell a stale report from a current one.
- **Desired state vs actual state.** The desired state is "every running job is held by a live lease". The actual state is whatever happened: workers died, leases expired, jobs were cancelled. A **reconciliation loop** compares the two, over and over, and repairs the difference.
- The loop is **level-triggered**: each pass looks at *how things are now*, not at a stream of events. It doesn't need to see the moment a worker died, so it can't miss it either. Whatever one pass misses, the next one finds. That's the pattern behind every Kubernetes controller, and behind most control planes you'll meet: describe what should be true, and run a loop that makes it so.
- The work may now run **twice**: a worker killed after finishing but before reporting has done the work, and the next worker does it again. The *effect* still happens once, because the control plane records it only when a `Complete` with the current token wins the compare-and-swap of lesson 07, under the ledger key of lesson 14.

And one new state: a job can be **cancelled**. A queued job is cancelled at once; a running one is marked cancelled, and its worker hears "stop" at its next heartbeat. A cancelled job never completes, and never gets an effect.

## The pattern

**Never trust a component to report its own death.** Give it a lease, make it renew, fence every report with a token, and let a level-triggered loop repair whatever doesn't match.

## Build it

### Step 1: Cancelled, and handed back

Two new state changes. A job can be **cancelled** from `queued` or `running`, and a running job can go **back to `queued`** when its worker vanishes. In `internal/jobs/job.go`, add the state. Change:

<!-- edit: internal/jobs/job.go -->
~~~go
	StateFailed    State = "failed"
)
~~~

to:

~~~go
	StateFailed    State = "failed"
	StateCancelled State = "cancelled"
)
~~~

Allow the new moves, and give jobs a way to say they're finished for good. Change:

<!-- edit: internal/jobs/job.go -->
~~~go
// allowed lists every legal state change. Anything not listed is refused.
// A queued job may fail without running: it can be rejected before any
// worker picks it up.
var allowed = map[State][]State{
	StateQueued:  {StateRunning, StateFailed},
	StateRunning: {StateCompleted, StateFailed},
}
~~~

to:

~~~go
// allowed lists every legal state change. Anything not listed is refused.
// A queued job may fail without running: it can be rejected before any
// worker picks it up. A running job goes back to queued when its worker
// vanishes, and either can be cancelled.
var allowed = map[State][]State{
	StateQueued:  {StateRunning, StateFailed, StateCancelled},
	StateRunning: {StateCompleted, StateFailed, StateQueued, StateCancelled},
}

// Final reports whether the job has reached a state it never leaves.
func (j Job) Final() bool {
	return len(allowed[j.State]) == 0
}
~~~

`Final` reads the rule from the table itself: a state with nowhere to go is final. Add the two methods next to `Fail`. Change:

<!-- edit: internal/jobs/job.go -->
~~~go
func (j *Job) Fail(reason string, now time.Time) error {
~~~

to:

~~~go
// Requeue hands a running job back, to be run again from the start.
func (j *Job) Requeue(now time.Time) error {
	return j.transition(StateQueued, now)
}

func (j *Job) Cancel(now time.Time) error {
	return j.transition(StateCancelled, now)
}

func (j *Job) Fail(reason string, now time.Time) error {
~~~

Lesson 05's table said `running → queued` was illegal. It isn't any more, and the test records the decision. In `internal/jobs/job_test.go`, change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
		{StateRunning, StateQueued, false},
		{StateCompleted, StateRunning, false},
		{StateCompleted, StateFailed, false},
		{StateFailed, StateRunning, false},
~~~

to:

~~~go
		{StateRunning, StateQueued, true},
		{StateQueued, StateCancelled, true},
		{StateRunning, StateCancelled, true},
		{StateCompleted, StateRunning, false},
		{StateCompleted, StateFailed, false},
		{StateCompleted, StateCancelled, false},
		{StateFailed, StateRunning, false},
		{StateCancelled, StateRunning, false},
		{StateCancelled, StateQueued, false},
~~~

and add at the end of the file:

<!-- append: internal/jobs/job_test.go -->
~~~go
func TestFinalStates(t *testing.T) {
	for _, s := range []State{StateQueued, StateRunning, StateCompleted, StateFailed, StateCancelled} {
		want := s == StateCompleted || s == StateFailed || s == StateCancelled
		if got := (Job{State: s}).Final(); got != want {
			t.Errorf("Final() for %s = %v, want %v", s, got, want)
		}
	}
}
~~~

<!-- run: go test ./internal/jobs/ -run 'TestTransitions|TestFinalStates' -->

### Step 2: `Run` splits in two

`Service.Run` started a job, did its work and recorded the outcome, all in one process. Now the work happens in another process, so `Run` splits: `Start` when a worker takes the job, `Finish` when it reports back. Both are compare-and-swap changes, like lesson 07's, so `Service` gets one helper, `change`, that every state change goes through: read, decide, write if nobody else wrote first, otherwise read again and decide again. The work function, and the retry policy around it, move to the worker. The ledger moves in: `Finish` records a completed job's effect, but only after its state change won.

The ledger needs a method that fits the service's new port. Add at the end of `internal/ledger/ledger.go`:

<!-- append: internal/ledger/ledger.go -->
~~~go
// RecordFor records a job's effect under its own key. It makes the ledger a
// jobs.Effects.
func (l *Ledger) RecordFor(job jobs.ID, now time.Time) bool {
	return l.Apply(KeyFor(job), job, now)
}
~~~

Replace `internal/jobs/service.go`:

<!-- file: internal/jobs/service.go -->
~~~go
package jobs

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// ErrDispatchFailed means the job was stored but could not be handed to a
// worker. The job is marked failed so it never sits queued forever.
var ErrDispatchFailed = errors.New("job could not be dispatched")

// WorkFunc does a job's actual work. It must stop when ctx is done.
type WorkFunc func(ctx context.Context, job Job) error

// Dispatcher hands a stored job to whatever will run it.
type Dispatcher interface {
	Dispatch(ctx context.Context, job Job) error
}

// Effects records a completed job's effect, once. ledger.Ledger is one.
type Effects interface {
	RecordFor(job ID, now time.Time) bool
}

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
	repo     Repository
	dispatch Dispatcher
	effects  Effects
	now      func() time.Time
}

// Option changes one setting of a Service.
type Option func(*Service)

// WithClock replaces the clock, for tests.
func WithClock(now func() time.Time) Option {
	return func(s *Service) { s.now = now }
}

// WithDispatcher sends every created job to d. Without one, jobs are only
// stored.
func WithDispatcher(d Dispatcher) Option {
	return func(s *Service) { s.dispatch = d }
}

// WithEffects records each completed job's effect in e.
func WithEffects(e Effects) Option {
	return func(s *Service) { s.effects = e }
}

func NewService(repo Repository, opts ...Option) *Service {
	s := &Service{
		repo: repo,
		now:  func() time.Time { return time.Now().UTC() },
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// Create stores a queued job and dispatches it. Storing and dispatching are
// two separate steps, so they can't be made atomic here: if dispatch fails,
// Create marks the stored job failed. If the process crashes between the two
// steps, the job stays queued forever. The transactional outbox (the Event
// streams unit) removes that gap.
func (s *Service) Create(ctx context.Context, description string, duration time.Duration) (Job, error) {
	d, err := NewDescription(description)
	if err != nil {
		return Job{}, err
	}
	job, err := New(d, duration, s.now())
	if err != nil {
		return Job{}, err
	}
	job, err = s.repo.Create(ctx, job)
	if err != nil || s.dispatch == nil {
		return job, err
	}

	if dispatchErr := s.dispatch.Dispatch(ctx, job); dispatchErr != nil {
		_ = job.Fail("not dispatched: "+dispatchErr.Error(), s.now())
		if err := s.repo.Update(context.WithoutCancel(ctx), job, StateQueued); err != nil {
			return Job{}, err
		}
		return job, fmt.Errorf("%w: %w", ErrDispatchFailed, dispatchErr)
	}
	return job, nil
}

func (s *Service) Get(ctx context.Context, id ID) (Job, error) {
	return s.repo.Get(ctx, id)
}

// change makes one state change with compare-and-swap: it reads the job,
// lets apply change it, and stores it only if nobody changed it in between.
// If somebody did, it reads the newer job and lets apply decide again.
func (s *Service) change(ctx context.Context, id ID, apply func(*Job) error) (Job, error) {
	for {
		job, err := s.repo.Get(ctx, id)
		if err != nil {
			return Job{}, err
		}
		before := job.State
		if err := apply(&job); err != nil {
			return job, err
		}
		err = s.repo.Update(ctx, job, before)
		if errors.Is(err, ErrConflict) {
			continue
		}
		return job, err
	}
}

// Start moves a queued job to running, for the worker that will run it.
func (s *Service) Start(ctx context.Context, id ID) (Job, error) {
	return s.change(ctx, id, func(j *Job) error { return j.Start(s.now()) })
}

// Finish records how a running job ended. If it completed, its effect is
// recorded too, but only after the state change succeeded: a job that was
// cancelled or handed to another worker in the meantime gets no effect.
// (With a database, the two writes would be one transaction.)
func (s *Service) Finish(ctx context.Context, id ID, workErr error) (Job, error) {
	job, err := s.change(ctx, id, func(j *Job) error {
		if workErr != nil {
			return j.Fail(workErr.Error(), s.now())
		}
		return j.Complete(s.now())
	})
	if err == nil && job.State == StateCompleted && s.effects != nil {
		s.effects.RecordFor(job.ID, s.now())
	}
	return job, err
}

// Requeue hands a running job back, to be run again from the start.
func (s *Service) Requeue(ctx context.Context, id ID) (Job, error) {
	return s.change(ctx, id, func(j *Job) error { return j.Requeue(s.now()) })
}

// Cancel stops a job that hasn't finished. A queued job is never run; a
// running job's worker is told to stop at its next heartbeat.
func (s *Service) Cancel(ctx context.Context, id ID) (Job, error) {
	return s.change(ctx, id, func(j *Job) error { return j.Cancel(s.now()) })
}
~~~

- `change` is lesson 07's compare-and-swap made reusable. On `ErrConflict` it doesn't give up: it rereads, and lets the domain decide again. If another worker started the job first, the second decision is "`running → running` is illegal", and that's the answer.
- `Finish` changes the state first and records the effect second. If a cancel won the race, `Finish` fails and there's no effect. The reverse order would record effects for jobs that end up cancelled.
- `Cancel` and `Requeue` are one line each: the rules are in the domain.

The tests change with it: `Run`'s tests go, and `Start`, `Finish`, `Cancel` and `Requeue` get theirs. The concurrency test from lesson 07 stays, now racing `Start`, and a new one races `Cancel` against `Finish`. Replace `internal/jobs/service_test.go`:

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
	"switchyard/internal/ledger"
	"switchyard/internal/memstore"
)

var fixedNow = time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)

func fixedClock() time.Time { return fixedNow }

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

func TestStartFinishRecordsTheEffectOnce(t *testing.T) {
	effects := ledger.New()
	svc := jobs.NewService(memstore.New(), jobs.WithClock(fixedClock), jobs.WithEffects(effects))
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)

	if _, err := svc.Start(ctx, job.ID); err != nil {
		t.Fatalf("Start: %v", err)
	}
	done, err := svc.Finish(ctx, job.ID, nil)
	if err != nil || done.State != jobs.StateCompleted {
		t.Fatalf("Finish = %s, %v; want completed", done.State, err)
	}
	if _, err := svc.Finish(ctx, job.ID, nil); !errors.Is(err, jobs.ErrInvalidTransition) {
		t.Fatalf("second Finish error = %v, want ErrInvalidTransition", err)
	}
	if n := effects.EffectsFor(job.ID); n != 1 {
		t.Fatalf("effects = %d, want 1", n)
	}
}

func TestCancelledJobGetsNoEffect(t *testing.T) {
	effects := ledger.New()
	svc := jobs.NewService(memstore.New(), jobs.WithEffects(effects))
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)
	_, _ = svc.Start(ctx, job.ID)

	if c, err := svc.Cancel(ctx, job.ID); err != nil || c.State != jobs.StateCancelled {
		t.Fatalf("Cancel = %s, %v; want cancelled", c.State, err)
	}
	if _, err := svc.Finish(ctx, job.ID, nil); !errors.Is(err, jobs.ErrInvalidTransition) {
		t.Fatalf("Finish after Cancel error = %v, want ErrInvalidTransition", err)
	}
	if n := effects.EffectsFor(job.ID); n != 0 {
		t.Fatalf("effects = %d, want 0 for a cancelled job", n)
	}
	if _, err := svc.Cancel(ctx, job.ID); !errors.Is(err, jobs.ErrInvalidTransition) {
		t.Fatalf("second Cancel error = %v, want ErrInvalidTransition", err)
	}
}

func TestRequeueHandsARunningJobBack(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)
	_, _ = svc.Start(ctx, job.ID)

	back, err := svc.Requeue(ctx, job.ID)
	if err != nil || back.State != jobs.StateQueued {
		t.Fatalf("Requeue = %s, %v; want queued", back.State, err)
	}
	if again, err := svc.Start(ctx, job.ID); err != nil || again.State != jobs.StateRunning {
		t.Fatalf("Start after Requeue = %s, %v; want running", again.State, err)
	}
}

func TestUnknownJob(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	if _, err := svc.Start(context.Background(), 99); !errors.Is(err, jobs.ErrNotFound) {
		t.Fatalf("error = %v, want ErrNotFound", err)
	}
}

// slowGetRepository wraps a real repository and pauses after every Get. That
// widens the gap between Start's Get and its Update, so a race that would
// otherwise happen once in a thousand runs happens every time.
type slowGetRepository struct {
	jobs.Repository
}

func (r slowGetRepository) Get(ctx context.Context, id jobs.ID) (jobs.Job, error) {
	job, err := r.Repository.Get(ctx, id)
	time.Sleep(5 * time.Millisecond)
	return job, err
}

// Twenty workers race to start one job. The compare-and-swap in Update lets
// exactly one win; the others reread the job, see it's running, and stop.
func TestConcurrentStartStartsJobOnce(t *testing.T) {
	svc := jobs.NewService(slowGetRepository{memstore.New()})
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)

	const callers = 20
	errs := make(chan error, callers)
	var wg sync.WaitGroup
	for range callers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := svc.Start(ctx, job.ID)
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
		case errors.Is(err, jobs.ErrInvalidTransition):
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	if succeeded != 1 {
		t.Fatalf("%d callers started the job, want exactly 1", succeeded)
	}
}

// Cancel and Finish race for one running job. Whichever wins, the job ends
// in one final state, and has an effect only if it completed.
func TestCancelRacesFinish(t *testing.T) {
	for range 50 {
		effects := ledger.New()
		svc := jobs.NewService(memstore.New(), jobs.WithEffects(effects))
		ctx := context.Background()
		job, _ := svc.Create(ctx, "resize", 0)
		_, _ = svc.Start(ctx, job.ID)

		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); _, _ = svc.Cancel(ctx, job.ID) }()
		go func() { defer wg.Done(); _, _ = svc.Finish(ctx, job.ID, nil) }()
		wg.Wait()

		final, _ := svc.Get(ctx, job.ID)
		want := 0
		if final.State == jobs.StateCompleted {
			want = 1
		} else if final.State != jobs.StateCancelled {
			t.Fatalf("state = %s, want completed or cancelled", final.State)
		}
		if n := effects.EffectsFor(job.ID); n != want {
			t.Fatalf("%s job has %d effects, want %d", final.State, n, want)
		}
	}
}

type failingDispatcher struct{ err error }

func (d failingDispatcher) Dispatch(context.Context, jobs.Job) error { return d.err }

type recordingDispatcher struct {
	mu  sync.Mutex
	ids []jobs.ID
}

func (d *recordingDispatcher) Dispatch(_ context.Context, job jobs.Job) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.ids = append(d.ids, job.ID)
	return nil
}

func TestCreateDispatchesTheStoredJob(t *testing.T) {
	dispatcher := &recordingDispatcher{}
	svc := jobs.NewService(memstore.New(), jobs.WithDispatcher(dispatcher))

	job, err := svc.Create(context.Background(), "resize", 0)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if len(dispatcher.ids) != 1 || dispatcher.ids[0] != job.ID {
		t.Fatalf("dispatched %v, want [%d]", dispatcher.ids, job.ID)
	}
}

func TestCreateMarksJobFailedWhenDispatchFails(t *testing.T) {
	full := errors.New("queue is full")
	svc := jobs.NewService(memstore.New(), jobs.WithDispatcher(failingDispatcher{full}))
	ctx := context.Background()

	job, err := svc.Create(ctx, "resize", 0)
	if !errors.Is(err, jobs.ErrDispatchFailed) || !errors.Is(err, full) {
		t.Fatalf("error = %v, want dispatch failure wrapping %v", err, full)
	}
	stored, _ := svc.Get(ctx, job.ID)
	if stored.State != jobs.StateFailed || stored.FailureReason != "not dispatched: queue is full" {
		t.Fatalf("stored = %+v, want failed and never queued forever", stored)
	}
}
~~~

<!-- run: go test -race -count=3 ./internal/jobs/ ./internal/ledger/ -->

### Step 3: The queue becomes a list

Lesson 13's `Serve` ran a pool of goroutines inside the control plane. That pool is gone: the queue only holds jobs until a worker asks for one. In `internal/queue/queue.go`, change the package comment:

<!-- edit: internal/queue/queue.go -->
~~~go
// Package queue is a bounded, in-process work queue served by a pool of
// worker goroutines.
~~~

to:

~~~go
// Package queue is a bounded, in-process queue of jobs waiting for a
// worker.
~~~

drop the import `Serve` needed:

<!-- edit: internal/queue/queue.go -->
~~~go
	"errors"
	"sync"
~~~

to:

~~~go
	"errors"
~~~

and replace `Serve` with the channel jobs come out of:

<!-- edit: internal/queue/queue.go -->
~~~go
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
~~~

to:

~~~go
// Next is where jobs come out, oldest first. Whoever hands jobs to workers
// receives from it; a job taken from it is gone from the queue.
func (q *Queue) Next() <-chan jobs.ID {
	return q.items
}
~~~

Replace `internal/queue/queue_test.go`: the refusal test stays, and the pool's tests become one test of the order jobs come out in.

<!-- file: internal/queue/queue_test.go -->
~~~go
package queue

import (
	"context"
	"errors"
	"testing"
	"time"

	"switchyard/internal/jobs"
)

func TestFullQueueRefusesImmediately(t *testing.T) {
	q := New(2)
	ctx := context.Background()

	for id := range 2 {
		if err := q.Dispatch(ctx, jobs.Job{ID: jobs.ID(id + 1)}); err != nil {
			t.Fatalf("Dispatch %d: %v", id+1, err)
		}
	}
	start := time.Now()
	if err := q.Dispatch(ctx, jobs.Job{ID: 3}); !errors.Is(err, ErrFull) {
		t.Fatalf("third Dispatch error = %v, want %v", err, ErrFull)
	}
	if waited := time.Since(start); waited > 10*time.Millisecond {
		t.Fatalf("refusal took %v; a full queue must not make the caller wait", waited)
	}
	if q.Len() != 2 {
		t.Fatalf("Len = %d, want 2", q.Len())
	}
}

func TestNextGivesJobsInOrder(t *testing.T) {
	q := New(10)
	for id := range 3 {
		_ = q.Dispatch(context.Background(), jobs.Job{ID: jobs.ID(id + 1)})
	}
	for want := jobs.ID(1); want <= 3; want++ {
		if got := <-q.Next(); got != want {
			t.Fatalf("Next = %d, want %d", got, want)
		}
	}
	if q.Len() != 0 {
		t.Fatalf("Len = %d after taking every job, want 0", q.Len())
	}
}
~~~

<!-- run: go test -race ./internal/queue/ -->

### Step 4: The coordinator

Everything about workers lives in one package. Create `internal/coord/coord.go`:

<!-- file: internal/coord/coord.go -->
~~~go
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
	lease, ok := c.leases[job]
	if !ok || lease.Token != token {
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
~~~

Read it in the order a job meets it:

- **`Register`** gives a worker an ID, and tells it the lease TTL and how often to send heartbeats (a third of the TTL, so two can be lost before the lease runs out).
- **`Lease`** is a **long poll**: it waits up to `wait` for a job, so an idle worker isn't hammering the control plane with requests. Jobs handed back go first. `Start` is the compare-and-swap; if a job was cancelled while it waited, `Start` fails and `Lease` takes the next one. Every lease gets the next **token**.
- **`Heartbeat`** renews the leases a worker still holds, and answers with the jobs it must stop: cancelled ones, and ones whose lease it has lost.
- **`Complete`** checks the token and finishes the job under one lock, so the reconcile loop can't hand the job back halfway through. The `finished` map makes it **idempotent**: a worker that didn't hear the answer asks again, and gets "yes" again, with no second effect. That's lesson 14's rule, applied to a report instead of a request.
- **`Reconcile`** is the loop's body: every expired lease is removed, and if its job is still running, the job is handed back. Workers that have gone quiet are forgotten.
- **`Close`** releases workers waiting in `Lease`, so shutdown doesn't wait for long polls.

Its tests move a fake clock by hand, so a 3-second lease expires in no time. Create `internal/coord/coord_test.go`:

<!-- file: internal/coord/coord_test.go -->
~~~go
package coord

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"switchyard/internal/jobs"
	"switchyard/internal/ledger"
	"switchyard/internal/memstore"
	"switchyard/internal/queue"
)

const ttl = 3 * time.Second

// fakeClock is a clock the test moves by hand, so leases expire without
// waiting.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (f *fakeClock) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

func (f *fakeClock) Advance(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.now = f.now.Add(d)
}

type fixture struct {
	svc     *jobs.Service
	effects *ledger.Ledger
	clock   *fakeClock
	c       *Coordinator
}

func setup(t *testing.T) fixture {
	t.Helper()
	clock := &fakeClock{now: time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)}
	q := queue.New(100)
	effects := ledger.New()
	svc := jobs.NewService(memstore.New(), jobs.WithDispatcher(q), jobs.WithEffects(effects), jobs.WithClock(clock.Now))
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return fixture{svc: svc, effects: effects, clock: clock, c: New(svc, q.Next(), ttl, clock.Now, logger)}
}

func (f fixture) create(t *testing.T) jobs.Job {
	t.Helper()
	job, err := f.svc.Create(context.Background(), "resize", 0)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	return job
}

func (f fixture) lease(t *testing.T, worker string) Lease {
	t.Helper()
	lease, ok, err := f.c.Lease(context.Background(), worker, 100*time.Millisecond)
	if err != nil || !ok {
		t.Fatalf("Lease = %v, %v; want a job", ok, err)
	}
	return lease
}

func (f fixture) state(t *testing.T, id jobs.ID) jobs.State {
	t.Helper()
	job, _ := f.svc.Get(context.Background(), id)
	return job.State
}

func TestLeaseStartsTheJob(t *testing.T) {
	f := setup(t)
	job := f.create(t)
	w := f.c.Register("w").WorkerID

	lease := f.lease(t, w)
	if lease.Job.ID != job.ID || lease.Token == 0 || f.state(t, job.ID) != jobs.StateRunning {
		t.Fatalf("lease = %+v, state %s; want job %d running", lease, f.state(t, job.ID), job.ID)
	}
}

func TestLeaseWithNothingToDoReturnsEmpty(t *testing.T) {
	f := setup(t)
	w := f.c.Register("w").WorkerID
	if _, ok, err := f.c.Lease(context.Background(), w, 20*time.Millisecond); ok || err != nil {
		t.Fatalf("Lease = %v, %v; want no job and no error", ok, err)
	}
}

func TestUnknownWorkerMustRegister(t *testing.T) {
	f := setup(t)
	if _, _, err := f.c.Lease(context.Background(), "nobody-1", time.Millisecond); !errors.Is(err, ErrUnknownWorker) {
		t.Fatalf("error = %v, want ErrUnknownWorker", err)
	}
}

func TestCompleteIsSafeToRepeat(t *testing.T) {
	f := setup(t)
	job := f.create(t)
	w := f.c.Register("w").WorkerID
	lease := f.lease(t, w)

	for range 2 { // the worker didn't hear the first answer, and asks again
		done, err := f.c.Complete(context.Background(), job.ID, lease.Token)
		if err != nil || done.State != jobs.StateCompleted {
			t.Fatalf("Complete = %s, %v; want completed", done.State, err)
		}
	}
	if n := f.effects.EffectsFor(job.ID); n != 1 {
		t.Fatalf("effects = %d, want 1", n)
	}
}

func TestExpiredLeaseIsHandedToAnotherWorker(t *testing.T) {
	f := setup(t)
	job := f.create(t)
	slow := f.c.Register("slow").WorkerID
	first := f.lease(t, slow)

	f.clock.Advance(ttl + time.Second) // slow stops calling in
	f.c.Reconcile(context.Background())
	if s := f.state(t, job.ID); s != jobs.StateQueued {
		t.Fatalf("state after expiry = %s, want queued", s)
	}

	fresh := f.c.Register("fresh").WorkerID
	second := f.lease(t, fresh)
	if second.Job.ID != job.ID || second.Token == first.Token {
		t.Fatalf("second lease = %+v; want job %d with a new token", second, job.ID)
	}
	// The slow worker wakes up and reports, with its old token: refused.
	if _, err := f.c.Complete(context.Background(), job.ID, first.Token); !errors.Is(err, ErrLeaseLost) {
		t.Fatalf("stale Complete error = %v, want ErrLeaseLost", err)
	}
	if _, err := f.c.Complete(context.Background(), job.ID, second.Token); err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if n := f.effects.EffectsFor(job.ID); n != 1 {
		t.Fatalf("effects = %d, want 1: the work ran twice, the effect once", n)
	}
}

func TestHeartbeatsKeepTheLease(t *testing.T) {
	f := setup(t)
	job := f.create(t)
	w := f.c.Register("w").WorkerID
	lease := f.lease(t, w)

	for range 5 { // 5 × 2 s is far past the TTL, but renewed every time
		f.clock.Advance(2 * time.Second)
		if stop, err := f.c.Heartbeat(context.Background(), w, []Held{{job.ID, lease.Token}}); err != nil || len(stop) != 0 {
			t.Fatalf("Heartbeat = %v, %v; want nothing to stop", stop, err)
		}
		f.c.Reconcile(context.Background())
	}
	if s := f.state(t, job.ID); s != jobs.StateRunning {
		t.Fatalf("state = %s, want still running", s)
	}
}

func TestHeartbeatStopsACancelledJob(t *testing.T) {
	f := setup(t)
	job := f.create(t)
	w := f.c.Register("w").WorkerID
	lease := f.lease(t, w)

	if _, err := f.svc.Cancel(context.Background(), job.ID); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	stop, err := f.c.Heartbeat(context.Background(), w, []Held{{job.ID, lease.Token}})
	if err != nil || len(stop) != 1 || stop[0] != job.ID {
		t.Fatalf("Heartbeat = %v, %v; want [%d]", stop, err, job.ID)
	}
	if _, err := f.c.Complete(context.Background(), job.ID, lease.Token); err == nil {
		t.Fatal("Complete of a cancelled job succeeded")
	}
	if n := f.effects.EffectsFor(job.ID); n != 0 {
		t.Fatalf("effects = %d, want 0", n)
	}
}

func TestCancelledJobIsNeverLeased(t *testing.T) {
	f := setup(t)
	first := f.create(t)
	second := f.create(t)
	if _, err := f.svc.Cancel(context.Background(), first.ID); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	w := f.c.Register("w").WorkerID
	if lease := f.lease(t, w); lease.Job.ID != second.ID {
		t.Fatalf("leased job %d, want %d: job %d was cancelled", lease.Job.ID, second.ID, first.ID)
	}
}

func TestQuietWorkersAreForgotten(t *testing.T) {
	f := setup(t)
	w := f.c.Register("w").WorkerID
	f.clock.Advance(ttl + time.Second)
	f.c.Reconcile(context.Background())
	if f.c.Stats().Workers != 0 {
		t.Fatalf("workers = %d, want 0", f.c.Stats().Workers)
	}
	if _, err := f.c.Heartbeat(context.Background(), w, nil); !errors.Is(err, ErrUnknownWorker) {
		t.Fatalf("error = %v, want ErrUnknownWorker", err)
	}
}

func TestCloseReleasesWaitingWorkers(t *testing.T) {
	f := setup(t)
	w := f.c.Register("w").WorkerID
	go func() {
		time.Sleep(20 * time.Millisecond)
		f.c.Close()
	}()
	start := time.Now()
	if _, ok, _ := f.c.Lease(context.Background(), w, 10*time.Second); ok || time.Since(start) > 5*time.Second {
		t.Fatalf("Lease after Close = %v after %v; want no job, at once", ok, time.Since(start))
	}
}
~~~

`TestExpiredLeaseIsHandedToAnotherWorker` is the whole lesson in one test: a worker goes quiet, the job goes to another, the first one wakes up and is refused, and the effect happens once.

<!-- run: go test -race -count=3 ./internal/coord/ -->

### Step 5: The workers' contract

Workers reach the coordinator over gRPC. Create `proto/switchyard/workers/v1/workers.proto`:

<!-- file: proto/switchyard/workers/v1/workers.proto -->
~~~text
syntax = "proto3";

package switchyard.workers.v1;

option go_package = "switchyard/internal/grpcapi/workersv1";

// Workers is how worker processes take jobs from the control plane and
// report back. A worker registers once, then repeats: lease a job, run it
// while sending heartbeats, complete it.
service Workers {
  rpc Register(RegisterRequest) returns (RegisterResponse);
  rpc Lease(LeaseRequest) returns (LeaseResponse);
  rpc Heartbeat(HeartbeatRequest) returns (HeartbeatResponse);
  rpc Complete(CompleteRequest) returns (CompleteResponse);
}

message RegisterRequest {
  string name = 1;
}

message RegisterResponse {
  string worker_id = 1;
  int64 lease_ttl_ms = 2;
  int64 heartbeat_ms = 3;
}

message LeaseRequest {
  string worker_id = 1;
  int64 wait_ms = 2; // how long to wait for a job before answering "none"
}

message LeaseResponse {
  bool granted = 1;
  int64 job_id = 2;
  int64 duration_ms = 3;
  int64 token = 4;
}

message Held {
  int64 job_id = 1;
  int64 token = 2;
}

message HeartbeatRequest {
  string worker_id = 1;
  repeated Held held = 2;
}

message HeartbeatResponse {
  repeated int64 stop_job_ids = 1; // jobs the worker must stop: cancelled, or no longer its own
}

message CompleteRequest {
  string worker_id = 1;
  int64 job_id = 2;
  int64 token = 3;
}

message CompleteResponse {}
~~~

Jobs can be cancelled now, so the jobs API needs the state too. Following lesson 15's rule, the new value gets a **new** number; nothing existing changes. In `proto/switchyard/jobs/v1/jobs.proto`, change:

<!-- edit: proto/switchyard/jobs/v1/jobs.proto -->
~~~text
  STATE_FAILED = 4;
}
~~~

to:

~~~text
  STATE_FAILED = 4;
  STATE_CANCELLED = 5;
}
~~~

Regenerate both:

<!-- run: PATH=$PWD/bin:$PATH protoc --go_out=. --go_opt=module=switchyard --go-grpc_out=. --go-grpc_opt=module=switchyard proto/switchyard/jobs/v1/jobs.proto proto/switchyard/workers/v1/workers.proto -->
~~~bash
PATH=$PWD/bin:$PATH protoc --go_out=. --go_opt=module=switchyard \
  --go-grpc_out=. --go-grpc_opt=module=switchyard \
  proto/switchyard/jobs/v1/jobs.proto proto/switchyard/workers/v1/workers.proto
~~~

Map the new state in `internal/grpcapi/server.go`. Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
	jobs.StateFailed:    jobsv1.State_STATE_FAILED,
}
~~~

to:

~~~go
	jobs.StateFailed:    jobsv1.State_STATE_FAILED,
	jobs.StateCancelled: jobsv1.State_STATE_CANCELLED,
}
~~~

Then the adapter. Create `internal/grpcapi/workers.go`:

<!-- file: internal/grpcapi/workers.go -->
~~~go
package grpcapi

import (
	"context"
	"errors"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"switchyard/internal/coord"
	"switchyard/internal/grpcapi/workersv1"
	"switchyard/internal/jobs"
)

// Coordinator is what the workers' gRPC API needs from coord.
type Coordinator interface {
	Register(name string) coord.Registration
	Lease(ctx context.Context, worker string, wait time.Duration) (coord.Lease, bool, error)
	Heartbeat(ctx context.Context, worker string, held []coord.Held) ([]jobs.ID, error)
	Complete(ctx context.Context, job jobs.ID, token int64) (jobs.Job, error)
}

// maxLeaseWait caps how long one Lease call may wait, so a worker always
// hears back while its connection is healthy.
const maxLeaseWait = 5 * time.Second

type WorkersServer struct {
	workersv1.UnimplementedWorkersServer
	coord Coordinator
}

func NewWorkers(c Coordinator) *WorkersServer {
	return &WorkersServer{coord: c}
}

func (s *WorkersServer) Register(_ context.Context, req *workersv1.RegisterRequest) (*workersv1.RegisterResponse, error) {
	if req.GetName() == "" {
		return nil, status.Error(codes.InvalidArgument, "name is required")
	}
	r := s.coord.Register(req.GetName())
	return &workersv1.RegisterResponse{
		WorkerId:    r.WorkerID,
		LeaseTtlMs:  r.LeaseTTL.Milliseconds(),
		HeartbeatMs: r.Heartbeat.Milliseconds(),
	}, nil
}

func (s *WorkersServer) Lease(ctx context.Context, req *workersv1.LeaseRequest) (*workersv1.LeaseResponse, error) {
	wait := min(time.Duration(req.GetWaitMs())*time.Millisecond, maxLeaseWait)
	lease, ok, err := s.coord.Lease(ctx, req.GetWorkerId(), wait)
	if err != nil {
		return nil, workerStatus(err)
	}
	if !ok {
		return &workersv1.LeaseResponse{}, nil
	}
	return &workersv1.LeaseResponse{
		Granted:    true,
		JobId:      int64(lease.Job.ID),
		DurationMs: lease.Job.Duration.Milliseconds(),
		Token:      lease.Token,
	}, nil
}

func (s *WorkersServer) Heartbeat(ctx context.Context, req *workersv1.HeartbeatRequest) (*workersv1.HeartbeatResponse, error) {
	held := make([]coord.Held, 0, len(req.GetHeld()))
	for _, h := range req.GetHeld() {
		held = append(held, coord.Held{Job: jobs.ID(h.GetJobId()), Token: h.GetToken()})
	}
	stop, err := s.coord.Heartbeat(ctx, req.GetWorkerId(), held)
	if err != nil {
		return nil, workerStatus(err)
	}
	resp := &workersv1.HeartbeatResponse{}
	for _, id := range stop {
		resp.StopJobIds = append(resp.StopJobIds, int64(id))
	}
	return resp, nil
}

func (s *WorkersServer) Complete(ctx context.Context, req *workersv1.CompleteRequest) (*workersv1.CompleteResponse, error) {
	if _, err := s.coord.Complete(ctx, jobs.ID(req.GetJobId()), req.GetToken()); err != nil {
		return nil, workerStatus(err)
	}
	return &workersv1.CompleteResponse{}, nil
}

// workerStatus maps coordinator errors to gRPC codes. FailedPrecondition
// tells a worker "don't retry this": the job isn't yours to finish.
func workerStatus(err error) error {
	switch {
	case errors.Is(err, coord.ErrUnknownWorker):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, coord.ErrLeaseLost), errors.Is(err, jobs.ErrInvalidTransition):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return status.FromContextError(err).Err()
	default:
		return status.Error(codes.Internal, "internal error")
	}
}
~~~

`workerStatus` is this API's `toStatus`. The important line is `FailedPrecondition`: it tells a worker "this job isn't yours to finish; don't retry". Lesson 14's retry policy stops at once on it.

<!-- run: go vet ./internal/grpcapi/ && go test -race ./internal/grpcapi/ -->

### Step 6: Cancel, and count effects, over HTTP

Two routes: `POST /jobs/{id}/cancel`, and `GET /effects/{id}`, which says how many effects a job has had. The second exists so a check outside the process, such as this module's gate, can verify the promise. In `internal/httpapi/handler.go`, extend the port, and give the handlers the counter. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	Get(ctx context.Context, id jobs.ID) (jobs.Job, error)
}

type handlers struct {
	jobs   JobService
	logger *slog.Logger
}
~~~

to:

~~~go
	Get(ctx context.Context, id jobs.ID) (jobs.Job, error)
	Cancel(ctx context.Context, id jobs.ID) (jobs.Job, error)
}

// EffectCounter says how many effects a job has had. *ledger.Ledger is one.
type EffectCounter interface {
	EffectsFor(job jobs.ID) int
}

type handlers struct {
	jobs    JobService
	effects EffectCounter
	logger  *slog.Logger
}
~~~

Add it to the configuration:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	idempotency    *idempotency.Store
}
~~~

to:

~~~go
	idempotency    *idempotency.Store
	effects        EffectCounter
}
~~~

and an option:

<!-- edit: internal/httpapi/handler.go -->
~~~go
// Option configures the handler built by NewHandler.
~~~

to:

~~~go
// WithEffects serves GET /effects/{id}, so a check can count each job's
// effects from outside the process.
func WithEffects(e EffectCounter) Option {
	return func(c *config) { c.effects = e }
}

// Option configures the handler built by NewHandler.
~~~

Pass it in. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	h := &handlers{jobs: service, logger: cfg.logger}
~~~

to:

~~~go
	h := &handlers{jobs: service, effects: cfg.effects, logger: cfg.logger}
~~~

Add the routes. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	mux.HandleFunc("GET /jobs/{id}", h.getJob)
~~~

to:

~~~go
	mux.HandleFunc("GET /jobs/{id}", h.getJob)
	mux.HandleFunc("POST /jobs/{id}/cancel", h.cancelJob)
	if cfg.effects != nil {
		mux.HandleFunc("GET /effects/{id}", h.getEffects)
	}
~~~

And the handlers, above `parseID`. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
func parseID(
~~~

to:

~~~go
// cancelJob stops a job that hasn't finished: 200 with the cancelled job,
// or 409 if it had already finished.
func (h *handlers) cancelJob(w http.ResponseWriter, r *http.Request) {
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	job, err := h.jobs.Cancel(r.Context(), id)
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toResponse(job))
}

type effectsResponse struct {
	JobID   jobs.ID `json:"job_id"`
	Effects int     `json:"effects"`
}

func (h *handlers) getEffects(w http.ResponseWriter, r *http.Request) {
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, effectsResponse{JobID: id, Effects: h.effects.EffectsFor(id)})
}

func parseID(
~~~

Cancelling a finished job is the domain's `ErrInvalidTransition`, which `writeDomainError` already turns into `409`. Test both routes. Add at the end of `internal/httpapi/handler_test.go`:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
func TestCancel(t *testing.T) {
	h := newTestHandler()
	do(t, h, http.MethodPost, "/jobs", `{"description":"resize"}`)

	first := do(t, h, http.MethodPost, "/jobs/1/cancel", "")
	if first.Code != http.StatusOK || decode(t, first).State != "cancelled" {
		t.Fatalf("cancel = %d %s, want 200 and cancelled", first.Code, first.Body)
	}
	if again := do(t, h, http.MethodPost, "/jobs/1/cancel", ""); again.Code != http.StatusConflict {
		t.Fatalf("second cancel = %d, want 409", again.Code)
	}
	if missing := do(t, h, http.MethodPost, "/jobs/99/cancel", ""); missing.Code != http.StatusNotFound {
		t.Fatalf("cancel of an unknown job = %d, want 404", missing.Code)
	}
}

type countEffects map[jobs.ID]int

func (c countEffects) EffectsFor(job jobs.ID) int { return c[job] }

func TestEffects(t *testing.T) {
	h := newTestHandler(WithEffects(countEffects{7: 1}))
	got := do(t, h, http.MethodGet, "/effects/7", "")
	if got.Code != http.StatusOK || strings.TrimSpace(got.Body.String()) != `{"job_id":7,"effects":1}` {
		t.Fatalf("GET /effects/7 = %d %s", got.Code, got.Body)
	}
	if none := do(t, newTestHandler(), http.MethodGet, "/effects/7", ""); none.Code != http.StatusNotFound {
		t.Fatalf("without WithEffects = %d, want 404", none.Code)
	}
}
~~~

<!-- run: go test -race ./internal/httpapi/ -->

### Step 7: The control plane

`main` loses its workers and gains the coordinator. Its settings change too: `WORKERS`, `JOB_TIMEOUT`, `RETRY_ATTEMPTS` and `FAIL_RATE` belong to the worker now, and `LEASE_TTL` (default `3s`) is new. Replace `cmd/switchyard/main.go`:

<!-- file: cmd/switchyard/main.go -->
~~~go
// Command switchyard runs Switchyard's control plane: an HTTP API and a gRPC
// API for jobs, and a gRPC API through which worker processes take jobs on
// leases and report back. It does no work itself.
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
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"

	"switchyard/internal/coord"
	"switchyard/internal/grpcapi"
	"switchyard/internal/grpcapi/jobsv1"
	"switchyard/internal/grpcapi/workersv1"
	"switchyard/internal/httpapi"
	"switchyard/internal/idempotency"
	"switchyard/internal/jobs"
	"switchyard/internal/ledger"
	"switchyard/internal/memstore"
	"switchyard/internal/queue"
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
	GRPCAddr       string
	RequestTimeout time.Duration
	ShutdownGrace  time.Duration
	QueueCapacity  int
	IdempotencyTTL time.Duration
	LeaseTTL       time.Duration
}

func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{
		ListenAddr:     "127.0.0.1:8080",
		GRPCAddr:       "127.0.0.1:9090",
		RequestTimeout: 2 * time.Second,
		ShutdownGrace:  10 * time.Second,
		QueueCapacity:  100,
		IdempotencyTTL: 24 * time.Hour,
		LeaseTTL:       3 * time.Second,
	}
	var err error
	if cfg.ListenAddr, err = hostPortFromEnv(getenv, "LISTEN_ADDR", cfg.ListenAddr); err != nil {
		return config{}, err
	}
	if cfg.GRPCAddr, err = hostPortFromEnv(getenv, "GRPC_ADDR", cfg.GRPCAddr); err != nil {
		return config{}, err
	}
	if cfg.RequestTimeout, err = durationFromEnv(getenv, "REQUEST_TIMEOUT", cfg.RequestTimeout); err != nil {
		return config{}, err
	}
	if cfg.ShutdownGrace, err = durationFromEnv(getenv, "SHUTDOWN_GRACE", cfg.ShutdownGrace); err != nil {
		return config{}, err
	}
	if cfg.QueueCapacity, err = positiveIntFromEnv(getenv, "QUEUE_CAPACITY", cfg.QueueCapacity); err != nil {
		return config{}, err
	}
	if cfg.IdempotencyTTL, err = durationFromEnv(getenv, "IDEMPOTENCY_TTL", cfg.IdempotencyTTL); err != nil {
		return config{}, err
	}
	if cfg.LeaseTTL, err = durationFromEnv(getenv, "LEASE_TTL", cfg.LeaseTTL); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func hostPortFromEnv(getenv func(string) string, name string, fallback string) (string, error) {
	v := getenv(name)
	if v == "" {
		return fallback, nil
	}
	if _, _, err := net.SplitHostPort(v); err != nil {
		return "", fmt.Errorf("%s must look like host:port, got %q", name, v)
	}
	return v, nil
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

func positiveIntFromEnv(getenv func(string) string, name string, fallback int) (int, error) {
	v := getenv(name)
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("%s must be a positive whole number, got %q", name, v)
	}
	return n, nil
}

// run starts the APIs and the reconcile loop, blocks until ctx is
// cancelled, then shuts everything down gracefully.
func run(ctx context.Context, getenv func(string) string, stdout io.Writer, ready func(addr string)) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	effects := ledger.New()
	pending := queue.New(cfg.QueueCapacity)
	service := jobs.NewService(memstore.New(), jobs.WithDispatcher(pending), jobs.WithEffects(effects))
	coordinator := coord.New(service, pending.Next(), cfg.LeaseTTL, time.Now, logger)
	keys := idempotency.NewStore(cfg.IdempotencyTTL, time.Now)

	metrics := httpapi.NewMetrics()
	gauge := func(name, help string, value func() float64) prometheus.Collector {
		return prometheus.NewGaugeFunc(prometheus.GaugeOpts{Name: name, Help: help}, value)
	}
	metrics.MustRegister(
		collectors.NewGoCollector(), // go_goroutines, go_memstats_*, ...
		gauge("jobs_queue_depth", "Jobs waiting for a worker.", func() float64 { return float64(pending.Len()) }),
		gauge("idempotency_keys", "Idempotency keys currently remembered.", func() float64 { return float64(keys.Len()) }),
		gauge("workers", "Workers that have called in within the lease TTL.", func() float64 { return float64(coordinator.Stats().Workers) }),
		gauge("leases", "Jobs held by a worker right now.", func() float64 { return float64(coordinator.Stats().Leases) }),
		prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "jobs_handed_back_total",
			Help: "Jobs whose lease expired and were handed back to be run again.",
		}, func() float64 { return float64(coordinator.Stats().HandedBack) }),
		prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "effects_applied_total",
			Help: "Job effects recorded in the ledger.",
		}, func() float64 { applied, _ := effects.Counts(); return float64(applied) }),
	)

	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
		httpapi.WithIdempotency(keys),
		httpapi.WithEffects(effects),
	)
	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      cfg.RequestTimeout + 5*time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Background loops run until shutdown, and run waits for them, so the
	// process never exits with one half-way through.
	loops, stopLoops := context.WithCancel(context.Background())
	defer stopLoops()
	var background sync.WaitGroup
	background.Add(2)
	go func() {
		defer background.Done()
		coordinator.Run(loops, cfg.LeaseTTL/6)
	}()
	go func() {
		defer background.Done()
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-loops.Done():
				return
			case <-ticker.C:
				if removed := keys.Sweep(); removed > 0 {
					logger.Info("swept idempotency keys", "removed", removed)
				}
			}
		}
	}()

	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}
	grpcListener, err := net.Listen("tcp", cfg.GRPCAddr)
	if err != nil {
		listener.Close()
		return err
	}
	logger.Info("listening", "addr", listener.Addr().String(), "grpc_addr", grpcListener.Addr().String(), "lease_ttl", cfg.LeaseTTL.String())
	if ready != nil {
		ready(listener.Addr().String())
	}

	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(listener) }()

	grpcServer := grpc.NewServer()
	jobsv1.RegisterJobsServer(grpcServer, grpcapi.New(service))
	workersv1.RegisterWorkersServer(grpcServer, grpcapi.NewWorkers(coordinator))
	reflection.Register(grpcServer)
	go func() { _ = grpcServer.Serve(grpcListener) }()

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}

	logger.Info("shutting down", "grace", cfg.ShutdownGrace.String())
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()

	// 1. Stop accepting HTTP requests, so no new jobs arrive.
	if err := server.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return err
	}

	// 2. Release workers waiting for a job, then stop gRPC, waiting for
	// calls in progress until the grace period ends. Workers holding jobs
	// keep running them; their reports will fail, and they'll retry.
	coordinator.Close()
	grpcStopped := make(chan struct{})
	go func() {
		grpcServer.GracefulStop()
		close(grpcStopped)
	}()
	select {
	case <-grpcStopped:
	case <-shutdownCtx.Done():
		grpcServer.Stop()
	}

	// 3. Stop the background loops, and wait for them.
	stopLoops()
	background.Wait()
	logger.Info("stopped", "jobs_left_in_queue", pending.Len(), "leases_held", coordinator.Stats().Leases)
	return nil
}
~~~

What's new:

- `coord.New` takes jobs from `pending.Next()`, and `coordinator.Run` reconciles six times per lease TTL: every half second by default.
- `collectors.NewGoCollector()` adds the Go runtime's own metrics to `/metrics`, among them **`go_goroutines`**. A count that grows under load and never comes back down is a goroutine leak, and the gate checks for exactly that.
- New gauges: `workers`, `leases`, and the counter `jobs_handed_back_total`.
- Background loops run until `stopLoops`, and `run` waits for them with a `WaitGroup` before returning: nothing is left half-way through.
- Shutdown: HTTP first, then `coordinator.Close()` releases long polls, then gRPC, then the loops. Workers holding jobs aren't the control plane's to stop: they have their own SIGTERM.

Replace `cmd/switchyard/main_test.go`. The tests that waited for in-process workers go; a control plane with no workers leaves jobs queued, and can cancel them:

<!-- file: cmd/switchyard/main_test.go -->
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
	if err != nil || cfg.QueueCapacity != 100 || cfg.LeaseTTL != 3*time.Second || cfg.GRPCAddr != "127.0.0.1:9090" {
		t.Fatalf("defaults = %+v, %v", cfg, err)
	}

	cfg, err = loadConfig(env(map[string]string{"QUEUE_CAPACITY": "5", "LEASE_TTL": "1s"}))
	if err != nil || cfg.QueueCapacity != 5 || cfg.LeaseTTL != time.Second {
		t.Fatalf("overrides = %+v, %v", cfg, err)
	}

	for name, bad := range map[string]string{"QUEUE_CAPACITY": "lots", "LEASE_TTL": "-1s", "LISTEN_ADDR": "8080", "GRPC_ADDR": "9090"} {
		if _, err := loadConfig(env(map[string]string{name: bad})); err == nil {
			t.Errorf("%s=%q was accepted", name, bad)
		}
	}
}

// syncBuffer lets the server goroutines write logs while the test reads them.
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

// startServer runs the service on a free port and returns its base URL, its
// logs, a function that stops it, and a channel with run's result.
func startServer(t *testing.T, extra map[string]string) (string, *syncBuffer, context.CancelFunc, <-chan error) {
	t.Helper()
	vars := map[string]string{"LISTEN_ADDR": "127.0.0.1:0", "GRPC_ADDR": "127.0.0.1:0"}
	for k, v := range extra {
		vars[k] = v
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	logs := &syncBuffer{}
	addr := make(chan string, 1)
	done := make(chan error, 1)
	go func() { done <- run(ctx, env(vars), logs, func(a string) { addr <- a }) }()
	return "http://" + <-addr, logs, cancel, done
}

func post(t *testing.T, url, body string) *http.Response {
	t.Helper()
	resp, err := http.Post(url, "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("POST %s: %v", url, err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func state(t *testing.T, url string) string {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	var job struct{ State string }
	_ = json.NewDecoder(resp.Body).Decode(&job)
	return job.State
}

// The control plane runs nothing itself: with no worker, a job waits.
func TestJobsWaitForAWorker(t *testing.T) {
	base, _, _, _ := startServer(t, nil)
	if resp := post(t, base+"/jobs", `{"description":"resize"}`); resp.StatusCode != http.StatusCreated {
		t.Fatalf("create = %d", resp.StatusCode)
	}
	time.Sleep(100 * time.Millisecond)
	if s := state(t, base+"/jobs/1"); s != "queued" {
		t.Fatalf("state = %q, want queued: there are no workers", s)
	}
	if resp := post(t, base+"/jobs/1/cancel", ""); resp.StatusCode != http.StatusOK {
		t.Fatalf("cancel = %d, want 200", resp.StatusCode)
	}
	if s := state(t, base+"/jobs/1"); s != "cancelled" {
		t.Fatalf("state = %q, want cancelled", s)
	}
}

func TestShutdownIsPrompt(t *testing.T) {
	_, logs, stop, done := startServer(t, nil)
	stop()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("run didn't return after shutdown")
	}
	if !strings.Contains(logs.String(), `"msg":"stopped"`) {
		t.Fatalf("no stopped line in the log:\n%s", logs)
	}
}

func TestRunFailsOnBadConfig(t *testing.T) {
	err := run(context.Background(), env(map[string]string{"LEASE_TTL": "soon"}), io.Discard, nil)
	if err == nil || !strings.Contains(err.Error(), "LEASE_TTL") {
		t.Fatalf("error = %v, want a LEASE_TTL config error", err)
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l . | grep -v ^bin/)" && go vet ./... && go test -race -count=1 ./... -->

### Step 8: The worker

The data plane is a small program. Create `cmd/worker/main.go`:

<!-- file: cmd/worker/main.go -->
~~~go
// Command worker runs Switchyard's jobs: the data plane. It registers with
// the control plane, then repeats: lease a job, run it while sending
// heartbeats, report it complete. It holds one job at a time, and keeps no
// state that matters: kill it at any moment, and the control plane hands
// its job to another worker.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	"switchyard/internal/chaos"
	"switchyard/internal/grpcapi/workersv1"
	"switchyard/internal/jobs"
	"switchyard/internal/retry"
)

var (
	errStopped   = errors.New("the control plane said stop")
	errGraceOver = errors.New("shutdown grace period over")
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type config struct {
	ControlPlane  string
	Name          string
	ShutdownGrace time.Duration
	FailRate      float64
}

func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{ControlPlane: "127.0.0.1:9090", Name: "worker", ShutdownGrace: 10 * time.Second}
	if v := getenv("CONTROL_PLANE"); v != "" {
		cfg.ControlPlane = v
	}
	if v := getenv("WORKER_NAME"); v != "" {
		cfg.Name = v
	}
	if v := getenv("SHUTDOWN_GRACE"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			return config{}, fmt.Errorf("SHUTDOWN_GRACE must be a positive duration such as 10s, got %q", v)
		}
		cfg.ShutdownGrace = d
	}
	if v := getenv("FAIL_RATE"); v != "" {
		rate, err := strconv.ParseFloat(v, 64)
		if err != nil || rate < 0 || rate >= 1 {
			return config{}, fmt.Errorf("FAIL_RATE must be a fraction from 0 up to (not including) 1, got %q", v)
		}
		cfg.FailRate = rate
	}
	return cfg, nil
}

type worker struct {
	cfg       config
	client    workersv1.WorkersClient
	log       *slog.Logger
	id        string
	heartbeat time.Duration
	retries   retry.Policy // for calls to the control plane
}

// run works until ctx is cancelled, then finishes the job it holds (within
// the grace period) and returns.
func run(ctx context.Context, getenv func(string) string, stdout io.Writer) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	conn, err := grpc.NewClient(cfg.ControlPlane, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	defer conn.Close()
	w := &worker{
		cfg:     cfg,
		client:  workersv1.NewWorkersClient(conn),
		log:     slog.New(slog.NewJSONHandler(stdout, nil)),
		retries: retry.Policy{Attempts: 8, Base: 100 * time.Millisecond, Max: 2 * time.Second},
	}
	w.loop(ctx)
	w.log.Info("stopped", "worker", w.id)
	return nil
}

func (w *worker) loop(ctx context.Context) {
	for ctx.Err() == nil {
		if w.id == "" {
			if err := w.register(ctx); err != nil {
				continue // ctx is done, or the control plane is still away: try again
			}
		}
		var lease *workersv1.LeaseResponse
		err := w.retries.Do(ctx, func(ctx context.Context) error {
			callCtx, cancel := context.WithTimeout(ctx, 7*time.Second)
			defer cancel()
			resp, err := w.client.Lease(callCtx, &workersv1.LeaseRequest{WorkerId: w.id, WaitMs: 1000})
			if status.Code(err) == codes.NotFound {
				return retry.Stop(err) // forgotten: register again
			}
			lease = resp
			return err
		})
		switch {
		case status.Code(err) == codes.NotFound:
			w.log.Warn("the control plane forgot this worker; registering again", "worker", w.id)
			w.id = ""
		case err != nil:
			if ctx.Err() == nil {
				w.log.Warn("lease failed", "error", err)
			}
		case lease.GetGranted():
			w.runJob(ctx, lease)
		}
	}
}

func (w *worker) register(ctx context.Context) error {
	return w.retries.Do(ctx, func(ctx context.Context) error {
		callCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		resp, err := w.client.Register(callCtx, &workersv1.RegisterRequest{Name: w.cfg.Name})
		if err != nil {
			return err
		}
		w.id, w.heartbeat = resp.GetWorkerId(), time.Duration(resp.GetHeartbeatMs())*time.Millisecond
		w.log.Info("registered", "worker", w.id, "heartbeat", w.heartbeat.String())
		return nil
	})
}

// runJob runs one leased job. While it runs, a heartbeat keeps the lease
// alive and listens for "stop". If ctx is cancelled (SIGTERM), the job
// carries on for up to the grace period.
func (w *worker) runJob(ctx context.Context, lease *workersv1.LeaseResponse) {
	job := jobs.Job{ID: jobs.ID(lease.GetJobId()), Duration: time.Duration(lease.GetDurationMs()) * time.Millisecond}
	log := w.log.With("worker", w.id, "job_id", job.ID, "token", lease.GetToken())
	log.Info("job started")

	jobCtx, stopJob := context.WithCancelCause(context.WithoutCancel(ctx))
	defer stopJob(nil)
	done := make(chan struct{})
	var helpers sync.WaitGroup
	helpers.Add(2)
	go func() {
		defer helpers.Done()
		w.heartbeats(jobCtx, done, lease, stopJob)
	}()
	go func() {
		defer helpers.Done()
		select {
		case <-done:
		case <-ctx.Done():
			grace := time.NewTimer(w.cfg.ShutdownGrace)
			defer grace.Stop()
			select {
			case <-done:
			case <-grace.C:
				stopJob(errGraceOver)
			}
		}
	}()

	workErr := jobs.Simulate(jobCtx, job)
	close(done)
	helpers.Wait()
	if workErr != nil {
		// Not reported: the control plane already knows (cancelled), or
		// will hand the job to someone else when the lease runs out.
		log.Info("job stopped", "reason", context.Cause(jobCtx).Error())
		return
	}

	report := jobs.WorkFunc(func(ctx context.Context, _ jobs.Job) error {
		callCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		_, err := w.client.Complete(callCtx, &workersv1.CompleteRequest{WorkerId: w.id, JobId: lease.GetJobId(), Token: lease.GetToken()})
		if status.Code(err) == codes.FailedPrecondition {
			return retry.Stop(err) // not ours any more: retrying can't help
		}
		return err
	})
	if w.cfg.FailRate > 0 {
		report = chaos.LoseResults(report, w.cfg.FailRate, rand.Float64)
	}
	reportCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), w.cfg.ShutdownGrace)
	defer cancel()
	if err := w.retries.Do(reportCtx, func(ctx context.Context) error { return report(ctx, job) }); err != nil {
		log.Warn("job done, report refused", "error", err)
		return
	}
	log.Info("job completed")
}

// heartbeats reports the held job every interval until done is closed. If
// the control plane says stop, it stops the job.
func (w *worker) heartbeats(ctx context.Context, done <-chan struct{}, lease *workersv1.LeaseResponse, stopJob context.CancelCauseFunc) {
	ticker := time.NewTicker(w.heartbeat)
	defer ticker.Stop()
	held := []*workersv1.Held{{JobId: lease.GetJobId(), Token: lease.GetToken()}}
	for {
		select {
		case <-done:
			return
		case <-ticker.C:
		}
		callCtx, cancel := context.WithTimeout(ctx, w.heartbeat)
		resp, err := w.client.Heartbeat(callCtx, &workersv1.HeartbeatRequest{WorkerId: w.id, Held: held})
		cancel()
		if status.Code(err) == codes.NotFound || (err == nil && len(resp.GetStopJobIds()) > 0) {
			stopJob(errStopped)
			return
		}
		// Any other error: the control plane is unreachable. Keep working;
		// the report at the end will find out whether the lease survived.
	}
}
~~~

How it holds a job:

- `loop` leases, runs, repeats. If the control plane forgot it (it was paused past its lease, say), the lease call answers `NotFound`, and the worker registers again under a new ID.
- `runJob` runs the work under `jobCtx`, which isn't cancelled by SIGTERM: on SIGTERM, the job gets up to `SHUTDOWN_GRACE` to finish, like lesson 12's requests. Two helper goroutines run next to it: the heartbeats, and the grace timer. Both end when `done` closes, and `runJob` waits for them, so no goroutine outlives its job.
- `context.WithCancelCause` records *why* a job stopped (`the control plane said stop`, or the grace period ran out), and `context.Cause` reads it back for the log.
- A stopped job is **not reported**. If it was cancelled, the control plane already knows. If the worker lost its lease, the job has been, or will be, handed to someone else.
- The report uses lesson 14's retry policy, and lesson 14's `chaos.LoseResults` when `FAIL_RATE` is set: this time it loses the *answer to `Complete`*, and the retry proves `Complete` is safe to repeat.

Its tests run a real coordinator and gRPC server on a free port, and the real `run`. Create `cmd/worker/main_test.go`:

<!-- file: cmd/worker/main_test.go -->
~~~go
package main

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"

	"switchyard/internal/coord"
	"switchyard/internal/grpcapi"
	"switchyard/internal/grpcapi/workersv1"
	"switchyard/internal/jobs"
	"switchyard/internal/ledger"
	"switchyard/internal/memstore"
	"switchyard/internal/queue"
)

// controlPlane is a real coordinator and gRPC server on a random port: the
// part of cmd/switchyard a worker talks to.
type controlPlane struct {
	addr    string
	svc     *jobs.Service
	effects *ledger.Ledger
}

func startControlPlane(t *testing.T, ttl time.Duration) controlPlane {
	t.Helper()
	q := queue.New(100)
	effects := ledger.New()
	svc := jobs.NewService(memstore.New(), jobs.WithDispatcher(q), jobs.WithEffects(effects))
	c := coord.New(svc, q.Next(), ttl, time.Now, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx, cancel := context.WithCancel(context.Background())
	go c.Run(ctx, ttl/6)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	workersv1.RegisterWorkersServer(server, grpcapi.NewWorkers(c))
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() {
		c.Close()
		server.Stop()
		cancel()
	})
	return controlPlane{addr: listener.Addr().String(), svc: svc, effects: effects}
}

// syncBuffer is a log that the worker writes while the test reads.
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

// startWorker runs a worker until the returned stop function is called;
// stop waits for run to return.
func startWorker(t *testing.T, addr string, extra map[string]string) (*syncBuffer, func()) {
	t.Helper()
	vars := map[string]string{"CONTROL_PLANE": addr, "SHUTDOWN_GRACE": "5s"}
	for k, v := range extra {
		vars[k] = v
	}
	logs := &syncBuffer{}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- run(ctx, func(k string) string { return vars[k] }, logs) }()
	var once sync.Once
	stop := func() {
		once.Do(func() {
			cancel()
			select {
			case err := <-done:
				if err != nil {
					t.Errorf("run: %v", err)
				}
			case <-time.After(10 * time.Second):
				t.Error("the worker didn't stop")
			}
		})
	}
	t.Cleanup(stop)
	return logs, stop
}

func waitForState(t *testing.T, svc *jobs.Service, id jobs.ID, want jobs.State) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if job, _ := svc.Get(context.Background(), id); job.State == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	job, _ := svc.Get(context.Background(), id)
	t.Fatalf("job %d is %s, want %s", id, job.State, want)
}

func waitForEffect(t *testing.T, effects *ledger.Ledger, id jobs.ID) {
	t.Helper()
	// The in-memory service publishes the state before recording its effect.
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if effects.EffectsFor(id) == 1 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("job %d has %d effects, want 1", id, effects.EffectsFor(id))
}

func TestWorkerRunsJobs(t *testing.T) {
	cp := startControlPlane(t, 3*time.Second)
	startWorker(t, cp.addr, nil)

	for range 3 {
		job, _ := cp.svc.Create(context.Background(), "resize", 20*time.Millisecond)
		waitForState(t, cp.svc, job.ID, jobs.StateCompleted)
		waitForEffect(t, cp.effects, job.ID)
	}
}

func TestWorkerStopsACancelledJob(t *testing.T) {
	cp := startControlPlane(t, 300*time.Millisecond) // heartbeats every 100 ms
	logs, _ := startWorker(t, cp.addr, nil)

	long, _ := cp.svc.Create(context.Background(), "long", 5*time.Second)
	waitForState(t, cp.svc, long.ID, jobs.StateRunning)
	if _, err := cp.svc.Cancel(context.Background(), long.ID); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	// The worker hears "stop" at its next heartbeat and is free again.
	next, _ := cp.svc.Create(context.Background(), "next", 10*time.Millisecond)
	waitForState(t, cp.svc, next.ID, jobs.StateCompleted)
	if !strings.Contains(logs.String(), "the control plane said stop") {
		t.Fatalf("log doesn't say why the job stopped:\n%s", logs)
	}
	if n := cp.effects.EffectsFor(long.ID); n != 0 {
		t.Fatalf("cancelled job has %d effects, want 0", n)
	}
}

func TestWorkerFinishesItsJobWhenStopped(t *testing.T) {
	cp := startControlPlane(t, 3*time.Second)
	_, stop := startWorker(t, cp.addr, nil)

	job, _ := cp.svc.Create(context.Background(), "resize", 300*time.Millisecond)
	waitForState(t, cp.svc, job.ID, jobs.StateRunning)
	stop() // SIGTERM in the middle of the job
	if got, _ := cp.svc.Get(context.Background(), job.ID); got.State != jobs.StateCompleted {
		t.Fatalf("after a graceful stop, job is %s, want completed", got.State)
	}
}

func TestLostRepliesDontRepeatTheEffect(t *testing.T) {
	cp := startControlPlane(t, 3*time.Second)
	startWorker(t, cp.addr, map[string]string{"FAIL_RATE": "0.5"})

	for range 10 {
		job, _ := cp.svc.Create(context.Background(), "charge", 0)
		waitForState(t, cp.svc, job.ID, jobs.StateCompleted)
		waitForEffect(t, cp.effects, job.ID)
	}
}

func TestBadConfig(t *testing.T) {
	err := run(context.Background(), func(k string) string {
		return map[string]string{"FAIL_RATE": "50%"}[k]
	}, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "FAIL_RATE") {
		t.Fatalf("error = %v, want one naming FAIL_RATE", err)
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l . | grep -v ^bin/)" && go vet ./... && go test -race -count=1 ./... -->

### Step 9: Kill a worker

Build both programs, start the control plane and one worker, `a`, and give it a 4-second job:

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && go build -o /tmp/worker ./cmd/worker
/tmp/switchyard > /tmp/switchyard.log &
sleep 0.5
WORKER_NAME=a /tmp/worker > /tmp/a.log & a=$!
sleep 0.5
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' \
  -d '{"description":"resize","duration_ms":4000}' > /dev/null
sleep 1
~~~

A second in, kill `a` the way a crash would, with no chance to clean up, and start worker `b`. Wait for the lease to run out and for `b` to do the job, then read what each process logged about job 1. `sed` drops the timestamps, to keep the lines short:

~~~bash
kill -KILL $a
WORKER_NAME=b /tmp/worker > /tmp/b.log & b=$!
sleep 9
grep -h '"job_id":1' /tmp/a.log /tmp/switchyard.log /tmp/b.log | sed 's/"time":"[^"]*",//'
curl -s http://127.0.0.1:8080/jobs/1; curl -s http://127.0.0.1:8080/effects/1
~~~

~~~text
{"level":"INFO","msg":"job started","worker":"a-1","job_id":1,"token":1}
{"level":"WARN","msg":"lease expired; job handed back","job_id":1,"worker":"a-1"}
{"level":"INFO","msg":"job started","worker":"b-2","job_id":1,"token":2}
{"level":"INFO","msg":"job completed","worker":"b-2","job_id":1,"token":2}
{"id":1,"state":"completed","description":"resize","duration_ms":4000,"created_at":"2026-11-20T05:22:47.563762235Z","updated_at":"2026-11-20T05:22:56.058785028Z"}
{"job_id":1,"effects":1}
~~~

Worker `a` started the job and was never heard from again. Nobody told the control plane `a` had died; its lease simply stopped being renewed, and the reconcile loop found it expired and handed the job back. Worker `b` ran it from the start, and completed it. The work ran one and a quarter times; the job has **one** effect.

### Step 10: Pause a worker

A paused process is worse than a dead one: it comes back. `kill -STOP` freezes a process the way a long garbage-collection pause or an overloaded virtual machine can. Stop `b`, start `c`, and give `c` a 2-second job. Freeze `c` half a second in, start `d`, and let `c` go again after 5 seconds:

~~~bash
kill -TERM $b
WORKER_NAME=c /tmp/worker > /tmp/c.log & c=$!
sleep 0.5
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' \
  -d '{"description":"thumbnail","duration_ms":2000}' > /dev/null
sleep 0.5
kill -STOP $c
WORKER_NAME=d /tmp/worker > /tmp/d.log & d=$!
sleep 5
kill -CONT $c
sleep 3
grep -h '"job_id":2' /tmp/c.log /tmp/switchyard.log /tmp/d.log | sed 's/"time":"[^"]*",//'
curl -s http://127.0.0.1:8080/effects/2
~~~

~~~text
{"level":"INFO","msg":"job started","worker":"c-3","job_id":2,"token":3}
{"level":"WARN","msg":"job done, report refused","worker":"c-3","job_id":2,"token":3,"error":"rpc error: code = FailedPrecondition desc = lease lost: the job is no longer yours"}
{"level":"WARN","msg":"lease expired; job handed back","job_id":2,"worker":"c-3"}
{"level":"INFO","msg":"job started","worker":"d-4","job_id":2,"token":4}
{"level":"INFO","msg":"job completed","worker":"d-4","job_id":2,"token":4}
{"job_id":2,"effects":1}
~~~

Read the tokens. Worker `c` held job 2 under one token. While it was frozen, its lease expired and `d` got the job under a new one. When `c` woke up, it had no idea any time had passed: it finished its work and reported, with its old token, and was refused. (Its log then shows it registering again: the control plane had forgotten it.) Without the token, `c`'s report would have been accepted, for a job another worker was still running.

### Step 11: Cancel a running job

~~~bash
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' \
  -d '{"description":"render","duration_ms":5000}' > /dev/null
sleep 0.5
curl -s -X POST http://127.0.0.1:8080/jobs/3/cancel; echo
sleep 1.5
grep -h '"job_id":3' /tmp/c.log /tmp/d.log | sed 's/"time":"[^"]*",//'
curl -s http://127.0.0.1:8080/effects/3
curl -s http://127.0.0.1:8080/metrics | grep -E '^(workers|leases|jobs_handed_back_total|effects_applied_total|go_goroutines) '
~~~

~~~text
{"id":3,"state":"cancelled","description":"render","duration_ms":5000,"created_at":"2026-11-20T05:23:06.678626959Z","updated_at":"2026-11-20T05:23:07.194080709Z"}
{"level":"INFO","msg":"job started","worker":"d-4","job_id":3,"token":5}
{"level":"INFO","msg":"job stopped","worker":"d-4","job_id":3,"token":5,"reason":"the control plane said stop"}
{"job_id":3,"effects":0}
effects_applied_total 2
go_goroutines 20
jobs_handed_back_total 2
leases 0
workers 2
~~~

The cancel answered at once; the worker heard "stop" at its next heartbeat, within a second, and dropped the job. No report, no effect. The metrics sum it up: two live workers, no leases held, two jobs handed back, two effects for two completed jobs.

Stop everything:

~~~bash
kill -TERM $c $d %1
~~~

## Break it

**Trust any report.** In `Complete`, stop checking the token: change `lease, ok := c.leases[job]` to `_, ok := c.leases[job]`, and `if !ok || lease.Token != token {` to `if !ok {`. Run the coordinator's tests:

~~~bash
go test ./internal/coord
~~~

~~~text
--- FAIL: TestExpiredLeaseIsHandedToAnotherWorker (0.00s)
    coord_test.go:142: stale Complete error = <nil>, want ErrLeaseLost
FAIL
FAIL	switchyard/internal/coord	0.047s
FAIL
~~~

The stale worker's report was accepted: the job was completed by a worker that no longer owned it, while another was still running it. (The effect still happened once; the compare-and-swap and the ledger key saw to that. But the job's record now says something untrue about who did the work and when, and the second worker's work was wasted.) Put the token back.

**No loop.** In `main.go`, replace `coordinator.Run(loops, cfg.LeaseTTL/6)` with `<-loops.Done()`, so the reconcile loop never runs, and repeat step 9:

~~~text
{"level":"INFO","msg":"job started","worker":"a-1","job_id":1,"token":1}
{"id":1,"state":"running","description":"resize","duration_ms":4000,"created_at":"2026-11-20T05:23:14.976184383Z","updated_at":"2026-11-20T05:23:14.976534117Z"}
{"job_id":1,"effects":0}
~~~

Nine seconds after worker `a` died, job 1 is still `running`, held by a lease that expired long ago, and it will stay that way forever. Every other part works: the lease expired, the workers are fine. Nothing *looked*. Put the loop back.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race ./...
~~~

Then run this module's gate. It builds your control plane and worker with the race detector, starts the control plane and four workers, sends 10,000 state changes from 32 clients at once (creates, repeats with the same idempotency key, cancels), kills workers with SIGKILL every second or two and pauses one past its lease, and then checks that everything converged. It uses ports 18080 and 19090, and takes about a minute:

~~~bash
bash ~/Nicholas-Engineering-Blueprint/2-core/01-go-runtime-and-reliable-services/gate/run.sh ~/blueprint/switchyard
~~~

~~~text
PASS  gofmt -l . lists nothing
PASS  go vet ./...
PASS  go test -race ./...
sending 10,000 state changes from 32 clients while workers are killed; this takes a minute or two
sent 10000 state changes in 1.8 s: 7131 creates, 1642 repeated with the same key, 1227 cancels (1003 accepted)
settled after 21.9 s: 7131 jobs: 6128 completed, 1003 cancelled, 0 failed
PASS  every request got an expected answer
PASS  a repeated request with the same key returned the same job
PASS  every job reached a final state (none lost, none stuck)
PASS  every job cancelled with 200 ended cancelled, never completed
PASS  every completed job has exactly one effect; every other job, none
      workers killed with SIGKILL: 16; one paused past its lease
      jobs handed back by the reconcile loop: 10
PASS  goroutines came back to the baseline (28 before, 28 after)
PASS  SIGTERM stopped the control plane and every worker within the grace period (2 s)
PASS  the race detector reported nothing

gate passed
~~~

<!-- run: bash "$BLUEPRINT_ROOT/2-core/01-go-runtime-and-reliable-services/gate/run.sh" . -->

Then answer: why can't the control plane tell a dead worker from a slow one? What does a fencing token protect against that a lease alone doesn't? Why is the reconcile loop level-triggered, and what would an edge-triggered one ("when a worker dies, requeue its jobs") miss? A job's work ran twice: why does it have one effect?

Read Martin Kleppmann, [*How to do distributed locking*](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html) (fencing tokens, and why a lock alone isn't enough); DDIA Ch. 8, *The Trouble with Distributed Systems*, the sections on process pauses and on knowledge, truth and lies; and the Kubernetes documentation's [*Controllers*](https://kubernetes.io/docs/concepts/architecture/controller/). Carry this question in: which of Switchyard's guarantees would survive the control plane itself being killed?

None of them, yet: everything lives in one control plane's memory. Core 03 puts jobs in PostgreSQL, and core 07 makes the control plane itself replicated. But the shape is now the one real systems use: a control plane that decides, a data plane that works, leases, tokens, and a loop that keeps them honest.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| Workers log `lease failed ... connection refused` | The control plane isn't running, or listens elsewhere | Start it first; `CONTROL_PLANE` must match its `GRPC_ADDR` |
| A job stays `running` after its worker died | The reconcile loop isn't running | Check that `run` starts `coordinator.Run` |
| A job stays `queued` with workers running | The workers aren't connected | Read the worker's log: it should say `registered` |
| A worker logs `report refused ... lease lost` | It was paused or cut off past its lease; the job went to another worker | Expected: that's the fencing token working |
| Every job is handed back, again and again | Heartbeats don't arrive within the lease TTL | Check the worker's heartbeat loop; or the TTL is too short for your machine (`LEASE_TTL`) |
| The gate says `Something is already listening on 127.0.0.1:18080` | A Switchyard from an earlier run is still up | `pkill -x switchyard; pkill -x worker` |
| The gate's goroutine check fails | Something starts a goroutine per request, call or job that never ends | Find what starts goroutines without a way to stop them; a goroutine profile (`/debug/pprof`, core 06) shows where they wait |
