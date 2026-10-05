# Phase 2 teaching: connect services

Phase 1's service runs a job *inside the HTTP request*: the caller waits the whole time. If the job takes a minute, the request takes a minute; if the process dies, the work dies with it. Real systems separate **accepting** work from **doing** it. The API records the job and answers at once, a queue holds the work, and workers, often in other processes on other machines, do it and report back.

The moment work crosses a process boundary, everything gets harder:
- messages can be lost, duplicated, or arrive out of order;
- the broker can be down;
- retries can turn a small outage into a flood;
- every message format becomes a contract with code you don't control.

This phase builds that split one step at a time, and makes each failure happen on purpose.

**The goal:** jobs are accepted over HTTP and queued, then run by workers in a separate process connected through RabbitMQ. They complete **exactly once in effect**, even when a worker is killed mid-job. The service pushes back under overload, retries transient failures with backoff, fails fast when the broker is down, and also speaks gRPC.

**Time:** about 4 weeks. **Before you start:** finish Phase 1 and the Python Bridge. Install Docker (Docker Desktop, or Docker Engine with the Compose plugin) and check that `docker run --rm hello-world` works.

## How this guide works

The same as Phase 1: you type everything into your `practice/` folder, the first appearance of a file shows the whole file, and later changes are exact edits. Each step ends with tests you run. CI rebuilds the code from this guide, so every step is known to work.

| Step | What you add |
|---|---|
| 1 | A bounded queue and a worker pool: accept now, run later, and push back when full |
| 2 | Messages and a bus: commands, events, envelopes, at-least-once delivery, an event-driven worker |
| 3 | RabbitMQ: a real broker, and the API and worker as separate processes |
| 4 | Idempotency: safe client retries, duplicate-proof consumers, and killing a worker mid-job |
| 5 | Retries with backoff and jitter, dead letters, message versioning, and a circuit breaker |
| 6 | gRPC and Protocol Buffers alongside HTTP and JSON |
| 7 | Look at the wire: sockets, TCP handshakes and packets (run locally) |

## Setup

Start from your finished Phase 1 code. From the repository root:

~~~bash
cd lessons/02-connected-services
cp -r ../01-reliable-service/practice practice
cd practice
go test ./...
~~~

`cp -r` copies a folder and everything in it. Everything should pass before you change anything. That's your baseline.

<!-- continue: ../01-reliable-service/TEACHING.md -->

---

## Step 1: Accept now, run later

**The problem.** `POST /jobs/{id}/run` holds the HTTP request open for the whole job. A caller with a 30-second timeout can't run a 60-second job. A thousand callers mean a thousand goroutines doing work at once, with no limit. And there's no way to say "not now, I'm full".

**New ideas.**

- **Synchronous vs asynchronous.** Synchronous means the caller waits for the result. Asynchronous means the service *accepts* the work, answers immediately, and does it later; the caller checks back with `GET /jobs/{id}`.
- The **producer/consumer** pattern: the API (the producer) puts work on a **queue**; **workers** (the consumers) take it off and do it. A **worker pool** is a fixed number of workers, so the amount of work in progress has a limit you chose.
- A **bounded queue** has a fixed capacity. That's not a weakness. An unbounded queue doesn't remove overload; it moves it into memory, where it grows silently until the process is killed.
- **Backpressure** means telling the producer to slow down when the consumer can't keep up. Here, a full queue makes `POST /jobs` answer **503 Service Unavailable** with a `Retry-After` header: "I'm overloaded; try again in a second." (429 Too Many Requests is a different signal: one *client* is over its own limit.)
- **Little's law**: the average number of items in a system = arrival rate × average time in the system (L = λW). With 4 workers and 1-second jobs, at most 4 jobs per second get done. If 10 a second arrive, the queue grows by 6 a second, and a 100-slot queue is full after about 17 seconds. Nothing about the code can change that arithmetic; only more workers, faster jobs or fewer arrivals can.
- **Saturation**, the fourth golden signal from Phase 1, now has a number: **queue depth**.

The new contract. `POST /jobs/{id}/run` disappears, because workers run jobs now.

| Request | Response |
|---|---|
| `POST /jobs` | `201` with the job `queued`. A worker picks it up shortly |
| `POST /jobs` when the queue is full | `503`, `Retry-After: 1`, `{"error":"the service is busy; retry later"}`. The job is recorded as `failed` with reason `not dispatched: queue is full` |
| `GET /jobs/{id}` | The job, whose state moves `queued → running → completed` (or `failed`) on its own |

### A queued job may now fail without running

A job rejected before any worker sees it goes straight from `queued` to `failed`. In `internal/jobs/job.go`, change:

<!-- edit: internal/jobs/job.go -->
~~~go
// allowed lists every legal state change. Anything not listed is refused.
var allowed = map[State][]State{
	StateQueued:  {StateRunning},
~~~

to:

~~~go
// allowed lists every legal state change. Anything not listed is refused.
// A queued job may fail without running: it can be rejected before any
// worker picks it up.
var allowed = map[State][]State{
	StateQueued:  {StateRunning, StateFailed},
~~~

The domain test that said this was illegal must change too. That's a deliberate change to the rules, and the test records it. In `internal/jobs/job_test.go`, change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
		{StateQueued, StateFailed, false},
~~~

to:

~~~go
		{StateQueued, StateFailed, true},
~~~

### A port for "send this job to be run"

The service shouldn't know whether jobs go to an in-process queue, RabbitMQ or anything else. It needs a **port**, just as storage had `Repository`. In `internal/jobs/service.go`, make these changes.

Add the new error next to the existing one. Change:

<!-- edit: internal/jobs/service.go -->
~~~go
// ErrWorkFailed wraps whatever stopped a job's work.
var ErrWorkFailed = errors.New("job work failed")
~~~

to:

~~~go
var (
	// ErrWorkFailed wraps whatever stopped a job's work.
	ErrWorkFailed = errors.New("job work failed")

	// ErrDispatchFailed means the job was stored but could not be handed to
	// a worker. The job is marked failed so it never sits queued forever.
	ErrDispatchFailed = errors.New("job could not be dispatched")
)
~~~

Add the port below `WorkFunc`. Change:

<!-- edit: internal/jobs/service.go -->
~~~go
type WorkFunc func(ctx context.Context, job Job) error
~~~

to:

~~~go
type WorkFunc func(ctx context.Context, job Job) error

// Dispatcher hands a stored job to whatever will run it: an in-process
// queue now, a message broker later.
type Dispatcher interface {
	Dispatch(ctx context.Context, job Job) error
}
~~~

Give `Service` a dispatcher and an option to set it. Change:

<!-- edit: internal/jobs/service.go -->
~~~go
type Service struct {
	repo Repository
	now  func() time.Time
	work WorkFunc
}
~~~

to:

~~~go
type Service struct {
	repo     Repository
	dispatch Dispatcher
	now      func() time.Time
	work     WorkFunc
}
~~~

and change:

<!-- edit: internal/jobs/service.go -->
~~~go
func WithWork(work WorkFunc) Option {
	return func(s *Service) { s.work = work }
}
~~~

to:

~~~go
func WithWork(work WorkFunc) Option {
	return func(s *Service) { s.work = work }
}

// WithDispatcher sends every created job to d. Without one, jobs are only
// stored.
func WithDispatcher(d Dispatcher) Option {
	return func(s *Service) { s.dispatch = d }
}
~~~

Now `Create` stores the job **and** dispatches it. Change:

<!-- edit: internal/jobs/service.go -->
~~~go
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
~~~

to:

~~~go
// Create stores a queued job and dispatches it. Storing and dispatching are
// two separate steps, so they can't be made atomic here: if dispatch fails,
// Create marks the stored job failed. If the process crashes between the two
// steps, the job stays queued forever. Phase 3 removes that gap with a
// transactional outbox.
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
~~~

Read that comment carefully, because it names this phase's most important flaw. Storing a job and dispatching it are **two separate writes to two separate systems**: the map and the queue now, a database and a broker later. No code can make two independent systems change together, atomically. If dispatch fails with an error, `Create` compensates by marking the job failed. But if the *process crashes* between the two writes, there's no code left running to compensate, and the job sits `queued` forever. This is the **dual-write problem**, and Phase 3 solves it with the transactional outbox.

Test the two outcomes with two tiny fakes. Add these at the end of `internal/jobs/service_test.go`:

<!-- append: internal/jobs/service_test.go -->
~~~go
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

<!-- run: go test ./internal/jobs/... -->

### The queue and its workers

Create `internal/queue/queue.go`:

<!-- file: internal/queue/queue.go -->
~~~go
// Package queue is a bounded, in-process work queue served by a pool of
// worker goroutines.
package queue

import (
	"context"
	"errors"
	"sync"

	"kestrel/internal/jobs"
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
	default:
		return ErrFull
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
~~~

How it works:

- The queue **is** a buffered channel. A channel of capacity N holds N items without a reader; `len(ch)` is how many are waiting right now.
- `Dispatch` uses `select` with a `default` case. That's a **non-blocking send**: if the channel has room, the send happens; if not, `default` runs at once and returns `ErrFull`. Without `default`, a full channel would block the HTTP handler until a slot freed up, hiding the overload from the caller.
- `Queue` satisfies `jobs.Dispatcher` (it has the right `Dispatch` method), so the service can use it without knowing what it is.
- `Serve` starts the worker goroutines and waits for all of them, using a `WaitGroup` as in Phase 1's tests.
- The `ctx.Err()` check before the `select` is there because of a real bug. *Break it* below shows what goes wrong without it.

Create `internal/queue/queue_test.go`:

<!-- file: internal/queue/queue_test.go -->
~~~go
package queue

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"kestrel/internal/jobs"
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

func TestWorkersRunJobsInParallel(t *testing.T) {
	q := New(10)
	for id := range 4 {
		_ = q.Dispatch(context.Background(), jobs.Job{ID: jobs.ID(id + 1)})
	}

	var done sync.WaitGroup
	done.Add(4)
	handle := func(jobs.ID) {
		time.Sleep(100 * time.Millisecond)
		done.Done()
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go q.Serve(ctx, 4, handle)

	start := time.Now()
	done.Wait()
	if elapsed := time.Since(start); elapsed > 300*time.Millisecond {
		t.Fatalf("4 jobs of 100ms on 4 workers took %v; they should overlap", elapsed)
	}
}

func TestServeStopsTakingJobsButFinishesTheCurrentOne(t *testing.T) {
	q := New(10)
	for id := range 3 {
		_ = q.Dispatch(context.Background(), jobs.Job{ID: jobs.ID(id + 1)})
	}

	ctx, cancel := context.WithCancel(context.Background())
	var finished atomic.Int32
	started := make(chan struct{}, 3)
	handle := func(jobs.ID) {
		started <- struct{}{}
		time.Sleep(100 * time.Millisecond)
		finished.Add(1)
	}

	served := make(chan struct{})
	go func() {
		q.Serve(ctx, 1, handle)
		close(served)
	}()
	<-started
	cancel()
	<-served

	if got := finished.Load(); got != 1 {
		t.Fatalf("finished %d jobs, want exactly the 1 in progress", got)
	}
	if q.Len() != 2 {
		t.Fatalf("Len = %d, want the 2 jobs never started", q.Len())
	}
}
~~~

`atomic.Int32` is a counter that many goroutines can update safely without a mutex. `Add` and `Load` are each one indivisible step. Use it for simple counters; a mutex is for anything bigger.

<!-- run: go test -race -count=3 ./internal/queue/... -->

**Break it: Go's `select` is random.** Delete the `if ctx.Err() != nil { return }` check in `Serve`, then run the last test many times: `go test -race -count=20 ./internal/queue/`. It fails some of the time:

~~~text
--- FAIL: TestServeStopsTakingJobsButFinishesTheCurrentOne (0.21s)
    queue_test.go:84: finished 2 jobs, want exactly the 1 in progress
~~~

After `cancel()`, two `select` cases are ready at once: `ctx.Done()` is closed **and** jobs are waiting. When several cases are ready, Go chooses **at random**, deliberately, so no case can starve the others. Half the time, a "stopped" worker grabs one more job. A test run once would usually pass, which is why `-count=20` matters for concurrent code. Restore the check: it runs before the `select`, so cancellation wins whenever it has already happened.

### The API answers 503 when the queue is full

In `internal/httpapi/handler.go`, the handlers no longer run jobs. Change the interface from:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	Get(ctx context.Context, id jobs.ID) (jobs.Job, error)
	Run(ctx context.Context, id jobs.ID) (jobs.Job, error)
}
~~~

to:

~~~go
	Get(ctx context.Context, id jobs.ID) (jobs.Job, error)
}
~~~

Remove the route. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	mux.HandleFunc("GET /jobs/{id}", h.getJob)
	mux.HandleFunc("POST /jobs/{id}/run", h.runJob)
~~~

to:

~~~go
	mux.HandleFunc("GET /jobs/{id}", h.getJob)
~~~

Delete the whole `runJob` handler. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
func (h *handlers) runJob(w http.ResponseWriter, r *http.Request) {
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	job, err := h.jobs.Run(r.Context(), id)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, toResponse(job))
	case errors.Is(err, context.DeadlineExceeded):
		writeJSON(w, http.StatusGatewayTimeout, toResponse(job))
	case errors.Is(err, context.Canceled):
		h.logger.Info("client went away during run", "job_id", id)
	default:
		h.writeDomainError(w, r, err)
	}
}

~~~

to nothing:

~~~go
~~~

And teach `createJob` the overload case. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	job, err := h.jobs.Create(r.Context(), req.Description, time.Duration(req.DurationMS)*time.Millisecond)
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
~~~

to:

~~~go
	job, err := h.jobs.Create(r.Context(), req.Description, time.Duration(req.DurationMS)*time.Millisecond)
	if errors.Is(err, jobs.ErrDispatchFailed) {
		// Overloaded: tell the caller to come back, rather than queueing
		// without limit. The job is recorded as failed.
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusServiceUnavailable, "the service is busy; retry later")
		return
	}
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
~~~

The queue depth is a metric, and it belongs on the same `/metrics` page. In `internal/httpapi/metrics.go`, change:

<!-- edit: internal/httpapi/metrics.go -->
~~~go
// Handler serves the metrics in Prometheus's text format.
~~~

to:

~~~go
// MustRegister adds more collectors, such as a queue-depth gauge, to the
// same registry the /metrics endpoint serves.
func (m *Metrics) MustRegister(collectors ...prometheus.Collector) {
	m.registry.MustRegister(collectors...)
}

// Handler serves the metrics in Prometheus's text format.
~~~

Now the handler tests. The two tests of `/run` go. Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
func TestRunCompletesThenConflicts(t *testing.T) {
	h := newTestHandler()
	do(t, h, http.MethodPost, "/jobs", `{"description":"resize","duration_ms":10}`)

	first := do(t, h, http.MethodPost, "/jobs/1/run", "")
	if first.Code != http.StatusOK || decode(t, first).State != "completed" {
		t.Fatalf("first run = %d %s", first.Code, first.Body)
	}
	second := do(t, h, http.MethodPost, "/jobs/1/run", "")
	if second.Code != http.StatusConflict {
		t.Fatalf("second run = %d, want 409", second.Code)
	}
}

func TestRunPastDeadlineReturns504AndFailsJob(t *testing.T) {
	h := newTestHandler(WithRequestTimeout(50 * time.Millisecond))
	do(t, h, http.MethodPost, "/jobs", `{"description":"slow","duration_ms":2000}`)

	start := time.Now()
	response := do(t, h, http.MethodPost, "/jobs/1/run", "")
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("run took %v; the deadline should have stopped it near 50ms", elapsed)
	}
	if response.Code != http.StatusGatewayTimeout {
		t.Fatalf("status = %d, want 504", response.Code)
	}
	if job := decode(t, response); job.State != "failed" || job.FailureReason != "deadline exceeded" {
		t.Fatalf("job = %+v", job)
	}
	if job := decode(t, do(t, h, http.MethodGet, "/jobs/1", "")); job.State != "failed" {
		t.Fatalf("stored state = %s, want failed", job.State)
	}
}

~~~

to nothing:

~~~go
~~~

The file no longer uses `time`, and the new test needs `errors`. Change the imports from:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
~~~

to:

~~~go
import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
~~~

And add the overload test at the end of the file:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
type busyDispatcher struct{}

func (busyDispatcher) Dispatch(context.Context, jobs.Job) error { return errors.New("queue is full") }

func TestCreateWhenBusyReturns503AndRecordsFailure(t *testing.T) {
	svc := jobs.NewService(memstore.New(), jobs.WithDispatcher(busyDispatcher{}))
	h := NewHandler(svc)

	response := do(t, h, http.MethodPost, "/jobs", `{"description":"resize"}`)
	if response.Code != http.StatusServiceUnavailable || response.Header().Get("Retry-After") != "1" {
		t.Fatalf("got %d with Retry-After %q, want 503 and 1", response.Code, response.Header().Get("Retry-After"))
	}
	if job := decode(t, do(t, h, http.MethodGet, "/jobs/1", "")); job.State != "failed" {
		t.Fatalf("stored state = %s, want failed", job.State)
	}
}
~~~

<!-- run: go vet ./internal/... && go test -race ./internal/... -->

### Wiring it together: two contexts for a clean stop

`main` now builds the queue, starts the workers, and has a harder shutdown problem: there are requests in flight **and** jobs in flight. Shutdown happens in order:

1. Stop accepting HTTP requests, so no new jobs arrive.
2. Tell the workers to stop *taking* jobs, but let each one finish the job it holds.
3. If the grace period runs out first, *interrupt* the running jobs. They're recorded as `failed` with reason `cancelled`, never left `running`.

That needs **two** contexts: one that means "stop taking" and one that means "stop running". Replace `cmd/api/main.go`:

<!-- file: cmd/api/main.go -->
~~~go
// Command api runs the KESTREL jobs service: an HTTP API plus a pool of
// workers that run jobs from an in-process queue.
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
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"kestrel/internal/httpapi"
	"kestrel/internal/jobs"
	"kestrel/internal/memstore"
	"kestrel/internal/queue"
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
	RequestTimeout time.Duration
	ShutdownGrace  time.Duration
	Workers        int
	QueueCapacity  int
	JobTimeout     time.Duration
}

func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{
		ListenAddr:     "127.0.0.1:8080",
		RequestTimeout: 2 * time.Second,
		ShutdownGrace:  10 * time.Second,
		Workers:        4,
		QueueCapacity:  100,
		JobTimeout:     10 * time.Second,
	}
	if v := getenv("LISTEN_ADDR"); v != "" {
		if _, _, err := net.SplitHostPort(v); err != nil {
			return config{}, fmt.Errorf("LISTEN_ADDR must look like host:port, got %q", v)
		}
		cfg.ListenAddr = v
	}
	var err error
	if cfg.RequestTimeout, err = durationFromEnv(getenv, "REQUEST_TIMEOUT", cfg.RequestTimeout); err != nil {
		return config{}, err
	}
	if cfg.ShutdownGrace, err = durationFromEnv(getenv, "SHUTDOWN_GRACE", cfg.ShutdownGrace); err != nil {
		return config{}, err
	}
	if cfg.JobTimeout, err = durationFromEnv(getenv, "JOB_TIMEOUT", cfg.JobTimeout); err != nil {
		return config{}, err
	}
	if cfg.Workers, err = positiveIntFromEnv(getenv, "WORKERS", cfg.Workers); err != nil {
		return config{}, err
	}
	if cfg.QueueCapacity, err = positiveIntFromEnv(getenv, "QUEUE_CAPACITY", cfg.QueueCapacity); err != nil {
		return config{}, err
	}
	return cfg, nil
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

// run starts the API and the workers, blocks until ctx is cancelled, then
// shuts both down gracefully.
func run(ctx context.Context, getenv func(string) string, stdout io.Writer, ready func(addr string)) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	work := queue.New(cfg.QueueCapacity)
	service := jobs.NewService(memstore.New(), jobs.WithDispatcher(work))

	metrics := httpapi.NewMetrics()
	metrics.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "jobs_queue_depth",
		Help: "Jobs waiting for a worker.",
	}, func() float64 { return float64(work.Len()) }))

	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
	)
	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      cfg.RequestTimeout + 5*time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Two contexts control the workers. Cancelling stopTaking makes them
	// stop picking up new jobs. Cancelling stopRunning interrupts the jobs
	// they are running; that only happens if the grace period runs out.
	stopTaking, cancelTaking := context.WithCancel(context.Background())
	defer cancelTaking()
	stopRunning, cancelRunning := context.WithCancel(context.Background())
	defer cancelRunning()

	runJob := func(id jobs.ID) {
		jobCtx, cancel := context.WithTimeout(stopRunning, cfg.JobTimeout)
		defer cancel()
		job, err := service.Run(jobCtx, id)
		logger.Info("job finished", "job_id", id, "state", job.State, "error", errText(err))
	}
	workersDone := make(chan struct{})
	go func() {
		work.Serve(stopTaking, cfg.Workers, runJob)
		close(workersDone)
	}()

	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}
	logger.Info("listening", "addr", listener.Addr().String(), "workers", cfg.Workers)
	if ready != nil {
		ready(listener.Addr().String())
	}

	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(listener) }()

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}

	logger.Info("shutting down", "grace", cfg.ShutdownGrace.String())
	deadline := time.Now().Add(cfg.ShutdownGrace)
	shutdownCtx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()

	// 1. Stop accepting requests, so no new jobs arrive.
	if err := server.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return err
	}

	// 2. Let workers finish the jobs they hold, until the grace period ends.
	cancelTaking()
	select {
	case <-workersDone:
	case <-shutdownCtx.Done():
		// 3. Out of time: interrupt the running jobs. They are recorded
		// as failed with reason "cancelled", never left "running".
		logger.Warn("grace period over; cancelling running jobs")
		cancelRunning()
		<-workersDone
	}
	logger.Info("stopped", "jobs_left_in_queue", work.Len())
	return nil
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
~~~

What's new:

- Three new settings: `WORKERS`, `QUEUE_CAPACITY` and `JOB_TIMEOUT`. `positiveIntFromEnv` is `durationFromEnv`'s twin for whole numbers; `strconv.Atoi` turns text into an `int`.
- `prometheus.NewGaugeFunc` is a **gauge**, a metric that goes up *and* down, whose value is computed by calling a function each time Prometheus scrapes. That's ideal for "how many are waiting right now".
- Each job gets its own deadline, `JOB_TIMEOUT`, derived from `stopRunning`. The HTTP request's deadline no longer applies: the request ended long ago.
- `Service.Run` is the same Phase 1 code. Only its caller changed, from an HTTP handler to a worker. The layering paid off: the use case didn't care who called it.
- Jobs still waiting in the queue at exit are **lost**: the queue lives in this process's memory. `jobs_left_in_queue` in the final log line says how many. Step 3 fixes that with a durable broker.

Replace `cmd/api/main_test.go` with tests for the new behaviour:

<!-- file: cmd/api/main_test.go -->
~~~go
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
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
	if err != nil || cfg.Workers != 4 || cfg.QueueCapacity != 100 || cfg.JobTimeout != 10*time.Second {
		t.Fatalf("defaults = %+v, %v", cfg, err)
	}

	cfg, err = loadConfig(env(map[string]string{"WORKERS": "8", "QUEUE_CAPACITY": "5", "JOB_TIMEOUT": "1s"}))
	if err != nil || cfg.Workers != 8 || cfg.QueueCapacity != 5 || cfg.JobTimeout != time.Second {
		t.Fatalf("overrides = %+v, %v", cfg, err)
	}

	for name, bad := range map[string]string{"WORKERS": "0", "QUEUE_CAPACITY": "lots", "JOB_TIMEOUT": "-1s", "LISTEN_ADDR": "8080"} {
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
	vars := map[string]string{"LISTEN_ADDR": "127.0.0.1:0"}
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

func createJob(t *testing.T, base string, durationMS int) {
	t.Helper()
	body := fmt.Sprintf(`{"description":"test","duration_ms":%d}`, durationMS)
	resp, err := http.Post(base+"/jobs", "application/json", strings.NewReader(body))
	if err != nil || resp.StatusCode != http.StatusCreated {
		t.Fatalf("create: %v %v", resp, err)
	}
	resp.Body.Close()
}

func waitForState(t *testing.T, base, want string) {
	t.Helper()
	for range 100 {
		resp, err := http.Get(base + "/jobs/1")
		if err == nil {
			var job struct{ State string }
			_ = json.NewDecoder(resp.Body).Decode(&job)
			resp.Body.Close()
			if job.State == want {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("job 1 never reached state %q", want)
}

func TestWorkersRunCreatedJobs(t *testing.T) {
	base, _, _, _ := startServer(t, nil)
	createJob(t, base, 50)
	waitForState(t, base, "completed")
}

func TestShutdownLetsRunningJobFinish(t *testing.T) {
	base, logs, stop, done := startServer(t, nil)
	createJob(t, base, 300)
	waitForState(t, base, "running")

	stop()
	if err := <-done; err != nil {
		t.Fatalf("run returned %v", err)
	}
	if !strings.Contains(logs.String(), `"msg":"job finished","job_id":1,"state":"completed"`) {
		t.Fatalf("job 1 did not complete during shutdown:\n%s", logs.String())
	}
}

func TestShutdownCancelsJobsThatOutlastTheGrace(t *testing.T) {
	base, logs, stop, done := startServer(t, map[string]string{"SHUTDOWN_GRACE": "100ms"})
	createJob(t, base, 5000)
	waitForState(t, base, "running")

	start := time.Now()
	stop()
	if err := <-done; err != nil {
		t.Fatalf("run returned %v", err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("shutdown took %v; the grace period is 100ms", elapsed)
	}
	for _, want := range []string{`"grace period over; cancelling running jobs"`, `"job_id":1,"state":"failed"`} {
		if !strings.Contains(logs.String(), want) {
			t.Errorf("logs missing %s:\n%s", want, logs.String())
		}
	}
}

func TestRunFailsOnBadConfig(t *testing.T) {
	err := run(context.Background(), env(map[string]string{"WORKERS": "none"}), io.Discard, nil)
	if err == nil || !strings.Contains(err.Error(), "WORKERS") {
		t.Fatalf("error = %v, want a WORKERS config error", err)
	}
}
~~~

`waitForState` **polls**: it asks repeatedly until the answer changes or it gives up. Asynchronous systems are tested this way, because there's no single moment when "the job is done" is returned to you.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

**Run it.** Start the service with one worker and room for two waiting jobs, so it's easy to overload:

~~~bash
WORKERS=1 QUEUE_CAPACITY=2 go run ./cmd/api
~~~

In a second terminal, send five 1-second jobs as fast as possible:

~~~bash
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -w "job $i: %{http_code} retry-after=%header{retry-after}\n" \
    -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' \
    -d '{"description":"slow","duration_ms":1000}'
done
curl -s http://127.0.0.1:8080/metrics | grep '^jobs_queue_depth'
~~~

~~~text
job 1: 201 retry-after=
job 2: 201 retry-after=
job 3: 201 retry-after=
job 4: 503 retry-after=1
job 5: 503 retry-after=1
jobs_queue_depth 2
~~~

Exactly what the arithmetic predicts. The single worker took job 1 at once, which freed its slot, so jobs 2 and 3 filled the two queue slots, and jobs 4 and 5 were refused. Now look at every job:

~~~bash
for i in 1 2 3 4 5; do curl -s http://127.0.0.1:8080/jobs/$i; echo; done
~~~

Trimmed to the fields that matter:

~~~text
1 running
2 queued
3 queued
4 failed   not dispatched: queue is full
5 failed   not dispatched: queue is full
~~~

Three seconds later, jobs 1–3 are `completed`, one per second (one worker, 1-second jobs). Press Ctrl+C, and the last log line reports `"jobs_left_in_queue":0`.

**Break it: no backpressure.** In `Dispatch`, delete the `default:` case and its `return ErrFull`, so a full queue makes the sender wait. Rerun the five requests. Requests 4 and 5 now hang, for about 1 and 2 seconds, until the worker frees a slot, and then succeed. With slower jobs they'd hang far past the 2-second request deadline, because a plain channel send ignores the context entirely. The caller can't tell "slow" from "overloaded", and every waiting request holds a goroutine and a connection. That's how overload spreads from one service to everything that calls it. Restore the `default` case.

**Explain it:** use Little's law to say how long the 100th job in a full 100-slot queue waits, with 4 workers and 1-second jobs. Why 503 and not 429? What does a job that was refused look like in `GET /jobs/{id}`, and why is that better than the job vanishing?

---

## Step 2: Messages, a bus, and an event-driven worker

**The problem.** In step 1, the worker calls `service.Run` directly. That only works because both live in one process and share one memory. Put the worker on another machine and there's no shared memory and no function call: the only thing that crosses the gap is a **message**, a piece of data sent over a network. This step reshapes the code so that *only messages* connect the API and the workers. Everything still runs in one process here, so you can see the design before a real broker arrives in step 3.

**New ideas.**

- A **command** asks for something to be done, and exactly one handler should act on it: "run job 7". Its name is imperative.
- An **event** reports that something happened, and any number of parts may react: "job 7 started", "job 7 completed". Its name is in the past tense. Events are facts, and nobody can refuse a fact.
- **Event-driven architecture (EDA)** connects parts of a system through events instead of direct calls. The worker doesn't call the API to say "done"; it publishes `job_completed`, and the API reacts. Neither needs to know where the other runs.
- **Bounded contexts**, from the strategic half of domain-driven design: the API owns *job records* (the Intake context); the worker owns *doing the work* (the Processing context). Each context keeps its own model. The worker never reads or writes job records, and the API never runs jobs. They agree only on the messages between them, and the messages are a **contract**.
- An **envelope** is the part every message shares:
  - a unique **ID**, so a receiver can recognise a duplicate;
  - a **type**;
  - a **version**, so the payload's shape can change later;
  - a timestamp;
  - the **payload** itself.
- **Delivery guarantees.**
  - **At-most-once:** a message is delivered once or not at all, and may be lost.
  - **At-least-once:** it's redelivered until a handler accepts it, and may be **duplicated**.
  - **Exactly-once delivery** isn't achievable between independent systems over an unreliable network. What you *can* build is **exactly-once in effect**: at-least-once delivery, plus handlers that are **idempotent**, meaning applying the same message twice has the same effect as applying it once.
- **Be strict at your front door, tolerant reading messages.** Phase 1's HTTP API rejects unknown JSON fields: callers are strangers, and a typo should fail loudly. Messages are different: they come from your own services, which are upgraded at different times. If a new sender adds a field, an old reader should ignore it rather than crash. This is the **tolerant reader** pattern.

~~~mermaid
sequenceDiagram
    participant API as API (Intake)
    participant C as commands queue
    participant W as Worker (Processing)
    participant E as events queue
    API->>C: RunJob{job 7}
    C->>W: RunJob{job 7}
    W->>E: JobStarted{7}
    W->>W: do the work
    W->>E: JobCompleted{7}
    E->>API: JobStarted{7}, JobCompleted{7}
    Note over API: queued → running → completed
~~~

### The messages

Create `internal/messages/messages.go`:

<!-- file: internal/messages/messages.go -->
~~~go
// Package messages defines what the parts of KESTREL say to each other.
// A command asks for something to be done and has exactly one handler. An
// event reports that something happened; any number of parts may react.
// Every message travels inside an Envelope.
package messages

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Queue names. Commands go to workers; events come back to the API.
const (
	CommandsQueue = "jobs.commands"
	EventsQueue   = "jobs.events"
)

// Message types. Commands are imperative; events are in the past tense.
const (
	TypeRunJob       = "jobs.run_job"
	TypeJobStarted   = "jobs.job_started"
	TypeJobCompleted = "jobs.job_completed"
	TypeJobFailed    = "jobs.job_failed"
)

// ErrUnsupported means a message has a type, version or payload this code
// can't read.
var ErrUnsupported = errors.New("unsupported message")

// Envelope is the part every message shares. The ID is unique per message,
// so a receiver can recognise a duplicate. Version says which shape the
// payload has.
type Envelope struct {
	ID         string          `json:"id"`
	Type       string          `json:"type"`
	Version    int             `json:"version"`
	OccurredAt time.Time       `json:"occurred_at"`
	Payload    json.RawMessage `json:"payload"`
}

// RunJob is the command that asks a worker to run a job.
type RunJob struct {
	JobID       int64  `json:"job_id"`
	Description string `json:"description"`
	DurationMS  int64  `json:"duration_ms"`
}

// JobStarted, JobCompleted and JobFailed are the events a worker reports.
type JobStarted struct {
	JobID int64 `json:"job_id"`
}

type JobCompleted struct {
	JobID int64 `json:"job_id"`
}

type JobFailed struct {
	JobID  int64  `json:"job_id"`
	Reason string `json:"reason"`
}

// New wraps payload in a version-1 envelope with a fresh, random ID.
func New(msgType string, payload any, now time.Time) (Envelope, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return Envelope{}, fmt.Errorf("encode %s: %w", msgType, err)
	}
	return Envelope{ID: rand.Text(), Type: msgType, Version: 1, OccurredAt: now.UTC(), Payload: body}, nil
}

// Decode checks env's type and version, then reads its payload into dst.
// Payload fields that dst doesn't have are ignored: a reader tolerates
// additions, so a sender can add a field without breaking older readers.
func Decode(env Envelope, wantType string, dst any) error {
	if env.Type != wantType {
		return fmt.Errorf("%w: got type %q, want %q", ErrUnsupported, env.Type, wantType)
	}
	if env.Version != 1 {
		return fmt.Errorf("%w: %s version %d", ErrUnsupported, env.Type, env.Version)
	}
	if err := json.Unmarshal(env.Payload, dst); err != nil {
		return fmt.Errorf("%w: %s payload: %v", ErrUnsupported, env.Type, err)
	}
	return nil
}
~~~

- `json.RawMessage` holds raw JSON bytes without decoding them. The envelope can be read first, to learn the type, and the payload decoded afterwards into the right struct.
- `rand.Text()` from `crypto/rand` returns a random string from a cryptographically secure source, so two messages essentially never share an ID.
- `Decode` uses `json.Unmarshal`, which **ignores** unknown fields. That's the tolerant reader, deliberately the opposite of the HTTP API's `DisallowUnknownFields`.

Create `internal/messages/messages_test.go`:

<!-- file: internal/messages/messages_test.go -->
~~~go
package messages

import (
	"encoding/json"
	"errors"
	"testing"
	"time"
)

var now = time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)

func TestEnvelopeRoundTrip(t *testing.T) {
	msg, err := New(TypeRunJob, RunJob{JobID: 7, Description: "resize", DurationMS: 250}, now)
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	wire, _ := json.Marshal(msg)
	var received Envelope
	if err := json.Unmarshal(wire, &received); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}

	var cmd RunJob
	if err := Decode(received, TypeRunJob, &cmd); err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if cmd != (RunJob{JobID: 7, Description: "resize", DurationMS: 250}) {
		t.Fatalf("cmd = %+v", cmd)
	}
	if received.ID == "" || received.ID != msg.ID || received.Version != 1 || !received.OccurredAt.Equal(now) {
		t.Fatalf("envelope = %+v", received)
	}
}

func TestEveryMessageGetsItsOwnID(t *testing.T) {
	a, _ := New(TypeJobStarted, JobStarted{JobID: 1}, now)
	b, _ := New(TypeJobStarted, JobStarted{JobID: 1}, now)
	if a.ID == b.ID {
		t.Fatalf("two messages share ID %q", a.ID)
	}
}

func TestDecodeRejectsWhatItCannotRead(t *testing.T) {
	started, _ := New(TypeJobStarted, JobStarted{JobID: 1}, now)
	future := started
	future.Version = 9
	broken := started
	broken.Payload = json.RawMessage(`{"job_id":"seven"}`)

	for name, env := range map[string]Envelope{"wrong type": started, "unknown version": future, "bad payload": broken} {
		var cmd RunJob
		want := TypeRunJob
		if name != "wrong type" {
			want = TypeJobStarted
		}
		if err := Decode(env, want, &cmd); !errors.Is(err, ErrUnsupported) {
			t.Errorf("%s: error = %v, want ErrUnsupported", name, err)
		}
	}
}

func TestDecodeToleratesNewFields(t *testing.T) {
	env := Envelope{Type: TypeJobFailed, Version: 1, Payload: json.RawMessage(`{"job_id":3,"reason":"boom","retryable":true}`)}
	var event JobFailed
	if err := Decode(env, TypeJobFailed, &event); err != nil {
		t.Fatalf("a field added by a newer sender broke an older reader: %v", err)
	}
	if event != (JobFailed{JobID: 3, Reason: "boom"}) {
		t.Fatalf("event = %+v", event)
	}
}
~~~

`cmd != (RunJob{...})` compares two structs field by field. That works in Go whenever every field is comparable.

<!-- run: go test ./internal/messages/... -->

### The bus: at-least-once delivery

A **message bus** carries messages from publishers to subscribers. Several subscribers on one queue are **competing consumers**: each message goes to exactly one of them. That's how a pool of workers shares the work. The in-memory bus here behaves like a real broker in the ways that matter:
- a handler that returns an error gets the message **again**, which is redelivery;
- a message that fails too many times, or fails permanently, goes to a **dead-letter** list instead of looping forever;
- a full queue refuses new messages.

Create `internal/bus/bus.go`:

<!-- file: internal/bus/bus.go -->
~~~go
// Package bus moves messages between the parts of KESTREL with at-least-once
// delivery: a message is redelivered until a handler accepts it, so a
// handler may see the same message more than once.
package bus

import (
	"context"
	"errors"
	"slices"
	"sync"

	"kestrel/internal/messages"
)

// ErrFull means a queue is at capacity and the message was not accepted.
var ErrFull = errors.New("queue is full")

// Handler processes one message. Returning nil accepts it. Returning an
// error asks for redelivery, unless the error is Permanent.
type Handler func(ctx context.Context, msg messages.Envelope) error

// Publisher sends a message to a named queue.
type Publisher interface {
	Publish(ctx context.Context, queue string, msg messages.Envelope) error
}

// Subscriber delivers a queue's messages to a handler until ctx is done.
type Subscriber interface {
	Subscribe(ctx context.Context, queue string, handle Handler) error
}

type permanentError struct{ err error }

func (p permanentError) Error() string { return "permanent: " + p.err.Error() }
func (p permanentError) Unwrap() error { return p.err }

// Permanent marks an error that redelivery cannot fix, such as a message
// that can't be decoded. The message is dead-lettered instead.
func Permanent(err error) error { return permanentError{err} }

// IsPermanent reports whether err, or anything it wraps, is Permanent.
func IsPermanent(err error) bool {
	var p permanentError
	return errors.As(err, &p)
}

// Memory is an in-process bus. Each queue is a buffered channel, so several
// subscribers on one queue compete for its messages.
type Memory struct {
	capacity      int
	maxDeliveries int

	mu     sync.Mutex
	queues map[string]chan delivery
	dead   []messages.Envelope
}

type delivery struct {
	msg        messages.Envelope
	deliveries int
}

// NewMemory makes a bus whose queues hold capacity messages each, and which
// dead-letters a message after maxDeliveries failed attempts.
func NewMemory(capacity, maxDeliveries int) *Memory {
	return &Memory{capacity: capacity, maxDeliveries: maxDeliveries, queues: make(map[string]chan delivery)}
}

func (m *Memory) queue(name string) chan delivery {
	m.mu.Lock()
	defer m.mu.Unlock()
	q, ok := m.queues[name]
	if !ok {
		q = make(chan delivery, m.capacity)
		m.queues[name] = q
	}
	return q
}

// Publish adds a message without waiting, or returns ErrFull.
func (m *Memory) Publish(_ context.Context, queue string, msg messages.Envelope) error {
	select {
	case m.queue(queue) <- delivery{msg: msg}:
		return nil
	default:
		return ErrFull
	}
}

// Subscribe hands messages to handle until ctx is cancelled. A handler that
// is already running finishes: it gets a context that is never cancelled,
// and bounds its own work.
func (m *Memory) Subscribe(ctx context.Context, queue string, handle Handler) error {
	q := m.queue(queue)
	for {
		if ctx.Err() != nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return nil
		case d := <-q:
			d.deliveries++
			err := handle(context.WithoutCancel(ctx), d.msg)
			switch {
			case err == nil:
			case IsPermanent(err) || d.deliveries >= m.maxDeliveries:
				m.deadLetter(d.msg)
			default:
				select {
				case q <- d: // redeliver
				default:
					m.deadLetter(d.msg)
				}
			}
		}
	}
}

func (m *Memory) deadLetter(msg messages.Envelope) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.dead = append(m.dead, msg)
}

// Len is how many messages are waiting in a queue.
func (m *Memory) Len(queue string) int {
	return len(m.queue(queue))
}

// Dead returns the dead-lettered messages, oldest first.
func (m *Memory) Dead() []messages.Envelope {
	m.mu.Lock()
	defer m.mu.Unlock()
	return slices.Clone(m.dead)
}
~~~

- `permanentError` wraps another error and has an `Unwrap` method, so `errors.Is` and `errors.As` can see through it. `Permanent(err)` is a way of *tagging* an error with extra meaning without losing the original.
- Redelivery puts the message at the **back** of the queue. A real broker does much the same, which is one reason messages can arrive **out of order**.
- `maxDeliveries` stops a message that always fails from spinning forever and starving the others. RabbitMQ's quorum queues have the same setting, called a delivery limit.
- `slices.Clone` returns a copy, so callers can't modify the dead-letter list behind the lock.

Create `internal/bus/bus_test.go`:

<!-- file: internal/bus/bus_test.go -->
~~~go
package bus

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"kestrel/internal/messages"
)

func msg(t *testing.T, n int) messages.Envelope {
	t.Helper()
	m, err := messages.New(messages.TypeJobStarted, messages.JobStarted{JobID: int64(n)}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// subscribe runs Subscribe in the background and returns a function that
// stops it and waits for it to return.
func subscribe(b *Memory, queue string, handle Handler) (stop func()) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		_ = b.Subscribe(ctx, queue, handle)
		close(done)
	}()
	return func() { cancel(); <-done }
}

func eventually(t *testing.T, cond func() bool) {
	t.Helper()
	for range 200 {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition never became true")
}

func TestFailedMessageIsRedeliveredUntilAccepted(t *testing.T) {
	b := NewMemory(10, 5)
	var calls atomic.Int32
	stop := subscribe(b, "q", func(context.Context, messages.Envelope) error {
		if calls.Add(1) < 3 {
			return errors.New("transient")
		}
		return nil
	})
	defer stop()

	_ = b.Publish(context.Background(), "q", msg(t, 1))
	eventually(t, func() bool { return calls.Load() == 3 })
	time.Sleep(20 * time.Millisecond)
	if calls.Load() != 3 || len(b.Dead()) != 0 {
		t.Fatalf("calls = %d, dead = %d; want 3 and 0", calls.Load(), len(b.Dead()))
	}
}

func TestPermanentFailureIsDeadLetteredAtOnce(t *testing.T) {
	b := NewMemory(10, 5)
	var calls atomic.Int32
	stop := subscribe(b, "q", func(context.Context, messages.Envelope) error {
		calls.Add(1)
		return Permanent(errors.New("can't decode"))
	})
	defer stop()

	_ = b.Publish(context.Background(), "q", msg(t, 1))
	eventually(t, func() bool { return len(b.Dead()) == 1 })
	if calls.Load() != 1 {
		t.Fatalf("calls = %d, want 1", calls.Load())
	}
}

func TestAlwaysFailingMessageStopsAfterMaxDeliveries(t *testing.T) {
	b := NewMemory(10, 4)
	var calls atomic.Int32
	stop := subscribe(b, "q", func(context.Context, messages.Envelope) error {
		calls.Add(1)
		return errors.New("still broken")
	})
	defer stop()

	_ = b.Publish(context.Background(), "q", msg(t, 1))
	eventually(t, func() bool { return len(b.Dead()) == 1 })
	if calls.Load() != 4 {
		t.Fatalf("calls = %d, want 4", calls.Load())
	}
}

func TestFullQueueRefuses(t *testing.T) {
	b := NewMemory(1, 5)
	_ = b.Publish(context.Background(), "q", msg(t, 1))
	if err := b.Publish(context.Background(), "q", msg(t, 2)); !errors.Is(err, ErrFull) {
		t.Fatalf("error = %v, want %v", err, ErrFull)
	}
}

func TestCompetingConsumersShareTheWork(t *testing.T) {
	b := NewMemory(200, 5)
	var mu sync.Mutex
	seen := map[string]string{}
	handler := func(name string) Handler {
		return func(_ context.Context, m messages.Envelope) error {
			mu.Lock()
			defer mu.Unlock()
			if other, dup := seen[m.ID]; dup {
				return fmt.Errorf("%s got %s, already handled by %s", name, m.ID, other)
			}
			seen[m.ID] = name
			return nil
		}
	}
	stopA := subscribe(b, "q", handler("a"))
	stopB := subscribe(b, "q", handler("b"))
	defer stopA()
	defer stopB()

	for n := range 100 {
		_ = b.Publish(context.Background(), "q", msg(t, n))
	}
	eventually(t, func() bool { mu.Lock(); defer mu.Unlock(); return len(seen) == 100 })
}
~~~

`eventually` **polls** a condition, the same idea as `waitForState`. Testing asynchronous code means waiting for an outcome, never assuming one happened.

<!-- run: go test -race -count=3 ./internal/bus/... -->

### The service: idempotent event handlers instead of Run

The API no longer runs jobs, so `Service.Run` goes. In its place come three methods that **apply what a worker reports**. Because delivery is at-least-once, each of them must be idempotent and tolerant of order:

| Situation | What happens |
|---|---|
| "started" arrives twice | The second changes nothing |
| "completed" arrives before "started" (redelivery reordered them) | The job still completes |
| "failed" arrives after "completed" (a duplicate run failed late) | Ignored: the **first outcome wins** |
| Two copies of one event are applied at the same moment | Compare-and-swap lets one write; the other reads again and finds nothing to do |

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

// FailureReason turns the error that stopped a job's work into the reason
// recorded on the job.
func FailureReason(err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "deadline exceeded"
	case errors.Is(err, context.Canceled):
		return "cancelled"
	default:
		return err.Error()
	}
}

// Service holds the API's use cases: accepting jobs, and recording what
// workers report about them.
type Service struct {
	repo     Repository
	dispatch Dispatcher
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
// steps, the job stays queued forever. Phase 3 removes that gap with a
// transactional outbox.
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

// MarkStarted, MarkCompleted and MarkFailed record what a worker reports.
// Messages can arrive more than once and out of order, so each one is
// idempotent: a duplicate changes nothing, a completion that arrives before
// its "started" still completes the job, and once a job has finished, later
// reports are ignored. The first outcome wins.
func (s *Service) MarkStarted(ctx context.Context, id ID) error {
	return s.transition(ctx, id, func(job *Job) error {
		return job.Start(s.now())
	})
}

func (s *Service) MarkCompleted(ctx context.Context, id ID) error {
	return s.transition(ctx, id, func(job *Job) error {
		if job.State == StateQueued {
			if err := job.Start(s.now()); err != nil {
				return err
			}
		}
		return job.Complete(s.now())
	})
}

func (s *Service) MarkFailed(ctx context.Context, id ID, reason string) error {
	return s.transition(ctx, id, func(job *Job) error {
		return job.Fail(reason, s.now())
	})
}

// transition applies change with compare-and-swap. If another update got
// there first, it reads the job again and reconsiders.
func (s *Service) transition(ctx context.Context, id ID, change func(*Job) error) error {
	for {
		job, err := s.repo.Get(ctx, id)
		if err != nil {
			return err
		}
		if job.State == StateCompleted || job.State == StateFailed {
			return nil // already finished: a duplicate or a late report
		}
		expected := job.State
		if err := change(&job); err != nil {
			if errors.Is(err, ErrInvalidTransition) {
				return nil // for example, "started" for a job already running
			}
			return err
		}
		err = s.repo.Update(ctx, job, expected)
		if !errors.Is(err, ErrConflict) {
			return err
		}
		// Another report changed the job between Get and Update. Read it again.
	}
}
~~~

`transition` is the same compare-and-swap as Phase 1, plus a **retry loop**: on `ErrConflict` it reads the fresh state and decides again. The loop ends because every pass either writes successfully, finds the job finished, or finds nothing to do.

Replace `internal/jobs/service_test.go`:

<!-- file: internal/jobs/service_test.go -->
~~~go
package jobs_test

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"kestrel/internal/jobs"
	"kestrel/internal/memstore"
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
}

type failingDispatcher struct{ err error }

func (d failingDispatcher) Dispatch(context.Context, jobs.Job) error { return d.err }

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
		t.Fatalf("stored = %+v", stored)
	}
}

func TestEventsDriveTheLifecycleIdempotently(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)

	steps := []struct {
		name  string
		apply func() error
		want  jobs.State
	}{
		{"started", func() error { return svc.MarkStarted(ctx, job.ID) }, jobs.StateRunning},
		{"started again", func() error { return svc.MarkStarted(ctx, job.ID) }, jobs.StateRunning},
		{"completed", func() error { return svc.MarkCompleted(ctx, job.ID) }, jobs.StateCompleted},
		{"completed again", func() error { return svc.MarkCompleted(ctx, job.ID) }, jobs.StateCompleted},
		{"a late failure", func() error { return svc.MarkFailed(ctx, job.ID, "late") }, jobs.StateCompleted},
	}
	for _, step := range steps {
		if err := step.apply(); err != nil {
			t.Fatalf("%s: %v", step.name, err)
		}
		if got, _ := svc.Get(ctx, job.ID); got.State != step.want {
			t.Fatalf("after %s: state = %s, want %s", step.name, got.State, step.want)
		}
	}
}

func TestCompletionBeforeStartStillCompletes(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)

	if err := svc.MarkCompleted(ctx, job.ID); err != nil {
		t.Fatalf("MarkCompleted: %v", err)
	}
	if err := svc.MarkStarted(ctx, job.ID); err != nil {
		t.Fatalf("late MarkStarted: %v", err)
	}
	if got, _ := svc.Get(ctx, job.ID); got.State != jobs.StateCompleted {
		t.Fatalf("state = %s, want completed", got.State)
	}
}

func TestEventForUnknownJob(t *testing.T) {
	svc := jobs.NewService(memstore.New())
	if err := svc.MarkStarted(context.Background(), 99); !errors.Is(err, jobs.ErrNotFound) {
		t.Fatalf("error = %v, want %v", err, jobs.ErrNotFound)
	}
}

// slowGetRepository pauses after every Get, widening the gap between a
// transition's read and its write, so racing updates collide every time.
type slowGetRepository struct {
	jobs.Repository
}

func (r slowGetRepository) Get(ctx context.Context, id jobs.ID) (jobs.Job, error) {
	job, err := r.Repository.Get(ctx, id)
	time.Sleep(5 * time.Millisecond)
	return job, err
}

// countingRepository counts the updates that were actually written.
type countingRepository struct {
	jobs.Repository
	writes atomic.Int32
}

func (r *countingRepository) Update(ctx context.Context, job jobs.Job, expected jobs.State) error {
	err := r.Repository.Update(ctx, job, expected)
	if err == nil {
		r.writes.Add(1)
	}
	return err
}

func TestConcurrentDuplicateEventsWriteOnce(t *testing.T) {
	counting := &countingRepository{Repository: memstore.New()}
	svc := jobs.NewService(slowGetRepository{counting})
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)
	_ = svc.MarkStarted(ctx, job.ID)
	before := counting.writes.Load()

	const copies = 20
	errs := make(chan error, copies)
	var wg sync.WaitGroup
	for range copies {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs <- svc.MarkCompleted(ctx, job.ID)
		}()
	}
	wg.Wait()
	close(errs)

	for err := range errs {
		if err != nil {
			t.Fatalf("a duplicate event returned %v; duplicates must be accepted quietly", err)
		}
	}
	if writes := counting.writes.Load() - before; writes != 1 {
		t.Fatalf("%d writes for %d copies of one event, want exactly 1", writes, copies)
	}
}
~~~

Two **decorators** stack here: `slowGetRepository{counting}` slows reads down, and `countingRepository` counts writes, both wrapped around the same real store. Neither knows about the other. That composability comes straight from depending on the `Repository` interface.

<!-- run: go test -race ./internal/jobs/... -->

### The connection between the service and the bus

Two small adapters connect the jobs service to the bus. A `Dispatcher` turns a new job into a `RunJob` command. An event handler turns worker events into `Mark...` calls. Create `internal/eventing/eventing.go`:

<!-- file: internal/eventing/eventing.go -->
~~~go
// Package eventing connects the jobs service to the message bus. It turns
// new jobs into RunJob commands, and worker events into state changes.
package eventing

import (
	"context"
	"errors"
	"fmt"
	"time"

	"kestrel/internal/bus"
	"kestrel/internal/jobs"
	"kestrel/internal/messages"
)

// Dispatcher implements jobs.Dispatcher by publishing a RunJob command.
type Dispatcher struct {
	commands bus.Publisher
	now      func() time.Time
}

func NewDispatcher(commands bus.Publisher) *Dispatcher {
	return &Dispatcher{commands: commands, now: time.Now}
}

func (d *Dispatcher) Dispatch(ctx context.Context, job jobs.Job) error {
	msg, err := messages.New(messages.TypeRunJob, messages.RunJob{
		JobID:       int64(job.ID),
		Description: string(job.Description),
		DurationMS:  job.Duration.Milliseconds(),
	}, d.now())
	if err != nil {
		return err
	}
	return d.commands.Publish(ctx, messages.CommandsQueue, msg)
}

// JobUpdater is what the event handler needs from the jobs service.
type JobUpdater interface {
	MarkStarted(ctx context.Context, id jobs.ID) error
	MarkCompleted(ctx context.Context, id jobs.ID) error
	MarkFailed(ctx context.Context, id jobs.ID, reason string) error
}

// NewEventHandler returns a bus.Handler that applies worker events. An event
// it can't read, or one about a job that doesn't exist, can never succeed,
// so it is marked permanent and dead-lettered instead of redelivered.
func NewEventHandler(updater JobUpdater) bus.Handler {
	return func(ctx context.Context, msg messages.Envelope) error {
		err := apply(ctx, updater, msg)
		if errors.Is(err, messages.ErrUnsupported) || errors.Is(err, jobs.ErrNotFound) {
			return bus.Permanent(err)
		}
		return err
	}
}

func apply(ctx context.Context, updater JobUpdater, msg messages.Envelope) error {
	switch msg.Type {
	case messages.TypeJobStarted:
		var event messages.JobStarted
		if err := messages.Decode(msg, msg.Type, &event); err != nil {
			return err
		}
		return updater.MarkStarted(ctx, jobs.ID(event.JobID))
	case messages.TypeJobCompleted:
		var event messages.JobCompleted
		if err := messages.Decode(msg, msg.Type, &event); err != nil {
			return err
		}
		return updater.MarkCompleted(ctx, jobs.ID(event.JobID))
	case messages.TypeJobFailed:
		var event messages.JobFailed
		if err := messages.Decode(msg, msg.Type, &event); err != nil {
			return err
		}
		return updater.MarkFailed(ctx, jobs.ID(event.JobID), event.Reason)
	default:
		return fmt.Errorf("%w: type %q", messages.ErrUnsupported, msg.Type)
	}
}
~~~

`NewEventHandler` returns a **closure**: a function value that remembers `updater`. Its signature matches `bus.Handler`, so it can be handed straight to `Subscribe`.

### The worker

The worker owns no job records. It reads a command, reports "started", does the work under its own deadline, and reports the outcome. Create `internal/worker/worker.go`:

<!-- file: internal/worker/worker.go -->
~~~go
// Package worker runs jobs it receives as RunJob commands and reports what
// happened as events. It owns no job records: the API does.
package worker

import (
	"context"
	"time"

	"kestrel/internal/bus"
	"kestrel/internal/jobs"
	"kestrel/internal/messages"
)

type Worker struct {
	events     bus.Publisher
	work       jobs.WorkFunc
	jobTimeout time.Duration
	now        func() time.Time
}

func New(events bus.Publisher, work jobs.WorkFunc, jobTimeout time.Duration) *Worker {
	return &Worker{events: events, work: work, jobTimeout: jobTimeout, now: time.Now}
}

// Handle is a bus.Handler for the commands queue.
//
// If publishing an event fails, Handle returns the error, so the command is
// redelivered and the job may run a second time. That is the price of
// at-least-once delivery; the API's idempotent handlers make it harmless.
func (w *Worker) Handle(ctx context.Context, msg messages.Envelope) error {
	var cmd messages.RunJob
	if err := messages.Decode(msg, messages.TypeRunJob, &cmd); err != nil {
		return bus.Permanent(err) // no retry can fix a message we can't read
	}
	if err := w.emit(ctx, messages.TypeJobStarted, messages.JobStarted{JobID: cmd.JobID}); err != nil {
		return err
	}

	job := jobs.Job{
		ID:          jobs.ID(cmd.JobID),
		Description: jobs.Description(cmd.Description),
		Duration:    time.Duration(cmd.DurationMS) * time.Millisecond,
	}
	jobCtx, cancel := context.WithTimeout(ctx, w.jobTimeout)
	defer cancel()
	if err := w.work(jobCtx, job); err != nil {
		failed := messages.JobFailed{JobID: cmd.JobID, Reason: jobs.FailureReason(err)}
		return w.emit(ctx, messages.TypeJobFailed, failed)
	}
	return w.emit(ctx, messages.TypeJobCompleted, messages.JobCompleted{JobID: cmd.JobID})
}

func (w *Worker) emit(ctx context.Context, msgType string, payload any) error {
	msg, err := messages.New(msgType, payload, w.now())
	if err != nil {
		return bus.Permanent(err)
	}
	return w.events.Publish(ctx, messages.EventsQueue, msg)
}
~~~

Create `internal/worker/worker_test.go`:

<!-- file: internal/worker/worker_test.go -->
~~~go
package worker

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"kestrel/internal/bus"
	"kestrel/internal/jobs"
	"kestrel/internal/messages"
)

// recorder is a bus.Publisher that keeps what was published, or fails.
type recorder struct {
	mu   sync.Mutex
	sent []messages.Envelope
	err  error
}

func (r *recorder) Publish(_ context.Context, _ string, msg messages.Envelope) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.err != nil {
		return r.err
	}
	r.sent = append(r.sent, msg)
	return nil
}

func (r *recorder) types() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var types []string
	for _, m := range r.sent {
		types = append(types, m.Type)
	}
	return types
}

func runJob(t *testing.T, durationMS int64) messages.Envelope {
	t.Helper()
	m, err := messages.New(messages.TypeRunJob, messages.RunJob{JobID: 7, Description: "x", DurationMS: durationMS}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestSuccessfulJobReportsStartedThenCompleted(t *testing.T) {
	events := &recorder{}
	w := New(events, jobs.Simulate, time.Second)

	if err := w.Handle(context.Background(), runJob(t, 10)); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if got := events.types(); len(got) != 2 || got[0] != messages.TypeJobStarted || got[1] != messages.TypeJobCompleted {
		t.Fatalf("events = %v", got)
	}
}

func TestJobPastItsDeadlineReportsFailure(t *testing.T) {
	events := &recorder{}
	w := New(events, jobs.Simulate, 20*time.Millisecond)

	if err := w.Handle(context.Background(), runJob(t, 2000)); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	var failed messages.JobFailed
	if err := messages.Decode(events.sent[1], messages.TypeJobFailed, &failed); err != nil {
		t.Fatalf("second event: %v", err)
	}
	if failed.Reason != "deadline exceeded" {
		t.Fatalf("reason = %q", failed.Reason)
	}
}

func TestUnreadableCommandIsPermanent(t *testing.T) {
	w := New(&recorder{}, jobs.Simulate, time.Second)
	bad := runJob(t, 0)
	bad.Version = 2
	if err := w.Handle(context.Background(), bad); !bus.IsPermanent(err) {
		t.Fatalf("error = %v, want permanent", err)
	}
}

func TestFailedPublishAsksForRedelivery(t *testing.T) {
	w := New(&recorder{err: errors.New("broker down")}, jobs.Simulate, time.Second)
	err := w.Handle(context.Background(), runJob(t, 0))
	if err == nil || bus.IsPermanent(err) {
		t.Fatalf("error = %v, want a retryable error", err)
	}
}
~~~

<!-- run: go test -race ./internal/eventing/... ./internal/worker/... -->

### Remove the in-process queue

The bus replaces step 1's queue. Delete the `internal/queue` package:

<!-- run: rm -r internal/queue -->
~~~bash
rm -r internal/queue
~~~

### Wiring: one process, connected only by messages

Replace `cmd/api/main.go`. It now builds a bus, starts `WORKERS` worker subscriptions and one event subscription, and shuts all of them down in order:

<!-- file: cmd/api/main.go -->
~~~go
// Command api runs the KESTREL jobs service. In this step, the API and its
// workers share one process, but they communicate only through messages on
// an in-memory bus.
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

	"kestrel/internal/bus"
	"kestrel/internal/eventing"
	"kestrel/internal/httpapi"
	"kestrel/internal/jobs"
	"kestrel/internal/memstore"
	"kestrel/internal/messages"
	"kestrel/internal/worker"
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
	RequestTimeout time.Duration
	ShutdownGrace  time.Duration
	Workers        int
	QueueCapacity  int
	MaxDeliveries  int
	JobTimeout     time.Duration
}

func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{
		ListenAddr:     "127.0.0.1:8080",
		RequestTimeout: 2 * time.Second,
		ShutdownGrace:  10 * time.Second,
		Workers:        4,
		QueueCapacity:  100,
		MaxDeliveries:  5,
		JobTimeout:     10 * time.Second,
	}
	if v := getenv("LISTEN_ADDR"); v != "" {
		if _, _, err := net.SplitHostPort(v); err != nil {
			return config{}, fmt.Errorf("LISTEN_ADDR must look like host:port, got %q", v)
		}
		cfg.ListenAddr = v
	}
	var err error
	if cfg.RequestTimeout, err = durationFromEnv(getenv, "REQUEST_TIMEOUT", cfg.RequestTimeout); err != nil {
		return config{}, err
	}
	if cfg.ShutdownGrace, err = durationFromEnv(getenv, "SHUTDOWN_GRACE", cfg.ShutdownGrace); err != nil {
		return config{}, err
	}
	if cfg.JobTimeout, err = durationFromEnv(getenv, "JOB_TIMEOUT", cfg.JobTimeout); err != nil {
		return config{}, err
	}
	if cfg.Workers, err = positiveIntFromEnv(getenv, "WORKERS", cfg.Workers); err != nil {
		return config{}, err
	}
	if cfg.QueueCapacity, err = positiveIntFromEnv(getenv, "QUEUE_CAPACITY", cfg.QueueCapacity); err != nil {
		return config{}, err
	}
	if cfg.MaxDeliveries, err = positiveIntFromEnv(getenv, "MAX_DELIVERIES", cfg.MaxDeliveries); err != nil {
		return config{}, err
	}
	return cfg, nil
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

// run starts the API, the workers and the event consumer, blocks until ctx
// is cancelled, then shuts them down gracefully.
func run(ctx context.Context, getenv func(string) string, stdout io.Writer, ready func(addr string)) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	messageBus := bus.NewMemory(cfg.QueueCapacity, cfg.MaxDeliveries)
	service := jobs.NewService(memstore.New(), jobs.WithDispatcher(eventing.NewDispatcher(messageBus)))
	runner := worker.New(messageBus, jobs.Simulate, cfg.JobTimeout)

	metrics := httpapi.NewMetrics()
	metrics.MustRegister(
		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Name: "jobs_queue_depth",
			Help: "Commands waiting for a worker.",
		}, func() float64 { return float64(messageBus.Len(messages.CommandsQueue)) }),
		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Name: "messages_dead_lettered",
			Help: "Messages given up on after permanent or repeated failure.",
		}, func() float64 { return float64(len(messageBus.Dead())) }),
	)

	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
	)
	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      cfg.RequestTimeout + 5*time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Cancelling stopConsuming makes every subscription stop taking
	// messages. A handler already running finishes on its own.
	stopConsuming, cancelConsuming := context.WithCancel(context.Background())
	defer cancelConsuming()
	var consumers sync.WaitGroup
	consume := func(queue string, handle bus.Handler) {
		consumers.Add(1)
		go func() {
			defer consumers.Done()
			_ = messageBus.Subscribe(stopConsuming, queue, handle)
		}()
	}
	for range cfg.Workers {
		consume(messages.CommandsQueue, runner.Handle)
	}
	consume(messages.EventsQueue, eventing.NewEventHandler(service))

	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}
	logger.Info("listening", "addr", listener.Addr().String(), "workers", cfg.Workers)
	if ready != nil {
		ready(listener.Addr().String())
	}

	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(listener) }()

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}

	logger.Info("shutting down", "grace", cfg.ShutdownGrace.String())
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()

	// 1. Stop accepting requests, so no new jobs arrive.
	if err := server.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return err
	}

	// 2. Stop consuming, and wait for running handlers up to the grace period.
	cancelConsuming()
	done := make(chan struct{})
	go func() {
		consumers.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-shutdownCtx.Done():
		logger.Warn("grace period over; abandoning messages still being handled")
	}
	logger.Info("stopped",
		"commands_waiting", messageBus.Len(messages.CommandsQueue),
		"events_waiting", messageBus.Len(messages.EventsQueue),
	)
	return nil
}
~~~

What changed, and why:

- **Only messages connect the API and the workers.** Search the code: nothing in `worker` imports `memstore` or calls `jobs.Service`. Moving the worker to another process in step 3 changes `main`, not the worker.
- Handlers run to completion, bounded by `JOB_TIMEOUT`, because the bus gives them a context that is never cancelled. If shutdown runs out of grace, `run` returns anyway, and work still in progress is abandoned. With this in-memory bus, abandoned and waiting messages are simply **lost** when the process exits. The final log line counts them. Step 3's broker keeps them.
- `MAX_DELIVERIES` sets how often the bus retries a failing message before dead-lettering it.

Two of the old `main` tests described the queue's two-context shutdown, which no longer exists. Replace them with tests of the new behaviour. In `cmd/api/main_test.go`, change:

<!-- edit: cmd/api/main_test.go -->
~~~go
func TestShutdownLetsRunningJobFinish(t *testing.T) {
	base, logs, stop, done := startServer(t, nil)
	createJob(t, base, 300)
	waitForState(t, base, "running")

	stop()
	if err := <-done; err != nil {
		t.Fatalf("run returned %v", err)
	}
	if !strings.Contains(logs.String(), `"msg":"job finished","job_id":1,"state":"completed"`) {
		t.Fatalf("job 1 did not complete during shutdown:\n%s", logs.String())
	}
}

func TestShutdownCancelsJobsThatOutlastTheGrace(t *testing.T) {
	base, logs, stop, done := startServer(t, map[string]string{"SHUTDOWN_GRACE": "100ms"})
	createJob(t, base, 5000)
	waitForState(t, base, "running")

	start := time.Now()
	stop()
	if err := <-done; err != nil {
		t.Fatalf("run returned %v", err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("shutdown took %v; the grace period is 100ms", elapsed)
	}
	for _, want := range []string{`"grace period over; cancelling running jobs"`, `"job_id":1,"state":"failed"`} {
		if !strings.Contains(logs.String(), want) {
			t.Errorf("logs missing %s:\n%s", want, logs.String())
		}
	}
}
~~~

to:

~~~go
func TestShutdownWaitsForRunningJob(t *testing.T) {
	base, _, stop, done := startServer(t, nil)
	createJob(t, base, 300)
	waitForState(t, base, "running")

	start := time.Now()
	stop()
	if err := <-done; err != nil {
		t.Fatalf("run returned %v", err)
	}
	if elapsed := time.Since(start); elapsed < 150*time.Millisecond {
		t.Fatalf("run returned after %v; it should wait for the running job", elapsed)
	}
}

func TestShutdownGivesUpAfterTheGrace(t *testing.T) {
	base, logs, stop, done := startServer(t, map[string]string{"SHUTDOWN_GRACE": "100ms"})
	createJob(t, base, 5000)
	waitForState(t, base, "running")

	start := time.Now()
	stop()
	if err := <-done; err != nil {
		t.Fatalf("run returned %v", err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("shutdown took %v; the grace period is 100ms", elapsed)
	}
	if !strings.Contains(logs.String(), "grace period over") {
		t.Errorf("logs missing the grace warning:\n%s", logs.String())
	}
}

func TestDeadLetteredCommandsAreCounted(t *testing.T) {
	base, _, _, _ := startServer(t, map[string]string{"JOB_TIMEOUT": "10ms"})
	createJob(t, base, 50)
	waitForState(t, base, "failed")

	resp, err := http.Get(base + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "messages_dead_lettered 0") {
		t.Fatalf("a job that fails normally is not a dead letter:\n%s", body)
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

**Run it.** Start the service with `go run ./cmd/api`, then create a half-second job and watch it move through its states:

~~~bash
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"resize","duration_ms":500}'
for t in 0.05 0.3 0.7; do sleep $t; curl -s http://127.0.0.1:8080/jobs/1; echo; done
~~~

The create returns `"state":"queued"`. The three reads that follow, trimmed to the state, give:

~~~text
running
running
completed
~~~

That path is `POST` → the dispatcher publishes `RunJob` → a worker takes it and publishes `JobStarted` → the event handler marks the job running → half a second later `JobCompleted` → the job is marked completed. Five hops and two queues, all invisible to the caller, who only ever sees the state change.

**Break it: duplicates without compare-and-swap.** In `memstore`'s `Update`, delete the `if current.State != expected { ... }` block (and change `current, ok` to `_, ok`). Run `go test ./internal/jobs`:

~~~text
--- FAIL: TestConcurrentDuplicateEventsWriteOnce (0.01s)
    service_test.go:156: 20 writes for 20 copies of one event, want exactly 1
~~~

All 20 copies read "running", all 20 decided to complete the job, and all 20 wrote. Here that only bumps `UpdatedAt` twenty times. But imagine each write also sent the customer an email, or charged a card. Idempotency isn't about the final state looking right; it's about **side effects happening once**. Restore the check.

**Explain it:** what's the difference between a command and an event? Why is exactly-once *delivery* impossible, and what do you build instead? Why do messages tolerate unknown fields when the HTTP API rejects them?

**Read.** DDIA Ch. 11, the first section (*Transmitting Event Streams*, up to log-based brokers), and *Understanding Distributed Systems*, the chapter on messaging. Carry this question in: which of this step's guarantees would survive the process crashing?

---

## Step 3: RabbitMQ, and two separate processes

**The problem.** The in-memory bus loses every message when the process exits, and it can't connect two processes. A **message broker** is a separate server that stores messages durably and delivers them to consumers in other processes, on other machines. This step swaps the in-memory bus for RabbitMQ without touching the worker, the event handler or the service. Their code depends only on `bus.Publisher` and `bus.Subscriber`.

**New ideas: AMQP, RabbitMQ's protocol.**

- A **connection** is one TCP connection to the broker. A **channel** is a lightweight session multiplexed inside it. Use one channel per goroutine: a channel isn't safe to share.
- A **queue** stores messages. A publisher sends to an **exchange**, which routes messages to queues. The **default exchange** (named `""`) routes each message straight to the queue named by its **routing key**, which is all this lesson needs.
- **Durability needs three things.** A queue declared **durable** survives a broker restart. A message marked **persistent** is written to disk. **Publisher confirms** mean the broker tells the publisher "I have stored it"; until that confirm arrives, the publisher must assume the message might be lost.
- **Acknowledgements.** A consumer receives a message and later **acks** it ("done; delete it") or **nacks** it ("I failed": requeue it, or dead-letter it). If a consumer's connection dies before it acks, the broker **redelivers** the message to another consumer. That's at-least-once delivery, enforced by the broker.
- **Prefetch** (QoS) limits how many unacknowledged messages one consumer may hold. With prefetch 1, a slow worker never hoards jobs that other workers could be running.
- A **quorum queue** keeps copies of its messages on several broker nodes and agrees on them with **Raft**, the consensus protocol you'll build yourself in Phase 4. It has:
  - a **delivery limit**: after too many failed deliveries, a message is dead-lettered instead of looping forever;
  - an optional **maximum length**: when full, new publishes are *rejected* rather than old messages dropped. That's backpressure, enforced by the broker.
- A **dead-letter exchange** (DLX) is where the broker sends messages it gives up on. Here they go to a queue named after the original plus `.dead`, so you can inspect them, fix the cause, and replay them.
- **Crash-only design.** If the connection to the broker drops, the client in this lesson doesn't try to repair itself. The process exits with an error, and whatever supervises it restarts it fresh. Phase 5 uses Kubernetes as that supervisor. Restarting from a clean state is simpler and more reliable than reconnection logic that's rarely exercised.

~~~mermaid
flowchart LR
    API[cmd/api] -- "RunJob (persistent, confirmed)" --> CQ[(jobs.commands<br/>quorum queue)]
    CQ -- "prefetch 1, manual ack" --> W1[cmd/worker]
    CQ --> W2[cmd/worker]
    CQ -. "delivery limit / permanent failure" .-> CD[(jobs.commands.dead)]
    W1 -- "JobStarted / Completed / Failed" --> EQ[(jobs.events<br/>quorum queue)]
    W2 --> EQ
    EQ --> API
~~~

### Run RabbitMQ

Create `compose.yaml` in your practice folder:

<!-- file: compose.yaml -->
~~~yaml
services:
  rabbitmq:
    image: rabbitmq:4-management
    # Run as the image's rabbitmq user; some Docker setups otherwise fail at
    # start-up reading the broker's .erlang.cookie file.
    user: "999:999"
    ports:
      - "5672:5672"   # AMQP, for the services
      - "15672:15672" # the management web UI
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 5s
      timeout: 10s
      retries: 20
~~~

> **Run locally.** These commands need Docker on your machine. CI runs its own RabbitMQ for the integration tests below.

~~~bash
docker compose up -d --wait
docker compose ps
~~~

`up -d` starts the containers in the background, and `--wait` returns only when the health check passes. `docker compose ps` should show `rabbitmq` as `healthy`. Open <http://localhost:15672> and log in as `guest` / `guest` to see the management UI. You'll watch queues there.

### Shared configuration helpers

Two programs (`cmd/api` and a new `cmd/worker`) now read settings from the environment. Rather than copying `durationFromEnv` into both, move the helpers into a package. Create `internal/envconfig/envconfig.go`:

<!-- file: internal/envconfig/envconfig.go -->
~~~go
// Package envconfig reads typed settings from environment variables, with
// defaults, and rejects bad values with a message that names the variable.
package envconfig

import (
	"fmt"
	"net"
	"strconv"
	"time"
)

// Getenv looks up a variable, like os.Getenv. Taking it as a parameter keeps
// configuration testable.
type Getenv func(string) string

func Duration(getenv Getenv, name string, fallback time.Duration) (time.Duration, error) {
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

func PositiveInt(getenv Getenv, name string, fallback int) (int, error) {
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

func HostPort(getenv Getenv, name, fallback string) (string, error) {
	v := getenv(name)
	if v == "" {
		return fallback, nil
	}
	if _, _, err := net.SplitHostPort(v); err != nil {
		return "", fmt.Errorf("%s must look like host:port, got %q", name, v)
	}
	return v, nil
}
~~~

Create `internal/envconfig/envconfig_test.go`:

<!-- file: internal/envconfig/envconfig_test.go -->
~~~go
package envconfig

import (
	"strings"
	"testing"
	"time"
)

func env(values map[string]string) Getenv {
	return func(key string) string { return values[key] }
}

func TestDefaultsAndOverrides(t *testing.T) {
	vars := env(map[string]string{"D": "250ms", "N": "8", "A": "0.0.0.0:9000"})
	if d, err := Duration(vars, "D", time.Second); err != nil || d != 250*time.Millisecond {
		t.Errorf("Duration = %v, %v", d, err)
	}
	if d, err := Duration(vars, "MISSING", time.Second); err != nil || d != time.Second {
		t.Errorf("Duration default = %v, %v", d, err)
	}
	if n, err := PositiveInt(vars, "N", 4); err != nil || n != 8 {
		t.Errorf("PositiveInt = %v, %v", n, err)
	}
	if a, err := HostPort(vars, "A", "127.0.0.1:8080"); err != nil || a != "0.0.0.0:9000" {
		t.Errorf("HostPort = %v, %v", a, err)
	}
}

func TestBadValuesNameTheVariable(t *testing.T) {
	vars := env(map[string]string{"D": "soon", "N": "0", "A": "8080"})
	_, errD := Duration(vars, "D", time.Second)
	_, errN := PositiveInt(vars, "N", 4)
	_, errA := HostPort(vars, "A", "")
	for name, err := range map[string]error{"D": errD, "N": errN, "A": errA} {
		if err == nil || !strings.HasPrefix(err.Error(), name+" ") {
			t.Errorf("%s: error = %v, want one that starts with the variable's name", name, err)
		}
	}
}
~~~

<!-- run: go test ./internal/envconfig/... -->

### The RabbitMQ adapter

Get the official Go client:

<!-- run: go get github.com/rabbitmq/amqp091-go@v1.15.0 -->
~~~bash
go get github.com/rabbitmq/amqp091-go@v1.15.0
~~~

Create `internal/rabbit/rabbit.go`. It implements the same two interfaces as the in-memory bus:

<!-- file: internal/rabbit/rabbit.go -->
~~~go
// Package rabbit connects KESTREL's bus interfaces to RabbitMQ. Queues are
// durable quorum queues, messages are persistent, every publish waits for
// the broker's confirm, and a delivery is acknowledged only after its
// handler accepts it.
package rabbit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"

	amqp "github.com/rabbitmq/amqp091-go"

	"kestrel/internal/bus"
	"kestrel/internal/messages"
)

var (
	// ErrRejected means the broker refused to store a message, for example
	// because the queue is at its maximum length.
	ErrRejected = errors.New("broker rejected the message")

	// ErrClosed means the connection to the broker was lost.
	ErrClosed = errors.New("connection to the broker closed")
)

// Options sets the queue topology and consumer behaviour.
type Options struct {
	MaxLength     int // messages a queue holds before refusing more
	MaxDeliveries int // failed deliveries before a message is dead-lettered
	Prefetch      int // unacknowledged messages one consumer may hold
}

// Client is a connection to RabbitMQ. It implements bus.Publisher and
// bus.Subscriber.
type Client struct {
	conn          *amqp.Connection
	prefetch      int
	maxDeliveries int

	mu        sync.Mutex // an AMQP channel is not safe for concurrent use
	publisher *amqp.Channel
}

// Dial connects to the broker and declares the named queues, each with a
// dead-letter queue named after it plus ".dead".
func Dial(url string, opts Options, queues ...string) (*Client, error) {
	conn, err := amqp.Dial(url)
	if err != nil {
		return nil, fmt.Errorf("connect to RabbitMQ: %w", err)
	}
	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, err
	}
	for _, name := range queues {
		if err := declare(ch, name, opts); err != nil {
			conn.Close()
			return nil, err
		}
	}
	if err := ch.Confirm(false); err != nil {
		conn.Close()
		return nil, fmt.Errorf("enable publisher confirms: %w", err)
	}
	return &Client{conn: conn, prefetch: opts.Prefetch, maxDeliveries: opts.MaxDeliveries, publisher: ch}, nil
}

func declare(ch *amqp.Channel, name string, opts Options) error {
	dead := name + ".dead"
	if _, err := ch.QueueDeclare(dead, true, false, false, false, amqp.Table{"x-queue-type": "quorum"}); err != nil {
		return fmt.Errorf("declare %s: %w", dead, err)
	}
	_, err := ch.QueueDeclare(name, true, false, false, false, amqp.Table{
		"x-queue-type":              "quorum",
		"x-delivery-limit":          int64(opts.MaxDeliveries),
		"x-max-length":              int64(opts.MaxLength),
		"x-overflow":                "reject-publish",
		"x-dead-letter-exchange":    "",
		"x-dead-letter-routing-key": dead,
	})
	if err != nil {
		return fmt.Errorf("declare %s: %w", name, err)
	}
	return nil
}

// Publish sends msg to queue and waits until the broker confirms it has
// stored it.
func (c *Client) Publish(ctx context.Context, queue string, msg messages.Envelope) error {
	body, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return c.publish(ctx, queue, amqp.Publishing{
		ContentType:  "application/json",
		DeliveryMode: amqp.Persistent,
		MessageId:    msg.ID,
		Type:         msg.Type,
		Timestamp:    msg.OccurredAt,
		Body:         body,
	})
}

func (c *Client) publish(ctx context.Context, queue string, p amqp.Publishing) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	confirm, err := c.publisher.PublishWithDeferredConfirmWithContext(ctx, "", queue, false, false, p)
	if err != nil {
		return fmt.Errorf("publish to %s: %w", queue, err)
	}
	acked, err := confirm.WaitContext(ctx)
	if err != nil {
		return fmt.Errorf("wait for confirm from %s: %w", queue, err)
	}
	if !acked {
		return fmt.Errorf("%w: %s", ErrRejected, queue)
	}
	return nil
}

// Subscribe delivers messages from queue to handle until ctx is cancelled.
// A message is acknowledged only after handle accepts it. If this consumer
// stops or its connection dies first, the broker redelivers the message to
// another consumer.
func (c *Client) Subscribe(ctx context.Context, queue string, handle bus.Handler) error {
	ch, err := c.conn.Channel()
	if err != nil {
		return err
	}
	defer ch.Close() // returns any unacknowledged messages to the queue
	if err := ch.Qos(c.prefetch, 0, false); err != nil {
		return err
	}
	deliveries, err := ch.Consume(queue, "", false, false, false, false, nil)
	if err != nil {
		return fmt.Errorf("consume %s: %w", queue, err)
	}
	for {
		if ctx.Err() != nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return nil
		case d, ok := <-deliveries:
			if !ok {
				return ErrClosed
			}
			c.deliver(ctx, queue, d, handle)
		}
	}
}

func (c *Client) deliver(ctx context.Context, queue string, d amqp.Delivery, handle bus.Handler) {
	var msg messages.Envelope
	if err := json.Unmarshal(d.Body, &msg); err != nil {
		_ = d.Nack(false, false) // unreadable: straight to the dead-letter queue
		return
	}
	err := handle(context.WithoutCancel(ctx), msg)
	switch {
	case err == nil:
		_ = d.Ack(false)
	case bus.IsPermanent(err):
		_ = d.Nack(false, false) // to the dead-letter queue
	default:
		c.retry(ctx, queue, d)
	}
}

const attemptHeader = "x-kestrel-attempt"

// retry handles a failed delivery. RabbitMQ 4 doesn't count a requeued
// message towards the queue's delivery limit; that limit catches consumers
// that crash. So the attempt count travels in a header: the message is
// republished with the count raised, and the original is acknowledged.
// After MaxDeliveries attempts it is dead-lettered instead.
func (c *Client) retry(ctx context.Context, queue string, d amqp.Delivery) {
	attempt := attemptOf(d) + 1
	if attempt >= c.maxDeliveries {
		_ = d.Nack(false, false)
		return
	}
	err := c.publish(context.WithoutCancel(ctx), queue, amqp.Publishing{
		Headers:      amqp.Table{attemptHeader: int64(attempt)},
		ContentType:  d.ContentType,
		DeliveryMode: amqp.Persistent,
		MessageId:    d.MessageId,
		Type:         d.Type,
		Timestamp:    d.Timestamp,
		Body:         d.Body,
	})
	if err != nil {
		_ = d.Nack(false, true) // couldn't republish: let the broker redeliver it as-is
		return
	}
	_ = d.Ack(false)
}

func attemptOf(d amqp.Delivery) int {
	switch n := d.Headers[attemptHeader].(type) {
	case int64:
		return int(n)
	case int32:
		return int(n)
	default:
		return 0
	}
}

// Close closes the publishing channel and the connection.
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = c.publisher.Close()
	return c.conn.Close()
}
~~~

Read it against the new ideas:

- `QueueDeclare(name, durable=true, ...)` is **idempotent**: declaring a queue that already exists with the same settings does nothing, so every process can safely declare what it needs at start-up. Declaring it with *different* settings fails. That's one of the errors in *If it goes wrong*.
- `amqp.Table` holds the queue's **arguments**: the quorum type, the delivery limit, the maximum length with `reject-publish`, and the dead-letter route.
- `DeliveryMode: amqp.Persistent` writes the message to disk. `PublishWithDeferredConfirmWithContext` then `WaitContext` sends the message and waits for the broker's confirm. A `false` confirm means the broker *refused* it (the queue was full), and that becomes `ErrRejected`.
- The mutex around `Publish` serialises publishes on one channel, as the AMQP rules require. It also means one publish waits for the previous confirm, which is simple but slow under heavy load. Faster designs keep a channel per goroutine or collect confirms asynchronously. Measure before you need them.
- In `deliver`, the outcomes map onto `bus.Handler`'s contract: `Ack` on success, `Nack(requeue=false)` on a permanent failure (which sends it to the dead-letter queue), and `retry` on anything else.
- `retry` exists because of a real RabbitMQ 4 behaviour that the integration tests below uncovered. A message nacked with `requeue=true` is redelivered at once, and **its delivery count doesn't go up**. A failing message would loop forever: one test measured 251 deliveries in 2 seconds. The queue's `x-delivery-limit` only counts deliveries to consumers that *disappear* (crashes, lost connections), which is still worth having, because it stops a message that keeps killing workers. Ordinary handler failures are counted by the adapter itself, in the `x-kestrel-attempt` header.
- `defer ch.Close()` in `Subscribe` matters: closing a consumer's channel hands every message it holds but hasn't acknowledged back to the queue.

### Integration tests against a real broker

Unit tests with fakes can't prove RabbitMQ behaves the way the code assumes. **Integration tests** run against the real thing. They need a broker, so they **skip** unless `KESTREL_AMQP_URL` is set, and every test uses its own randomly named queue so tests can't interfere with each other. Create `internal/rabbit/rabbit_test.go`:

<!-- file: internal/rabbit/rabbit_test.go -->
~~~go
package rabbit

import (
	"context"
	"crypto/rand"
	"errors"
	"os"
	"sync/atomic"
	"testing"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"

	"kestrel/internal/bus"
	"kestrel/internal/messages"
)

// setup connects to the broker named by KESTREL_AMQP_URL and declares a
// fresh queue for this test, deleting it afterwards.
func setup(t *testing.T, opts Options) (*Client, string) {
	t.Helper()
	url := os.Getenv("KESTREL_AMQP_URL")
	if url == "" {
		t.Skip("set KESTREL_AMQP_URL to run RabbitMQ integration tests")
	}
	queue := "test." + rand.Text()
	client, err := Dial(url, opts, queue)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ch, err := client.conn.Channel()
		if err == nil {
			_, _ = ch.QueueDelete(queue, false, false, false)
			_, _ = ch.QueueDelete(queue+".dead", false, false, false)
			ch.Close()
		}
		client.Close()
	})
	return client, queue
}

func defaults() Options { return Options{MaxLength: 100, MaxDeliveries: 3, Prefetch: 1} }

func newMsg(t *testing.T) messages.Envelope {
	t.Helper()
	m, err := messages.New(messages.TypeJobStarted, messages.JobStarted{JobID: 1}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// consume runs Subscribe until the returned stop function is called.
func consume(client *Client, queue string, handle bus.Handler) (stop func()) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		_ = client.Subscribe(ctx, queue, handle)
		close(done)
	}()
	return func() { cancel(); <-done }
}

// deadCount reports how many messages are waiting in a queue's dead-letter queue.
func deadCount(t *testing.T, client *Client, queue string) int {
	t.Helper()
	ch, err := client.conn.Channel()
	if err != nil {
		t.Fatal(err)
	}
	defer ch.Close()
	q, err := ch.QueueDeclarePassive(queue+".dead", true, false, false, false, amqp.Table{"x-queue-type": "quorum"})
	if err != nil {
		t.Fatal(err)
	}
	return q.Messages
}

func eventually(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("condition never became true")
}

func TestPublishedMessageIsDelivered(t *testing.T) {
	client, queue := setup(t, defaults())
	sent := newMsg(t)
	got := make(chan messages.Envelope, 1)
	stop := consume(client, queue, func(_ context.Context, m messages.Envelope) error {
		got <- m
		return nil
	})
	defer stop()

	if err := client.Publish(context.Background(), queue, sent); err != nil {
		t.Fatalf("Publish: %v", err)
	}
	select {
	case m := <-got:
		if m.ID != sent.ID || m.Type != sent.Type {
			t.Fatalf("got %+v, want %+v", m, sent)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("message never arrived")
	}
}

func TestFailedMessageIsRedelivered(t *testing.T) {
	client, queue := setup(t, defaults())
	var calls atomic.Int32
	stop := consume(client, queue, func(context.Context, messages.Envelope) error {
		if calls.Add(1) == 1 {
			return errors.New("transient")
		}
		return nil
	})
	defer stop()

	_ = client.Publish(context.Background(), queue, newMsg(t))
	eventually(t, func() bool { return calls.Load() == 2 })
}

func TestPermanentFailureGoesToTheDeadLetterQueue(t *testing.T) {
	client, queue := setup(t, defaults())
	stop := consume(client, queue, func(context.Context, messages.Envelope) error {
		return bus.Permanent(errors.New("unreadable"))
	})
	defer stop()

	_ = client.Publish(context.Background(), queue, newMsg(t))
	eventually(t, func() bool { return deadCount(t, client, queue) == 1 })
}

func TestDeliveryLimitStopsAPoisonMessage(t *testing.T) {
	client, queue := setup(t, defaults())
	var calls atomic.Int32
	stop := consume(client, queue, func(context.Context, messages.Envelope) error {
		calls.Add(1)
		return errors.New("always fails")
	})
	defer stop()

	_ = client.Publish(context.Background(), queue, newMsg(t))
	eventually(t, func() bool { return deadCount(t, client, queue) == 1 })
	if calls.Load() != 3 {
		t.Fatalf("delivered %d times, want MaxDeliveries = 3", calls.Load())
	}
}

// A quorum queue notices that it is over its maximum length only after the
// message that crosses the limit is stored, so a queue of 2 accepts a
// third message and refuses the fourth.
func TestFullQueueRejectsPublish(t *testing.T) {
	opts := defaults()
	opts.MaxLength = 2
	client, queue := setup(t, opts)
	ctx := context.Background()

	for n := range 3 {
		if err := client.Publish(ctx, queue, newMsg(t)); err != nil {
			t.Fatalf("Publish %d: %v", n+1, err)
		}
	}
	if err := client.Publish(ctx, queue, newMsg(t)); !errors.Is(err, ErrRejected) {
		t.Fatalf("fourth Publish error = %v, want %v", err, ErrRejected)
	}
}

func TestUnacknowledgedMessageReturnsWhenConsumerStops(t *testing.T) {
	client, queue := setup(t, defaults())
	started := make(chan struct{})
	release := make(chan struct{})
	stopFirst := consume(client, queue, func(context.Context, messages.Envelope) error {
		close(started)
		<-release // a slow handler, holding the message unacknowledged
		return errors.New("crashed")
	})

	_ = client.Publish(context.Background(), queue, newMsg(t))
	<-started

	got := make(chan struct{}, 1)
	stopSecond := consume(client, queue, func(context.Context, messages.Envelope) error {
		got <- struct{}{}
		return nil
	})
	defer stopSecond()

	close(release)
	stopFirst()
	select {
	case <-got:
	case <-time.After(10 * time.Second):
		t.Fatal("the message held by the stopped consumer was never redelivered")
	}
}
~~~

- `t.Skip` marks the test as skipped, not failed, so `go test ./...` passes on a machine without RabbitMQ.
- `t.Cleanup` registers a function to run when the test ends, pass or fail. That's how the test queues get deleted.
- `QueueDeclarePassive` *checks* a queue without creating it, and returns how many messages it holds.

Run them against your broker:

~~~bash
KESTREL_AMQP_URL=amqp://guest:guest@localhost:5672/ go test -v -count=1 ./internal/rabbit/
~~~

~~~text
--- PASS: TestPublishedMessageIsDelivered (0.27s)
--- PASS: TestFailedMessageIsRedelivered (0.29s)
--- PASS: TestPermanentFailureGoesToTheDeadLetterQueue (0.30s)
--- PASS: TestDeliveryLimitStopsAPoisonMessage (0.33s)
--- PASS: TestFullQueueRejectsPublish (0.27s)
--- PASS: TestUnacknowledgedMessageReturnsWhenConsumerStops (0.31s)
ok  	kestrel/internal/rabbit	1.773s
~~~

Without `KESTREL_AMQP_URL`, all six report `SKIP`. Two of these tests started out **failing** while this lesson was being written, and each failure taught something:

- `TestFullQueueRejectsPublish` first expected the *third* publish into a 2-message queue to be refused. The broker accepted it and refused the fourth. A quorum queue notices it's over its limit only after storing the message that crossed it. The test now records the real behaviour, with a comment saying why.
- `TestDeliveryLimitStopsAPoisonMessage` never finished: requeued messages don't raise the delivery count in RabbitMQ 4. That's why the adapter has `retry`.

**That's what integration tests are for.** They test your *assumptions about other software*, which no unit test with a fake can do.

<!-- run: go mod tidy && go vet ./internal/... && go test -race -count=1 ./internal/rabbit/... ./internal/envconfig/... -->

### The API: in-memory for development, RabbitMQ for real

`cmd/api` now has two modes. With `AMQP_URL` set, it publishes commands to RabbitMQ, consumes events from it, and runs **no** workers itself. Without it, it keeps step 2's in-memory bus and in-process workers, so `go test` and quick experiments need no broker. It also stops if its connection to the broker dies (crash-only). Replace `cmd/api/main.go`:

<!-- file: cmd/api/main.go -->
~~~go
// Command api runs the KESTREL jobs API.
//
// With AMQP_URL set, it publishes RunJob commands to RabbitMQ and consumes
// the events that workers (cmd/worker) send back. Without it, it uses an
// in-memory bus and runs workers in this process, for development and tests.
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
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"kestrel/internal/bus"
	"kestrel/internal/envconfig"
	"kestrel/internal/eventing"
	"kestrel/internal/httpapi"
	"kestrel/internal/jobs"
	"kestrel/internal/memstore"
	"kestrel/internal/messages"
	"kestrel/internal/rabbit"
	"kestrel/internal/worker"
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
	AMQPURL        string
	RequestTimeout time.Duration
	ShutdownGrace  time.Duration
	Workers        int
	QueueCapacity  int
	MaxDeliveries  int
	JobTimeout     time.Duration
}

func loadConfig(getenv envconfig.Getenv) (config, error) {
	cfg := config{AMQPURL: getenv("AMQP_URL")}
	var err error
	if cfg.ListenAddr, err = envconfig.HostPort(getenv, "LISTEN_ADDR", "127.0.0.1:8080"); err != nil {
		return config{}, err
	}
	if cfg.RequestTimeout, err = envconfig.Duration(getenv, "REQUEST_TIMEOUT", 2*time.Second); err != nil {
		return config{}, err
	}
	if cfg.ShutdownGrace, err = envconfig.Duration(getenv, "SHUTDOWN_GRACE", 10*time.Second); err != nil {
		return config{}, err
	}
	if cfg.JobTimeout, err = envconfig.Duration(getenv, "JOB_TIMEOUT", 10*time.Second); err != nil {
		return config{}, err
	}
	if cfg.Workers, err = envconfig.PositiveInt(getenv, "WORKERS", 4); err != nil {
		return config{}, err
	}
	if cfg.QueueCapacity, err = envconfig.PositiveInt(getenv, "QUEUE_CAPACITY", 100); err != nil {
		return config{}, err
	}
	if cfg.MaxDeliveries, err = envconfig.PositiveInt(getenv, "MAX_DELIVERIES", 5); err != nil {
		return config{}, err
	}
	return cfg, nil
}

// connectBus returns the publisher and subscriber to use, and a function
// that closes them.
func connectBus(cfg config, metrics *httpapi.Metrics) (bus.Publisher, bus.Subscriber, func() error, error) {
	if cfg.AMQPURL == "" {
		memory := bus.NewMemory(cfg.QueueCapacity, cfg.MaxDeliveries)
		metrics.MustRegister(
			prometheus.NewGaugeFunc(prometheus.GaugeOpts{
				Name: "jobs_queue_depth",
				Help: "Commands waiting for a worker.",
			}, func() float64 { return float64(memory.Len(messages.CommandsQueue)) }),
			prometheus.NewGaugeFunc(prometheus.GaugeOpts{
				Name: "messages_dead_lettered",
				Help: "Messages given up on after permanent or repeated failure.",
			}, func() float64 { return float64(len(memory.Dead())) }),
		)
		return memory, memory, func() error { return nil }, nil
	}
	client, err := rabbit.Dial(cfg.AMQPURL, rabbit.Options{
		MaxLength:     cfg.QueueCapacity,
		MaxDeliveries: cfg.MaxDeliveries,
		Prefetch:      1,
	}, messages.CommandsQueue, messages.EventsQueue)
	if err != nil {
		return nil, nil, nil, err
	}
	return client, client, client.Close, nil
}

// run starts the API and its consumers, blocks until ctx is cancelled or the
// message bus fails, then shuts down gracefully.
func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer, ready func(addr string)) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	metrics := httpapi.NewMetrics()
	publisher, subscriber, closeBus, err := connectBus(cfg, metrics)
	if err != nil {
		return err
	}
	defer closeBus()
	service := jobs.NewService(memstore.New(), jobs.WithDispatcher(eventing.NewDispatcher(publisher)))

	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
	)
	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      cfg.RequestTimeout + 5*time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Cancelling stopConsuming makes every subscription stop taking
	// messages. A handler already running finishes on its own.
	stopConsuming, cancelConsuming := context.WithCancel(context.Background())
	defer cancelConsuming()
	var consumers sync.WaitGroup
	consumerErr := make(chan error, 1)
	consume := func(queue string, handle bus.Handler) {
		consumers.Add(1)
		go func() {
			defer consumers.Done()
			if err := subscriber.Subscribe(stopConsuming, queue, handle); err != nil {
				select {
				case consumerErr <- fmt.Errorf("consume %s: %w", queue, err):
				default:
				}
			}
		}()
	}

	workers := 0
	if cfg.AMQPURL == "" {
		workers = cfg.Workers
		runner := worker.New(publisher, jobs.Simulate, cfg.JobTimeout)
		for range workers {
			consume(messages.CommandsQueue, runner.Handle)
		}
	}
	consume(messages.EventsQueue, eventing.NewEventHandler(service))

	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}
	logger.Info("listening", "addr", listener.Addr().String(), "bus", busName(cfg), "in_process_workers", workers)
	if ready != nil {
		ready(listener.Addr().String())
	}

	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(listener) }()

	var runErr error
	select {
	case err := <-serveErr:
		return err
	case runErr = <-consumerErr:
		logger.Error("lost the message bus; shutting down", "error", runErr)
	case <-ctx.Done():
	}

	logger.Info("shutting down", "grace", cfg.ShutdownGrace.String())
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()

	// 1. Stop accepting requests, so no new jobs arrive.
	if err := server.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return err
	}

	// 2. Stop consuming, and wait for running handlers up to the grace period.
	cancelConsuming()
	done := make(chan struct{})
	go func() {
		consumers.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-shutdownCtx.Done():
		logger.Warn("grace period over; abandoning messages still being handled")
	}
	logger.Info("stopped")
	return runErr
}

func busName(cfg config) string {
	if cfg.AMQPURL == "" {
		return "in-memory"
	}
	return "rabbitmq"
}
~~~

- `connectBus` is a small **factory**: it chooses an implementation from configuration and returns it through the interfaces. Nothing after it knows which bus it got.
- `consumerErr` turns a dead consumer into a shutdown. If RabbitMQ disappears, `Subscribe` returns `ErrClosed`, `run` shuts down and returns the error, and the process exits with status 1. A supervisor (Phase 5) restarts it.

One more `main` test proves a bad broker address fails at start-up instead of halfway through. Add it at the end of `cmd/api/main_test.go`:

<!-- append: cmd/api/main_test.go -->
~~~go
func TestUnreachableBrokerFailsAtStartup(t *testing.T) {
	vars := env(map[string]string{"LISTEN_ADDR": "127.0.0.1:0", "AMQP_URL": "amqp://guest:guest@127.0.0.1:1/"})
	err := run(context.Background(), vars, io.Discard, nil)
	if err == nil || !strings.Contains(err.Error(), "connect to RabbitMQ") {
		t.Fatalf("error = %v, want a connection error", err)
	}
}
~~~

Port 1 is never a RabbitMQ server, so the connection is refused at once.

<!-- run: go mod tidy && go vet ./cmd/... && go test -race -count=1 ./cmd/... -->

### The worker, as its own program

Create `cmd/worker/main.go`:

<!-- file: cmd/worker/main.go -->
~~~go
// Command worker runs KESTREL jobs. It takes RunJob commands from RabbitMQ,
// runs them, and publishes what happened as events. Run as many copies as
// you need: they compete for commands, and each holds one at a time.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"kestrel/internal/bus"
	"kestrel/internal/envconfig"
	"kestrel/internal/jobs"
	"kestrel/internal/messages"
	"kestrel/internal/rabbit"
	"kestrel/internal/worker"
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
	AMQPURL       string
	Workers       int
	QueueCapacity int
	MaxDeliveries int
	JobTimeout    time.Duration
	ShutdownGrace time.Duration
}

func loadConfig(getenv envconfig.Getenv) (config, error) {
	cfg := config{AMQPURL: getenv("AMQP_URL")}
	if cfg.AMQPURL == "" {
		return config{}, errors.New("AMQP_URL is required, for example amqp://guest:guest@localhost:5672/")
	}
	var err error
	if cfg.Workers, err = envconfig.PositiveInt(getenv, "WORKERS", 4); err != nil {
		return config{}, err
	}
	if cfg.QueueCapacity, err = envconfig.PositiveInt(getenv, "QUEUE_CAPACITY", 100); err != nil {
		return config{}, err
	}
	if cfg.MaxDeliveries, err = envconfig.PositiveInt(getenv, "MAX_DELIVERIES", 5); err != nil {
		return config{}, err
	}
	if cfg.JobTimeout, err = envconfig.Duration(getenv, "JOB_TIMEOUT", 10*time.Second); err != nil {
		return config{}, err
	}
	if cfg.ShutdownGrace, err = envconfig.Duration(getenv, "SHUTDOWN_GRACE", 10*time.Second); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	client, err := rabbit.Dial(cfg.AMQPURL, rabbit.Options{
		MaxLength:     cfg.QueueCapacity,
		MaxDeliveries: cfg.MaxDeliveries,
		Prefetch:      1,
	}, messages.CommandsQueue, messages.EventsQueue)
	if err != nil {
		return err
	}
	defer client.Close()

	handle := logged(logger, worker.New(client, jobs.Simulate, cfg.JobTimeout).Handle)

	stopConsuming, cancelConsuming := context.WithCancel(context.Background())
	defer cancelConsuming()
	consumerErr := make(chan error, cfg.Workers)
	var consumers sync.WaitGroup
	for range cfg.Workers {
		consumers.Add(1)
		go func() {
			defer consumers.Done()
			if err := client.Subscribe(stopConsuming, messages.CommandsQueue, handle); err != nil {
				consumerErr <- err
			}
		}()
	}
	logger.Info("worker ready", "consumers", cfg.Workers)

	var runErr error
	select {
	case <-ctx.Done():
	case runErr = <-consumerErr:
		logger.Error("lost the broker; shutting down", "error", runErr)
	}

	cancelConsuming()
	done := make(chan struct{})
	go func() {
		consumers.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(cfg.ShutdownGrace):
		logger.Warn("grace period over; unacknowledged commands will be redelivered")
	}
	logger.Info("stopped")
	return runErr
}

// logged wraps a handler with one log line per message handled.
func logged(logger *slog.Logger, next bus.Handler) bus.Handler {
	return func(ctx context.Context, msg messages.Envelope) error {
		start := time.Now()
		err := next(ctx, msg)
		errText := ""
		if err != nil {
			errText = err.Error()
		}
		logger.Info("command handled",
			"message_id", msg.ID,
			"type", msg.Type,
			"duration_ms", time.Since(start).Milliseconds(),
			"error", errText,
		)
		return err
	}
}
~~~

The worker's shutdown is simpler than the API's, and safer than step 1's. When the grace period runs out, the worker just exits. Every command it was holding was never acknowledged, so **the broker gives it to another worker**. Nothing is lost. The cost is that the job may run twice, and the next step deals with that.

Create `cmd/worker/main_test.go`:

<!-- file: cmd/worker/main_test.go -->
~~~go
package main

import (
	"context"
	"io"
	"strings"
	"testing"
)

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestAMQPURLIsRequired(t *testing.T) {
	_, err := loadConfig(env(nil))
	if err == nil || !strings.Contains(err.Error(), "AMQP_URL is required") {
		t.Fatalf("error = %v", err)
	}
}

func TestUnreachableBrokerFailsAtStartup(t *testing.T) {
	err := run(context.Background(), env(map[string]string{"AMQP_URL": "amqp://guest:guest@127.0.0.1:1/"}), io.Discard)
	if err == nil || !strings.Contains(err.Error(), "connect to RabbitMQ") {
		t.Fatalf("error = %v, want a connection error", err)
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

**Run it.** Three terminals, all in your practice folder, with RabbitMQ running from `docker compose up -d --wait`.

Terminal 1, the API:

~~~bash
AMQP_URL=amqp://guest:guest@localhost:5672/ go run ./cmd/api
~~~

Its first log line says `"bus":"rabbitmq","in_process_workers":0`.

Terminal 2, one worker:

~~~bash
AMQP_URL=amqp://guest:guest@localhost:5672/ WORKERS=1 go run ./cmd/worker
~~~

Terminal 3, a 4-second job:

~~~bash
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"resize","duration_ms":4000}'
~~~

About four seconds later, `curl -s http://127.0.0.1:8080/jobs/1` shows `"state":"completed"`, and the worker logs one line:

~~~text
{"time":"...","level":"INFO","msg":"command handled","message_id":"KZTR6QN7EWHIKAGBWJHAD4LEBE","type":"jobs.run_job","duration_ms":4034,"error":""}
~~~

Two processes, connected only through the broker. In the management UI (<http://localhost:15672>, *Queues and Streams*) you can see `jobs.commands`, `jobs.events` and their `.dead` queues, all of type `quorum`.

### The experiment: kill a worker in the middle of a job

This is the experiment Phase 2 exists for. Create another 4-second job (it gets ID 2). One second in, **kill the worker with SIGKILL** (Ctrl+C would be graceful; this is a crash):

~~~bash
curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"resize","duration_ms":4000}'
sleep 1; pkill -9 -f 'cmd/worker|/worker$'
curl -s http://127.0.0.1:8080/jobs/2
~~~

The job says `"state":"running"`, and nobody is running it. Wait as long as you like: it stays that way. In the management UI, `jobs.commands` now shows **1 Ready** message. The broker noticed the dead worker's connection close, and the command it never acknowledged went back on the queue. (The UI's counts refresh every few seconds, so they lag a little behind.)

Now start a new worker in terminal 2, exactly as before. About four seconds later its log shows it handling the same job, and the job is `completed`:

~~~text
job 2: running        (after the kill: nobody is working on it)
...start a new worker...
job 2: completed      (4 s later: the new worker ran it from the start)
~~~

**Nothing was lost, and no human intervened.** Compare step 1, where killing the process lost every queued job, and step 2, where messages lived in memory. Two things made it work: the command was persistent and confirmed when published, and it was acknowledged only after the work finished.

But look closely at *what* happened. The first worker had done one second of the work, then died. The second worker did **all four seconds again**. The job ran twice, and only the second run's result was recorded. That's at-least-once delivery in action. Here the duplicate is harmless, because `Simulate` has no side effects. In step 4 you'll make that safe even when work has real effects.

**Break it: what if acknowledgement came first?** In `deliver`, move `_ = d.Ack(false)` to the very top, before `handle` is called (and remove it from the success case). Repeat the kill experiment. Now the job stays `running` **forever**, even after you start a new worker: the broker deleted the command the moment it was delivered. That's **at-most-once** delivery: no duplicates, but crashes lose work. Restore the original order.

**Break it: the broker goes away.** With the API running, stop RabbitMQ: `docker compose stop rabbitmq`. The API logs `"lost the message bus; shutting down"` and exits with an error. That's the crash-only design working. Start RabbitMQ again (`docker compose start rabbitmq`) and then the API. The jobs the API held in memory are gone, but every command and event in the broker's queues survived the restart: they were durable and persistent. (Phase 3 makes the API's own records durable too.)

**Explain it:** what three things make a message survive a broker restart? Why does acknowledging *after* the work give at-least-once, and acknowledging *before* give at-most-once? When the worker was killed, why did the job run twice?

**Read.** The RabbitMQ documentation pages [*Consumer Acknowledgements and Publisher Confirms*](https://www.rabbitmq.com/docs/confirms) and [*Quorum Queues*](https://www.rabbitmq.com/docs/quorum-queues). Then DDIA Ch. 11, the section on message brokers. Carry this question in: what exactly does the broker guarantee, and what is left to your code?

---

## Step 4: Idempotency, end to end

**The problem.** Duplicates now come from three directions:

1. **Client → API.** A client sends `POST /jobs`, the network drops the response, and the client can't tell whether the job was created. If it retries, there may be two jobs. If it doesn't, there may be none.
2. **Broker → API.** Events can arrive twice. Step 2's state machine already makes that harmless.
3. **Broker → worker.** A worker that dies mid-job gets its command redelivered, so the *work* runs twice. You watched that happen in step 3.

Each direction needs its own defence. Stacked together, they make the system correct **in effect**, even though delivery is at-least-once everywhere.

**New ideas.**

- An **idempotency key** is a unique value the *client* chooses for one logical operation and sends with every retry of it: `Idempotency-Key: 9f1c...`. The server remembers the key with the response it gave. A retry with the same key gets the **same response** back, and the work isn't done again. Stripe's API popularised this, and an IETF draft standardises the header.
- A key is bound to *one* request. Reusing it with a different body is a client bug, answered with **422 Unprocessable Content**.
- If a retry arrives while the original is **still being processed**, the server can't replay a response it doesn't have yet. It answers **409 Conflict** with `Retry-After`.
- Only *final* answers are remembered. A 5xx means "something went wrong on our side", so the key is released and the client may retry for real.
- A **fingerprint** is a hash of the request (method, path, body) that identifies "the same request" cheaply. **SHA-256** is a cryptographic hash: any change to the input gives a completely different 32-byte output.
- Remembered keys **expire** after a while (here, 24 hours by default). Otherwise memory grows forever. Removing expired keys on a timer is a **background job**: work that runs on a schedule, not in response to a request.

~~~mermaid
sequenceDiagram
    participant C as Client
    participant M as Idempotency middleware
    participant H as createJob
    C->>M: POST /jobs, key K
    M->>M: K unknown: claim it (in progress)
    M->>H: handle
    H-->>M: 201 job 7
    M->>M: store K → 201 job 7
    M-->>C: 201 job 7 (response lost on the way)
    C->>M: POST /jobs, key K (retry)
    M-->>C: 201 job 7, Idempotent-Replayed: true
~~~

### The store and the middleware

Create `internal/idempotency/idempotency.go`:

<!-- file: internal/idempotency/idempotency.go -->
~~~go
// Package idempotency lets clients retry unsafe requests safely. A request
// that repeats an Idempotency-Key gets the original response back instead
// of doing the work a second time.
package idempotency

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

const (
	HeaderKey      = "Idempotency-Key"
	HeaderReplayed = "Idempotent-Replayed"
	maxKeyLength   = 255
)

var (
	ErrInProgress = errors.New("a request with this Idempotency-Key is still in progress")
	ErrMismatch   = errors.New("Idempotency-Key was already used for a different request")
)

// Response is what the server answered the first time.
type Response struct {
	Status int
	Header http.Header
	Body   []byte
}

type record struct {
	fingerprint [32]byte
	done        bool
	response    Response
	expires     time.Time
}

// Store remembers keys and their responses in memory until they expire.
type Store struct {
	ttl time.Duration
	now func() time.Time

	mu      sync.Mutex
	records map[string]*record
}

func NewStore(ttl time.Duration, now func() time.Time) *Store {
	return &Store{ttl: ttl, now: now, records: make(map[string]*record)}
}

// Begin claims key for a request with the given fingerprint. It returns the
// stored response if the same request already finished, ErrInProgress if it
// hasn't finished yet, ErrMismatch if the key belongs to a different
// request, or nil and nil if this request may go ahead.
func (s *Store) Begin(key string, fingerprint [32]byte) (*Response, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	r, ok := s.records[key]
	if ok && s.now().After(r.expires) {
		delete(s.records, key)
		ok = false
	}
	if !ok {
		s.records[key] = &record{fingerprint: fingerprint, expires: s.now().Add(s.ttl)}
		return nil, nil
	}
	if r.fingerprint != fingerprint {
		return nil, ErrMismatch
	}
	if !r.done {
		return nil, ErrInProgress
	}
	response := r.response
	return &response, nil
}

// Complete stores the final response for key.
func (s *Store) Complete(key string, response Response) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if r, ok := s.records[key]; ok {
		r.done = true
		r.response = response
	}
}

// Release forgets key, so the client may retry the request for real.
func (s *Store) Release(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.records, key)
}

// Sweep removes expired keys and reports how many it removed. Run it on a
// timer so memory doesn't grow without limit.
func (s *Store) Sweep() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	removed := 0
	for key, r := range s.records {
		if s.now().After(r.expires) {
			delete(s.records, key)
			removed++
		}
	}
	return removed
}

// Len is how many keys are remembered.
func (s *Store) Len() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.records)
}

// Middleware makes next idempotent for requests that carry an
// Idempotency-Key. Requests without one pass straight through.
func Middleware(store *Store, maxBodyBytes int64, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get(HeaderKey)
		if key == "" {
			next.ServeHTTP(w, r)
			return
		}
		if len(key) > maxKeyLength {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("%s must be at most %d characters", HeaderKey, maxKeyLength))
			return
		}

		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
		if err != nil {
			writeError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("request body must not exceed %d bytes", maxBodyBytes))
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))

		cached, err := store.Begin(key, fingerprint(r, body))
		switch {
		case errors.Is(err, ErrMismatch):
			writeError(w, http.StatusUnprocessableEntity, err.Error())
		case errors.Is(err, ErrInProgress):
			w.Header().Set("Retry-After", "1")
			writeError(w, http.StatusConflict, err.Error())
		case cached != nil:
			for name, values := range cached.Header {
				w.Header()[name] = values
			}
			w.Header().Set(HeaderReplayed, "true")
			w.WriteHeader(cached.Status)
			_, _ = w.Write(cached.Body)
		default:
			recorder := &responseRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(recorder, r)
			if recorder.status >= 500 {
				store.Release(key) // not a final answer: let the client retry
				return
			}
			store.Complete(key, Response{
				Status: recorder.status,
				Header: w.Header().Clone(),
				Body:   recorder.body.Bytes(),
			})
		}
	})
}

func fingerprint(r *http.Request, body []byte) [32]byte {
	h := sha256.New()
	fmt.Fprintf(h, "%s %s\n", r.Method, r.URL.Path)
	h.Write(body)
	var sum [32]byte
	copy(sum[:], h.Sum(nil))
	return sum
}

// responseRecorder passes a response through while keeping a copy of it.
type responseRecorder struct {
	http.ResponseWriter
	status int
	body   bytes.Buffer
}

func (r *responseRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *responseRecorder) Write(b []byte) (int, error) {
	r.body.Write(b)
	return r.ResponseWriter.Write(b)
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}
~~~

Things to notice:

- `Begin` does **claim, check and look up in one locked step**. Two copies of a request arriving together can't both see "unknown key": one claims it, and the other gets `ErrInProgress`. It's the same check-then-act lesson as Phase 1, solved the same way: decide and write under one lock.
- The body is read once to fingerprint it, then put back with `io.NopCloser(bytes.NewReader(body))`, so the real handler can read it again.
- `responseRecorder` writes the response through to the client **and** keeps a copy. It's the same embedding trick as Phase 1's `statusRecorder`.
- `w.Header().Clone()` captures the headers the handler set (`Content-Type`, `Location`), so the replay looks exactly like the original.

Create `internal/idempotency/idempotency_test.go`:

<!-- file: internal/idempotency/idempotency_test.go -->
~~~go
package idempotency

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// creator counts calls and answers like a real create handler.
func creator(calls *atomic.Int32, status int) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Location", fmt.Sprintf("/jobs/%d", n))
		w.WriteHeader(status)
		fmt.Fprintf(w, `{"id":%d}`, n)
	})
}

func post(h http.Handler, key, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(body))
	if key != "" {
		r.Header.Set(HeaderKey, key)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestRetryReplaysTheOriginalResponse(t *testing.T) {
	var calls atomic.Int32
	h := Middleware(NewStore(time.Hour, time.Now), 1024, creator(&calls, http.StatusCreated))

	first := post(h, "k1", `{"description":"x"}`)
	second := post(h, "k1", `{"description":"x"}`)

	if calls.Load() != 1 {
		t.Fatalf("handler ran %d times, want 1", calls.Load())
	}
	if second.Code != http.StatusCreated || second.Body.String() != first.Body.String() {
		t.Fatalf("replay = %d %q, want %d %q", second.Code, second.Body, first.Code, first.Body)
	}
	if second.Header().Get("Location") != "/jobs/1" || second.Header().Get(HeaderReplayed) != "true" {
		t.Fatalf("replay headers = %v", second.Header())
	}
}

func TestDifferentKeysAreDifferentRequests(t *testing.T) {
	var calls atomic.Int32
	h := Middleware(NewStore(time.Hour, time.Now), 1024, creator(&calls, http.StatusCreated))
	post(h, "k1", `{}`)
	post(h, "k2", `{}`)
	post(h, "", `{}`)
	post(h, "", `{}`)
	if calls.Load() != 4 {
		t.Fatalf("handler ran %d times, want 4", calls.Load())
	}
}

func TestReusedKeyWithDifferentBodyIsRejected(t *testing.T) {
	var calls atomic.Int32
	h := Middleware(NewStore(time.Hour, time.Now), 1024, creator(&calls, http.StatusCreated))
	post(h, "k1", `{"description":"x"}`)
	if got := post(h, "k1", `{"description":"y"}`); got.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422", got.Code)
	}
}

func TestServerErrorsAreNotRemembered(t *testing.T) {
	var calls atomic.Int32
	h := Middleware(NewStore(time.Hour, time.Now), 1024, creator(&calls, http.StatusServiceUnavailable))
	post(h, "k1", `{}`)
	post(h, "k1", `{}`)
	if calls.Load() != 2 {
		t.Fatalf("handler ran %d times; a 503 must let the client retry for real", calls.Load())
	}
}

func TestConcurrentCopiesRunOnce(t *testing.T) {
	var calls atomic.Int32
	release := make(chan struct{})
	slow := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		<-release
		w.WriteHeader(http.StatusCreated)
	})
	h := Middleware(NewStore(time.Hour, time.Now), 1024, slow)

	const copies = 10
	codes := make(chan int, copies)
	var wg sync.WaitGroup
	for range copies {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes <- post(h, "k1", `{}`).Code
		}()
	}
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()
	close(codes)

	counts := map[int]int{}
	for code := range codes {
		counts[code]++
	}
	if calls.Load() != 1 || counts[http.StatusCreated] != 1 || counts[http.StatusConflict] != copies-1 {
		t.Fatalf("calls = %d, statuses = %v; want 1 call, one 201 and %d 409s", calls.Load(), counts, copies-1)
	}
}

func TestKeysExpireAndAreSwept(t *testing.T) {
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	store := NewStore(time.Hour, clock)
	var calls atomic.Int32
	h := Middleware(store, 1024, creator(&calls, http.StatusCreated))

	post(h, "k1", `{}`)
	now = now.Add(2 * time.Hour)
	if removed := store.Sweep(); removed != 1 || store.Len() != 0 {
		t.Fatalf("Sweep removed %d, %d left; want 1 and 0", removed, store.Len())
	}
	post(h, "k1", `{}`)
	if calls.Load() != 2 {
		t.Fatalf("an expired key must not replay; handler ran %d times", calls.Load())
	}
}
~~~

`TestConcurrentCopiesRunOnce` holds the handler on a channel (`<-release`) so that all ten copies are in flight at once. Exactly one may run; the other nine must get 409. A fake clock (`clock` reads the variable `now`, which the test moves forward) tests expiry without waiting two hours.

<!-- run: go test -race ./internal/idempotency/... -->

### Wire it into the API

The middleware wraps only `POST /jobs`, the one unsafe route. `GET` is safe by definition and needs no key. In `internal/httpapi/handler.go`, add an option. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
type config struct {
	logger         *slog.Logger
	metrics        *Metrics
	requestTimeout time.Duration
}
~~~

to:

~~~go
type config struct {
	logger         *slog.Logger
	metrics        *Metrics
	requestTimeout time.Duration
	idempotency    *idempotency.Store
}

// WithIdempotency honours Idempotency-Key on POST /jobs, using store.
func WithIdempotency(store *idempotency.Store) Option {
	return func(c *config) { c.idempotency = store }
}
~~~

and change the route:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	mux.HandleFunc("POST /jobs", h.createJob)
~~~

to:

~~~go
	var create http.Handler = http.HandlerFunc(h.createJob)
	if cfg.idempotency != nil {
		create = idempotency.Middleware(cfg.idempotency, maxBodyBytes, create)
	}
	mux.Handle("POST /jobs", create)
~~~

and add the import. Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	"kestrel/internal/jobs"
)
~~~

to:

~~~go
	"kestrel/internal/idempotency"
	"kestrel/internal/jobs"
)
~~~

An end-to-end test through the real service proves a retried create makes **one** job. Add it at the end of `internal/httpapi/handler_test.go`:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
func TestRetriedCreateMakesOneJob(t *testing.T) {
	store := idempotency.NewStore(time.Hour, time.Now)
	h := newTestHandler(WithIdempotency(store))

	send := func() *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(`{"description":"resize"}`))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Idempotency-Key", "order-42")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	first, second := send(), send()

	if first.Code != http.StatusCreated || second.Code != http.StatusCreated || decode(t, second).ID != 1 {
		t.Fatalf("first %d, second %d %s", first.Code, second.Code, second.Body)
	}
	if got := do(t, h, http.MethodGet, "/jobs/2", ""); got.Code != http.StatusNotFound {
		t.Fatalf("a second job exists: GET /jobs/2 = %d", got.Code)
	}
}
~~~

That test needs the `time` and `idempotency` imports back. Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	"strings"
	"testing"

	"kestrel/internal/jobs"
~~~

to:

~~~go
	"strings"
	"testing"
	"time"

	"kestrel/internal/idempotency"
	"kestrel/internal/jobs"
~~~

<!-- run: go vet ./internal/... && go test -race ./internal/httpapi/... -->

### A background job: sweeping expired keys

`cmd/api` creates the store, passes it to the handler, and runs `Sweep` every minute until shutdown. In `cmd/api/main.go`, add the setting. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	MaxDeliveries  int
	JobTimeout     time.Duration
}
~~~

to:

~~~go
	MaxDeliveries  int
	JobTimeout     time.Duration
	IdempotencyTTL time.Duration
}
~~~

and change:

<!-- edit: cmd/api/main.go -->
~~~go
	if cfg.MaxDeliveries, err = envconfig.PositiveInt(getenv, "MAX_DELIVERIES", 5); err != nil {
		return config{}, err
	}
	return cfg, nil
~~~

to:

~~~go
	if cfg.MaxDeliveries, err = envconfig.PositiveInt(getenv, "MAX_DELIVERIES", 5); err != nil {
		return config{}, err
	}
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
		return config{}, err
	}
	return cfg, nil
~~~

Create the store and pass it to the handler. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
	)
~~~

to:

~~~go
	keys := idempotency.NewStore(cfg.IdempotencyTTL, time.Now)
	metrics.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "idempotency_keys",
		Help: "Idempotency keys currently remembered.",
	}, func() float64 { return float64(keys.Len()) }))

	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
		httpapi.WithIdempotency(keys),
	)
~~~

Start the sweeper next to the consumers. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	consume(messages.EventsQueue, eventing.NewEventHandler(service))
~~~

to:

~~~go
	consume(messages.EventsQueue, eventing.NewEventHandler(service))

	// A background job: forget expired idempotency keys once a minute.
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-stopConsuming.Done():
				return
			case <-ticker.C:
				if removed := keys.Sweep(); removed > 0 {
					logger.Info("swept idempotency keys", "removed", removed)
				}
			}
		}
	}()
~~~

and add the import. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"kestrel/internal/httpapi"
	"kestrel/internal/jobs"
	"kestrel/internal/memstore"
	"kestrel/internal/messages"
	"kestrel/internal/rabbit"
~~~

to:

~~~go
	"kestrel/internal/httpapi"
	"kestrel/internal/idempotency"
	"kestrel/internal/jobs"
	"kestrel/internal/memstore"
	"kestrel/internal/messages"
	"kestrel/internal/rabbit"
~~~

`time.NewTicker` sends the current time on its channel `C` at a fixed interval. The `select` waits for the next tick *or* shutdown, the same shape as `Simulate`. The ticker is stopped with `defer`, so it doesn't keep running after the goroutine exits.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

**Run it.** Start the API in its in-memory mode (`go run ./cmd/api`), then send the same request twice with the same key:

~~~bash
for i in 1 2; do
  curl -s -i -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: order-42' -d '{"description":"resize","duration_ms":100}'
done
~~~

The interesting lines from each response:

~~~text
HTTP/1.1 201 Created
Location: /jobs/1
{"id":1,"state":"queued","description":"resize",...}

HTTP/1.1 201 Created
Idempotent-Replayed: true
Location: /jobs/1
{"id":1,"state":"queued","description":"resize",...}
~~~

The second response is the first one, replayed, and `GET /jobs/2` returns 404: only one job exists. Notice the replay still says `"state":"queued"`, even though job 1 has long since completed. A replay is the **original answer**, not the current state. The client asked "did my create happen?", and the answer is "yes, and here's exactly what I told you then". To see the job now, it calls `GET /jobs/1`.

Reuse the key with a different body:

~~~bash
curl -s -i -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: order-42' -d '{"description":"thumbnail"}'
~~~

~~~text
HTTP/1.1 422 Unprocessable Entity
{"error":"Idempotency-Key was already used for a different request"}
~~~

`curl -s http://127.0.0.1:8080/metrics | grep idempotency_keys` shows `idempotency_keys 1`.

**Break it.** In `Begin`, delete the fingerprint check (`if r.fingerprint != fingerprint { return nil, ErrMismatch }`) and run `go test ./internal/idempotency/`:

~~~text
--- FAIL: TestReusedKeyWithDifferentBodyIsRejected (0.00s)
    idempotency_test.go:70: status = 201, want 422
~~~

Without the fingerprint, a client that reuses a key by mistake for a *different* job gets a reply about the old job, a cheerful 201 for work that was never done. Silent wrong answers are the worst kind. Restore the check.

### The three defences, together

| Duplicate from | Defence | Where |
|---|---|---|
| Client retries `POST /jobs` | Idempotency key: replay the stored response | `internal/idempotency`, step 4 |
| Broker redelivers an event to the API | Idempotent receiver: the state machine ignores what's already applied | `jobs.Service.transition`, step 2 |
| Broker redelivers a command to a worker | Make the **work** idempotent: running it twice must give the same result as once | The work itself (see below) |

The last row is the hardest, and no library solves it. A worker can't reliably remember "I already did this" in its own memory: the worker that did it is the one that crashed. The work itself must be safe to repeat. The usual techniques:

- **Write results keyed by the job's ID** (an upsert: "set the result for job 7"), never append ("add another result").
- **Pass an idempotency key to anything with side effects.** A payment provider, an email service and a webhook receiver can each deduplicate if you send the same key on a retry. Here, the job ID plus the step name would do.
- **Record "done" and the effect in one transaction.** That needs a database, and it's called the **inbox** pattern: a table of processed message IDs, written in the same transaction as the effect. Phase 3 builds it.

Remember this the next time someone says their system has "exactly-once processing". Ask which of these three they built.

**Limits of this step.** Keys live in the API's memory, so they're lost on restart and not shared between API instances. Two copies of the API behind a load balancer would each have their own keys. Phase 3 moves them into PostgreSQL, where a unique constraint does the claiming.

**Explain it:** why must claiming the key and checking it happen under one lock? Why are 5xx responses not remembered? Of the three defences, which needs a database to be fully correct, and why?

**Read.** Stripe's engineering post [*Designing robust and predictable APIs with idempotency*](https://stripe.com/blog/idempotency), and the IETF draft [*The Idempotency-Key HTTP Header Field*](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/). Carry this question in: how long should a key be remembered, and what does that choice trade off?

---

## Step 5: Retries, versioning, dead letters and a circuit breaker

**The problem.** Real work fails for passing reasons: a network blip, a dependency that's restarting, a lock held a moment too long. The worker should try again. But retrying badly is dangerous:

- retrying instantly hammers a struggling dependency;
- retrying in lockstep (every client retrying at the same moment) turns a blip into a stampede;
- retrying forever never gives up.

On the other side, when the broker is in trouble, the API shouldn't make every caller wait two seconds to find out. It should **fail fast** until the broker recovers.

**New ideas.**

- A **transient** failure might succeed if tried again. A **permanent** one never will (a malformed message, a validation error). Only retry transient failures.
- **Exponential backoff**: wait longer before each retry (100 ms, 200 ms, 400 ms, ...) up to a cap, giving the dependency room to recover.
- **Jitter**: randomise each wait. With "full jitter", the wait is a random value between 0 and the backoff ceiling. Without jitter, a thousand clients that failed together retry together, again and again: a **thundering herd**. AWS's analysis found full jitter does the least total work while finishing fastest.
- **A retry budget**: a fixed number of attempts, and all of them inside the job's deadline. Retries never extend a deadline; they spend it.
- **Message versioning.** The `RunJob` command gains a field, `max_attempts`, so the API can decide how many attempts each job gets. That changes what the message *means*, so it becomes **version 2**. Readers must still accept version 1: messages already sitting in the queue were written by the old code. Filling in a default for an old message is called **upcasting**. And because old readers reject the new version, the deployment order matters: **upgrade readers (workers) before writers (the API).**
- A **circuit breaker**, named after the electrical kind, wraps calls to a dependency:
  - **Closed:** calls go through and failures are counted.
  - **Open:** after too many failures in a row, calls fail at once without even trying, so callers don't wait and the dependency gets a rest.
  - **Half-open:** after a cool-down, *one* trial call is let through. Success closes the breaker; failure opens it again.

~~~mermaid
stateDiagram-v2
    [*] --> Closed
    Closed --> Open: failures reach the threshold
    Open --> HalfOpen: cool-down passes
    HalfOpen --> Closed: the trial call succeeds
    HalfOpen --> Open: the trial call fails
~~~

### Retry with backoff and jitter

Create `internal/retry/retry.go`:

<!-- file: internal/retry/retry.go -->
~~~go
// Package retry runs an operation again after transient failures. Each wait
// is longer than the last (exponential backoff) and random (full jitter), so
// many callers that failed together don't all retry at the same moment.
package retry

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"time"
)

type stopError struct{ err error }

func (s stopError) Error() string { return s.err.Error() }
func (s stopError) Unwrap() error { return s.err }

// Stop marks an error that retrying cannot fix. Do returns it at once.
func Stop(err error) error { return stopError{err} }

// Policy says how many times to try and how long to wait in between.
type Policy struct {
	Attempts int           // total tries, including the first
	Base     time.Duration // the ceiling for the first wait
	Max      time.Duration // the largest ceiling for any wait

	// Rand returns a number in [0, 1). Sleep waits, or stops early when ctx
	// is done. Both default to the real thing; tests replace them.
	Rand  func() float64
	Sleep func(ctx context.Context, d time.Duration) error
}

// Backoff returns the wait before retry n (n = 1 is the first retry): a
// random duration between 0 and min(Max, Base × 2^(n-1)).
func (p Policy) Backoff(n int) time.Duration {
	ceiling := p.Base
	for i := 1; i < n && ceiling < p.Max; i++ {
		ceiling *= 2
	}
	ceiling = min(ceiling, p.Max)
	random := p.Rand
	if random == nil {
		random = rand.Float64
	}
	return time.Duration(random() * float64(ceiling))
}

// Do calls op until it succeeds, returns a Stop error, runs out of
// attempts, or ctx is done. It returns nil, or the error that ended it.
func (p Policy) Do(ctx context.Context, op func(ctx context.Context) error) error {
	sleep := p.Sleep
	if sleep == nil {
		sleep = sleepContext
	}
	var err error
	for attempt := 1; attempt <= p.Attempts; attempt++ {
		if err = op(ctx); err == nil {
			return nil
		}
		var stop stopError
		if errors.As(err, &stop) {
			return stop.err
		}
		if attempt == p.Attempts {
			break
		}
		if sleepErr := sleep(ctx, p.Backoff(attempt)); sleepErr != nil {
			return fmt.Errorf("%w (stopped retrying: %w)", err, sleepErr)
		}
	}
	return fmt.Errorf("failed after %d attempts: %w", p.Attempts, err)
}

func sleepContext(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
~~~

- The `for` loop in `Backoff` doubles the ceiling instead of computing `Base << (n-1)`. A shift by a large `n` would overflow, and `ceiling < p.Max` stops the doubling as soon as the cap is reached.
- `min` is a built-in function (Go 1.21 and later).
- `math/rand/v2` gives a fast random number that is **not** cryptographically secure. That's fine for jitter, unlike message IDs, which used `crypto/rand`.
- `Rand` and `Sleep` are injectable. Tests use a fixed "random" number and a sleep that only records the wait, so they're fast and **deterministic**.

Create `internal/retry/retry_test.go`:

<!-- file: internal/retry/retry_test.go -->
~~~go
package retry

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestBackoffCeilingsDoubleUpToMax(t *testing.T) {
	p := Policy{Base: 100 * time.Millisecond, Max: time.Second, Rand: func() float64 { return 0.999999 }}
	want := []time.Duration{100, 200, 400, 800, 1000, 1000}
	for n, ceiling := range want {
		got := p.Backoff(n + 1)
		if got > ceiling*time.Millisecond || got < ceiling*time.Millisecond*99/100 {
			t.Errorf("retry %d: wait %v, want just under %v", n+1, got, ceiling*time.Millisecond)
		}
	}
	if got := (Policy{Base: time.Second, Max: time.Minute, Rand: func() float64 { return 0.5 }}).Backoff(1000); got != 30*time.Second {
		t.Errorf("huge n: %v, want half of Max with no overflow", got)
	}
}

func TestJitterSpreadsTheWaits(t *testing.T) {
	p := Policy{Base: time.Second, Max: time.Second, Rand: func() float64 { return 0 }}
	if got := p.Backoff(1); got != 0 {
		t.Errorf("with Rand=0, wait = %v, want 0", got)
	}
}

func fastPolicy(attempts int, waits *[]time.Duration) Policy {
	return Policy{
		Attempts: attempts, Base: 100 * time.Millisecond, Max: time.Second,
		Rand: func() float64 { return 0.5 },
		Sleep: func(_ context.Context, d time.Duration) error {
			*waits = append(*waits, d)
			return nil
		},
	}
}

func TestSucceedsAfterTransientFailures(t *testing.T) {
	var waits []time.Duration
	calls := 0
	err := fastPolicy(5, &waits).Do(context.Background(), func(context.Context) error {
		calls++
		if calls < 3 {
			return errors.New("blip")
		}
		return nil
	})
	if err != nil || calls != 3 {
		t.Fatalf("err = %v, calls = %d; want success on the 3rd call", err, calls)
	}
	if len(waits) != 2 || waits[0] != 50*time.Millisecond || waits[1] != 100*time.Millisecond {
		t.Fatalf("waits = %v, want [50ms 100ms]", waits)
	}
}

func TestGivesUpAfterTheLastAttempt(t *testing.T) {
	var waits []time.Duration
	blip := errors.New("blip")
	err := fastPolicy(3, &waits).Do(context.Background(), func(context.Context) error { return blip })
	if !errors.Is(err, blip) || err.Error() != "failed after 3 attempts: blip" || len(waits) != 2 {
		t.Fatalf("err = %v, waits = %d", err, len(waits))
	}
}

func TestStopEndsAtOnce(t *testing.T) {
	var waits []time.Duration
	bad := errors.New("invalid input")
	calls := 0
	err := fastPolicy(5, &waits).Do(context.Background(), func(context.Context) error {
		calls++
		return Stop(bad)
	})
	if err != bad || calls != 1 {
		t.Fatalf("err = %v, calls = %d; want the unwrapped error after 1 call", err, calls)
	}
}

func TestCancelledContextStopsTheWait(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	p := Policy{Attempts: 3, Base: time.Hour, Max: time.Hour}
	start := time.Now()
	err := p.Do(ctx, func(context.Context) error { return errors.New("blip") })
	if !errors.Is(err, context.Canceled) || time.Since(start) > time.Second {
		t.Fatalf("err = %v after %v; want a prompt cancellation", err, time.Since(start))
	}
}
~~~

<!-- run: go test ./internal/retry/... -->

### Version 2 of RunJob

In `internal/messages/messages.go`, add the field and the default. Change:

<!-- edit: internal/messages/messages.go -->
~~~go
// RunJob is the command that asks a worker to run a job.
type RunJob struct {
	JobID       int64  `json:"job_id"`
	Description string `json:"description"`
	DurationMS  int64  `json:"duration_ms"`
}
~~~

to:

~~~go
// DefaultMaxAttempts is how many tries a job gets when its command doesn't
// say: version 1 of RunJob had no max_attempts field.
const DefaultMaxAttempts = 3

// RunJob is the command that asks a worker to run a job. Version 2 added
// MaxAttempts.
type RunJob struct {
	JobID       int64  `json:"job_id"`
	Description string `json:"description"`
	DurationMS  int64  `json:"duration_ms"`
	MaxAttempts int    `json:"max_attempts"`
}

// current is the newest version of each message type. New writes it, and
// Decode accepts every version from 1 up to it.
var current = map[string]int{
	TypeRunJob:       2,
	TypeJobStarted:   1,
	TypeJobCompleted: 1,
	TypeJobFailed:    1,
}

func versionOf(msgType string) int {
	if v, ok := current[msgType]; ok {
		return v
	}
	return 1
}
~~~

Make `New` write the current version, and `Decode` accept every version up to it. Change:

<!-- edit: internal/messages/messages.go -->
~~~go
// New wraps payload in a version-1 envelope with a fresh, random ID.
func New(msgType string, payload any, now time.Time) (Envelope, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return Envelope{}, fmt.Errorf("encode %s: %w", msgType, err)
	}
	return Envelope{ID: rand.Text(), Type: msgType, Version: 1, OccurredAt: now.UTC(), Payload: body}, nil
}
~~~

to:

~~~go
// New wraps payload in an envelope of the type's current version, with a
// fresh, random ID.
func New(msgType string, payload any, now time.Time) (Envelope, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return Envelope{}, fmt.Errorf("encode %s: %w", msgType, err)
	}
	return Envelope{ID: rand.Text(), Type: msgType, Version: versionOf(msgType), OccurredAt: now.UTC(), Payload: body}, nil
}
~~~

and change:

<!-- edit: internal/messages/messages.go -->
~~~go
	if env.Version != 1 {
		return fmt.Errorf("%w: %s version %d", ErrUnsupported, env.Type, env.Version)
	}
~~~

to:

~~~go
	if env.Version < 1 || env.Version > versionOf(wantType) {
		return fmt.Errorf("%w: %s version %d", ErrUnsupported, env.Type, env.Version)
	}
~~~

Then add a decoder that **upcasts** version 1 at the end of the file:

<!-- append: internal/messages/messages.go -->
~~~go
// DecodeRunJob reads a RunJob command of any supported version. Version 1
// had no MaxAttempts, so it gets DefaultMaxAttempts: this is upcasting, so
// the rest of the code only ever sees the newest shape.
func DecodeRunJob(env Envelope) (RunJob, error) {
	var cmd RunJob
	if err := Decode(env, TypeRunJob, &cmd); err != nil {
		return RunJob{}, err
	}
	if env.Version == 1 || cmd.MaxAttempts < 1 {
		cmd.MaxAttempts = DefaultMaxAttempts
	}
	return cmd, nil
}
~~~

`RunJob` envelopes are now version 2, so the round-trip test's version check changes. In `internal/messages/messages_test.go`, change:

<!-- edit: internal/messages/messages_test.go -->
~~~go
	if received.ID == "" || received.ID != msg.ID || received.Version != 1 || !received.OccurredAt.Equal(now) {
~~~

to:

~~~go
	if received.ID == "" || received.ID != msg.ID || received.Version != 2 || !received.OccurredAt.Equal(now) {
~~~

And test both versions. A version 1 message is written *by hand*, exactly as old code would have produced it. Add at the end of `internal/messages/messages_test.go`:

<!-- append: internal/messages/messages_test.go -->
~~~go
func TestVersion1RunJobIsUpcast(t *testing.T) {
	old := Envelope{Type: TypeRunJob, Version: 1, Payload: json.RawMessage(`{"job_id":5,"description":"x","duration_ms":10}`)}
	cmd, err := DecodeRunJob(old)
	if err != nil {
		t.Fatalf("a version 1 message already in the queue must still be readable: %v", err)
	}
	if cmd.MaxAttempts != DefaultMaxAttempts {
		t.Fatalf("MaxAttempts = %d, want the default %d", cmd.MaxAttempts, DefaultMaxAttempts)
	}
}

func TestVersion2RunJobKeepsItsMaxAttempts(t *testing.T) {
	msg, _ := New(TypeRunJob, RunJob{JobID: 5, MaxAttempts: 7}, now)
	cmd, err := DecodeRunJob(msg)
	if err != nil || cmd.MaxAttempts != 7 {
		t.Fatalf("cmd = %+v, err = %v", cmd, err)
	}
}

func TestVersion3IsNotUnderstoodYet(t *testing.T) {
	future := Envelope{Type: TypeRunJob, Version: 3, Payload: json.RawMessage(`{}`)}
	if _, err := DecodeRunJob(future); !errors.Is(err, ErrUnsupported) {
		t.Fatalf("error = %v, want ErrUnsupported", err)
	}
}
~~~

The dispatcher writes version 2 with the default number of attempts. In `internal/eventing/eventing.go`, change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
		DurationMS:  job.Duration.Milliseconds(),
	}, d.now())
~~~

to:

~~~go
		DurationMS:  job.Duration.Milliseconds(),
		MaxAttempts: messages.DefaultMaxAttempts,
	}, d.now())
~~~

<!-- run: go test ./internal/messages/... ./internal/eventing/... -->

### The worker retries its work

Give the worker a retry policy, and a way to *inject* failures so you can watch retries happen. Deliberately injecting failures to test how a system copes is the core idea of **chaos engineering**. Replace `internal/worker/worker.go`:

<!-- file: internal/worker/worker.go -->
~~~go
// Package worker runs jobs it receives as RunJob commands and reports what
// happened as events. It owns no job records: the API does.
package worker

import (
	"context"
	"errors"
	"time"

	"kestrel/internal/bus"
	"kestrel/internal/jobs"
	"kestrel/internal/messages"
	"kestrel/internal/retry"
)

// ErrTransient is the failure Flaky injects.
var ErrTransient = errors.New("transient failure")

// Flaky wraps work so each call fails with ErrTransient with probability
// rate. It exists to practise failure handling.
func Flaky(work jobs.WorkFunc, rate float64, random func() float64) jobs.WorkFunc {
	return func(ctx context.Context, job jobs.Job) error {
		if random() < rate {
			return ErrTransient
		}
		return work(ctx, job)
	}
}

type Worker struct {
	events     bus.Publisher
	work       jobs.WorkFunc
	jobTimeout time.Duration
	retry      retry.Policy
	now        func() time.Time
}

// Option changes one setting of a Worker.
type Option func(*Worker)

// WithRetry replaces the retry policy's timing. The number of attempts
// always comes from each command.
func WithRetry(p retry.Policy) Option {
	return func(w *Worker) { w.retry = p }
}

func New(events bus.Publisher, work jobs.WorkFunc, jobTimeout time.Duration, opts ...Option) *Worker {
	w := &Worker{
		events:     events,
		work:       work,
		jobTimeout: jobTimeout,
		retry:      retry.Policy{Base: 100 * time.Millisecond, Max: 2 * time.Second},
		now:        time.Now,
	}
	for _, opt := range opts {
		opt(w)
	}
	return w
}

// Handle is a bus.Handler for the commands queue.
//
// The work is retried with backoff, within the job's deadline, up to the
// command's MaxAttempts. If publishing an event fails, Handle returns the
// error so the command is redelivered; the API's idempotent handlers make a
// repeated run harmless.
func (w *Worker) Handle(ctx context.Context, msg messages.Envelope) error {
	cmd, err := messages.DecodeRunJob(msg)
	if err != nil {
		return bus.Permanent(err) // no retry can fix a message we can't read
	}
	if err := w.emit(ctx, messages.TypeJobStarted, messages.JobStarted{JobID: cmd.JobID}); err != nil {
		return err
	}

	job := jobs.Job{
		ID:          jobs.ID(cmd.JobID),
		Description: jobs.Description(cmd.Description),
		Duration:    time.Duration(cmd.DurationMS) * time.Millisecond,
	}
	jobCtx, cancel := context.WithTimeout(ctx, w.jobTimeout)
	defer cancel()

	policy := w.retry
	policy.Attempts = cmd.MaxAttempts
	err = policy.Do(jobCtx, func(ctx context.Context) error {
		err := w.work(ctx, job)
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
			return retry.Stop(err) // out of time: another try can't help
		}
		return err
	})
	if err != nil {
		failed := messages.JobFailed{JobID: cmd.JobID, Reason: jobs.FailureReason(err)}
		return w.emit(ctx, messages.TypeJobFailed, failed)
	}
	return w.emit(ctx, messages.TypeJobCompleted, messages.JobCompleted{JobID: cmd.JobID})
}

func (w *Worker) emit(ctx context.Context, msgType string, payload any) error {
	msg, err := messages.New(msgType, payload, w.now())
	if err != nil {
		return bus.Permanent(err)
	}
	return w.events.Publish(ctx, messages.EventsQueue, msg)
}
~~~

Version 2 is now valid, so the "unreadable command" test needs a version the worker truly can't read. In `internal/worker/worker_test.go`, change:

<!-- edit: internal/worker/worker_test.go -->
~~~go
	bad.Version = 2
~~~

to:

~~~go
	bad.Version = 3
~~~

And test the retries. Add at the end of `internal/worker/worker_test.go`:

<!-- append: internal/worker/worker_test.go -->
~~~go
func noWait() Option {
	return WithRetry(retry.Policy{Sleep: func(context.Context, time.Duration) error { return nil }})
}

// failingTimes returns work that fails n times, then succeeds.
func failingTimes(n int, calls *int) jobs.WorkFunc {
	return func(context.Context, jobs.Job) error {
		*calls++
		if *calls <= n {
			return ErrTransient
		}
		return nil
	}
}

func TestTransientFailuresAreRetried(t *testing.T) {
	events := &recorder{}
	calls := 0
	w := New(events, failingTimes(2, &calls), time.Second, noWait())

	if err := w.Handle(context.Background(), runJob(t, 0)); err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if calls != 3 || events.types()[1] != messages.TypeJobCompleted {
		t.Fatalf("calls = %d, events = %v; want success on the 3rd try", calls, events.types())
	}
}

func TestTooManyFailuresReportTheJobFailed(t *testing.T) {
	events := &recorder{}
	calls := 0
	w := New(events, failingTimes(99, &calls), time.Second, noWait())

	_ = w.Handle(context.Background(), runJob(t, 0))
	var failed messages.JobFailed
	if err := messages.Decode(events.sent[1], messages.TypeJobFailed, &failed); err != nil {
		t.Fatal(err)
	}
	if calls != messages.DefaultMaxAttempts || failed.Reason != "failed after 3 attempts: transient failure" {
		t.Fatalf("calls = %d, reason = %q", calls, failed.Reason)
	}
}

func TestFlakyFailsAtTheGivenRate(t *testing.T) {
	values := []float64{0.1, 0.9, 0.2, 0.7}
	i := 0
	random := func() float64 { v := values[i%len(values)]; i++; return v }
	work := Flaky(func(context.Context, jobs.Job) error { return nil }, 0.5, random)

	var failures int
	for range values {
		if work(context.Background(), jobs.Job{}) != nil {
			failures++
		}
	}
	if failures != 2 {
		t.Fatalf("failures = %d, want 2 of 4 at rate 0.5", failures)
	}
}
~~~

That file needs the `retry` package. Change its imports:

<!-- edit: internal/worker/worker_test.go -->
~~~go
	"kestrel/internal/messages"
)
~~~

to:

~~~go
	"kestrel/internal/messages"
	"kestrel/internal/retry"
)
~~~

<!-- run: go test -race ./internal/worker/... -->

To inject failures from the command line, the worker reads `FAIL_RATE`, a fraction between 0 and 1. Add a reader for fractions at the end of `internal/envconfig/envconfig.go`:

<!-- append: internal/envconfig/envconfig.go -->
~~~go
// Fraction reads a number between 0 and 1 inclusive.
func Fraction(getenv Getenv, name string, fallback float64) (float64, error) {
	v := getenv(name)
	if v == "" {
		return fallback, nil
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil || f < 0 || f > 1 {
		return 0, fmt.Errorf("%s must be a number from 0 to 1, got %q", name, v)
	}
	return f, nil
}
~~~

In `cmd/worker/main.go`, add the setting. Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	JobTimeout    time.Duration
	ShutdownGrace time.Duration
}
~~~

to:

~~~go
	JobTimeout    time.Duration
	ShutdownGrace time.Duration
	FailRate      float64
}
~~~

and change:

<!-- edit: cmd/worker/main.go -->
~~~go
	if cfg.ShutdownGrace, err = envconfig.Duration(getenv, "SHUTDOWN_GRACE", 10*time.Second); err != nil {
		return config{}, err
	}
	return cfg, nil
~~~

to:

~~~go
	if cfg.ShutdownGrace, err = envconfig.Duration(getenv, "SHUTDOWN_GRACE", 10*time.Second); err != nil {
		return config{}, err
	}
	if cfg.FailRate, err = envconfig.Fraction(getenv, "FAIL_RATE", 0); err != nil {
		return config{}, err
	}
	return cfg, nil
~~~

and wrap the work when the rate is above zero. Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	handle := logged(logger, worker.New(client, jobs.Simulate, cfg.JobTimeout).Handle)
~~~

to:

~~~go
	work := jobs.Simulate
	if cfg.FailRate > 0 {
		work = worker.Flaky(work, cfg.FailRate, rand.Float64)
		logger.Warn("injecting failures", "fail_rate", cfg.FailRate)
	}
	handle := logged(logger, worker.New(client, work, cfg.JobTimeout).Handle)
~~~

with the import:

<!-- edit: cmd/worker/main.go -->
~~~go
	"log/slog"
	"os"
~~~

to:

~~~go
	"log/slog"
	"math/rand/v2"
	"os"
~~~

<!-- run: go vet ./cmd/... ./internal/envconfig/... && go test ./cmd/worker/... ./internal/envconfig/... -->

### A circuit breaker around dispatch

Create `internal/breaker/breaker.go`:

<!-- file: internal/breaker/breaker.go -->
~~~go
// Package breaker stops calling a dependency that keeps failing, so callers
// fail fast instead of waiting, and the dependency gets time to recover.
package breaker

import (
	"context"
	"errors"
	"sync"
	"time"

	"kestrel/internal/jobs"
)

// ErrOpen means the breaker refused the call without trying it.
var ErrOpen = errors.New("circuit breaker is open")

type State int

const (
	Closed   State = iota // calls go through; failures are counted
	Open                  // calls fail at once
	HalfOpen              // one trial call is allowed through
)

func (s State) String() string {
	return [...]string{"closed", "open", "half-open"}[s]
}

type Breaker struct {
	threshold int
	cooldown  time.Duration
	now       func() time.Time

	mu       sync.Mutex
	state    State
	failures int
	openedAt time.Time
}

// New returns a breaker that opens after threshold failures in a row, and
// lets a trial call through once cooldown has passed.
func New(threshold int, cooldown time.Duration, now func() time.Time) *Breaker {
	return &Breaker{threshold: threshold, cooldown: cooldown, now: now}
}

// Do calls fn unless the breaker is open, and records how it went.
func (b *Breaker) Do(fn func() error) error {
	if err := b.allow(); err != nil {
		return err
	}
	err := fn()
	b.record(err)
	return err
}

func (b *Breaker) allow() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	switch b.state {
	case Open:
		if b.now().Sub(b.openedAt) < b.cooldown {
			return ErrOpen
		}
		b.state = HalfOpen // this caller makes the one trial call
		return nil
	case HalfOpen:
		return ErrOpen // a trial is already in flight
	default:
		return nil
	}
}

func (b *Breaker) record(err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if err == nil {
		b.state, b.failures = Closed, 0
		return
	}
	b.failures++
	if b.state == HalfOpen || b.failures >= b.threshold {
		b.state, b.openedAt = Open, b.now()
	}
}

// State reports the breaker's current state.
func (b *Breaker) State() State {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.state
}

// Dispatcher wraps a jobs.Dispatcher with a breaker.
type Dispatcher struct {
	Next    jobs.Dispatcher
	Breaker *Breaker
}

func (d Dispatcher) Dispatch(ctx context.Context, job jobs.Job) error {
	return d.Breaker.Do(func() error { return d.Next.Dispatch(ctx, job) })
}
~~~

- `iota` numbers constants automatically: `Closed` is 0, `Open` 1, `HalfOpen` 2. `String()` makes them print as words in logs.
- The breaker counts failures **in a row**: any success resets the count.
- In `allow`, the first caller after the cool-down *becomes* the trial (the state moves to half-open), and everyone else gets `ErrOpen` until the trial finishes. Deciding that under the lock means only one trial ever runs.
- `Dispatcher` is a decorator again: it's a `jobs.Dispatcher` wrapping another `jobs.Dispatcher`. The service can't tell it's there.

Create `internal/breaker/breaker_test.go`:

<!-- file: internal/breaker/breaker_test.go -->
~~~go
package breaker

import (
	"errors"
	"testing"
	"time"
)

var boom = errors.New("boom")

type clock struct{ t time.Time }

func (c *clock) now() time.Time          { return c.t }
func (c *clock) advance(d time.Duration) { c.t = c.t.Add(d) }

func TestOpensAfterThresholdAndFailsFast(t *testing.T) {
	c := &clock{t: time.Now()}
	b := New(3, time.Minute, c.now)

	for range 3 {
		_ = b.Do(func() error { return boom })
	}
	if b.State() != Open {
		t.Fatalf("state = %v after 3 failures, want open", b.State())
	}
	called := false
	if err := b.Do(func() error { called = true; return nil }); !errors.Is(err, ErrOpen) || called {
		t.Fatalf("err = %v, called = %v; an open breaker must not call through", err, called)
	}
}

func TestSuccessResetsTheCount(t *testing.T) {
	b := New(3, time.Minute, time.Now)
	_ = b.Do(func() error { return boom })
	_ = b.Do(func() error { return boom })
	_ = b.Do(func() error { return nil })
	_ = b.Do(func() error { return boom })
	if b.State() != Closed {
		t.Fatalf("state = %v; failures must be in a row to open", b.State())
	}
}

func TestHalfOpenTrialClosesOrReopens(t *testing.T) {
	c := &clock{t: time.Now()}
	b := New(1, time.Minute, c.now)
	_ = b.Do(func() error { return boom })

	c.advance(time.Minute)
	_ = b.Do(func() error { return boom }) // the trial fails
	if b.State() != Open {
		t.Fatalf("state = %v after a failed trial, want open", b.State())
	}

	c.advance(time.Minute)
	if err := b.Do(func() error { return nil }); err != nil || b.State() != Closed {
		t.Fatalf("err = %v, state = %v after a good trial, want closed", err, b.State())
	}
}

func TestOnlyOneTrialAtATime(t *testing.T) {
	c := &clock{t: time.Now()}
	b := New(1, time.Minute, c.now)
	_ = b.Do(func() error { return boom })
	c.advance(time.Minute)

	_ = b.Do(func() error {
		if err := b.Do(func() error { return nil }); !errors.Is(err, ErrOpen) {
			t.Errorf("a second call during the trial got %v, want ErrOpen", err)
		}
		return nil
	})
}
~~~

`TestOnlyOneTrialAtATime` makes a second call **from inside** the trial call, which is a neat way to be sure the trial is still in flight.

<!-- run: go test -race ./internal/breaker/... -->

Wire the breaker into the API. In `cmd/api/main.go`, add the settings. The new, longer field names make `gofmt` re-align the whole struct, so here is all of it. Change:

<!-- edit: cmd/api/main.go -->
~~~go
type config struct {
	ListenAddr     string
	AMQPURL        string
	RequestTimeout time.Duration
	ShutdownGrace  time.Duration
	Workers        int
	QueueCapacity  int
	MaxDeliveries  int
	JobTimeout     time.Duration
	IdempotencyTTL time.Duration
}
~~~

to:

~~~go
type config struct {
	ListenAddr       string
	AMQPURL          string
	RequestTimeout   time.Duration
	ShutdownGrace    time.Duration
	Workers          int
	QueueCapacity    int
	MaxDeliveries    int
	JobTimeout       time.Duration
	IdempotencyTTL   time.Duration
	BreakerThreshold int
	BreakerCooldown  time.Duration
}
~~~

and change:

<!-- edit: cmd/api/main.go -->
~~~go
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
		return config{}, err
	}
~~~

to:

~~~go
	if cfg.IdempotencyTTL, err = envconfig.Duration(getenv, "IDEMPOTENCY_TTL", 24*time.Hour); err != nil {
		return config{}, err
	}
	if cfg.BreakerThreshold, err = envconfig.PositiveInt(getenv, "BREAKER_THRESHOLD", 5); err != nil {
		return config{}, err
	}
	if cfg.BreakerCooldown, err = envconfig.Duration(getenv, "BREAKER_COOLDOWN", 10*time.Second); err != nil {
		return config{}, err
	}
~~~

Wrap the dispatcher, and expose the breaker's state as a metric. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	service := jobs.NewService(memstore.New(), jobs.WithDispatcher(eventing.NewDispatcher(publisher)))
~~~

to:

~~~go
	dispatchBreaker := breaker.New(cfg.BreakerThreshold, cfg.BreakerCooldown, time.Now)
	metrics.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "dispatch_breaker_state",
		Help: "The dispatch circuit breaker: 0 closed, 1 open, 2 half-open.",
	}, func() float64 { return float64(dispatchBreaker.State()) }))
	dispatcher := breaker.Dispatcher{Next: eventing.NewDispatcher(publisher), Breaker: dispatchBreaker}
	service := jobs.NewService(memstore.New(), jobs.WithDispatcher(dispatcher))
~~~

with the import:

<!-- edit: cmd/api/main.go -->
~~~go
	"kestrel/internal/bus"
	"kestrel/internal/envconfig"
~~~

to:

~~~go
	"kestrel/internal/breaker"
	"kestrel/internal/bus"
	"kestrel/internal/envconfig"
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

**Run it: retries.** Start the API with RabbitMQ as in step 3, then a worker that fails half of all attempts:

~~~bash
AMQP_URL=amqp://guest:guest@localhost:5672/ FAIL_RATE=0.5 WORKERS=4 go run ./cmd/worker
~~~

Create ten short jobs, wait a few seconds, then look at all ten:

~~~bash
for i in $(seq 1 10); do curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"flaky","duration_ms":50}'; done
sleep 4
for i in $(seq 1 10); do curl -s http://127.0.0.1:8080/jobs/$i; echo; done
~~~

One real run, trimmed to the state and reason:

~~~text
1 completed
2 completed
3 completed
4 completed
5 failed   failed after 3 attempts: transient failure
6 completed
...
10 completed
~~~

Each attempt fails half the time, so a job fails only if all three attempts fail: 0.5 × 0.5 × 0.5 = 12.5%. One in ten is right in line with that. Without retries, about **five** of the ten would have failed. The worker's log shows the cost: jobs that needed retries took 80–150 ms instead of 60, because of the backoff waits.

**Run it: a poison message.** Publish something that isn't JSON straight into the commands queue, through the management API:

~~~bash
curl -s -u guest:guest -X POST http://localhost:15672/api/exchanges/%2F/amq.default/publish \
  -H 'content-type: application/json' \
  -d '{"properties":{},"routing_key":"jobs.commands","payload":"this is not JSON","payload_encoding":"string"}'
~~~

The worker can't decode it, so it's rejected without requeueing, and RabbitMQ moves it to the dead-letter queue. Fetch it from there (`ack_requeue_true` peeks without removing it):

~~~bash
curl -s -u guest:guest -X POST http://localhost:15672/api/queues/%2F/jobs.commands.dead/get \
  -H 'content-type: application/json' -d '{"count":1,"ackmode":"ack_requeue_true","encoding":"auto"}'
~~~

The response is a JSON array. Its message has `"payload":"this is not JSON"`, and the broker's `x-death` header records `"reason":"rejected"` and the queue it came from. The bad message didn't crash the worker, didn't loop, and didn't block the messages behind it. It's parked where a human can inspect it, fix the cause, and republish it. That's the job of a dead-letter queue.

**Run it: the breaker.** With the API running against RabbitMQ, **freeze** the broker. `docker pause` suspends the container's processes without closing their connections, which is nastier than a crash: everything just stops answering. Then create jobs:

~~~bash
docker pause $(docker compose ps -q rabbitmq)
for i in $(seq 1 8); do
  curl -s -o /dev/null -w "request $i: %{http_code} in %{time_total}s\n" \
    -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"x"}'
done
curl -s http://127.0.0.1:8080/metrics | grep '^dispatch_breaker_state'
docker unpause $(docker compose ps -q rabbitmq)
~~~

~~~text
request 1: 503 in 2.183728s
request 2: 503 in 2.183685s
request 3: 503 in 2.183466s
request 4: 503 in 2.183548s
request 5: 503 in 2.183032s
request 6: 503 in 0.000708s
request 7: 503 in 0.000592s
request 8: 503 in 0.000857s
dispatch_breaker_state 1
~~~

The first five requests each waited the full 2-second request deadline for a publish confirm that never came. After the fifth failure in a row the breaker **opened**, and requests 6–8 were refused in under a millisecond, **three thousand times faster**, without touching the broker at all. Under real load that's the difference between "jobs can't be created right now" and every API goroutine stuck waiting, connection pools exhausted, and the outage spreading to everything that calls the API. Ten seconds later (`BREAKER_COOLDOWN`), one trial request is let through; if the broker is back, the breaker closes.

The API itself notices the frozen broker through AMQP **heartbeats**, small "are you alive?" frames exchanged every few seconds. In one test it took about 17 seconds. It then logs `lost the message bus; shutting down` and exits with status 1, so after `docker unpause`, start it again. The breaker protected callers during those 17 seconds; the crash-only exit handles everything after.

**Break it.** Set `BREAKER_THRESHOLD=1000` and repeat the freeze. Every request now takes two seconds and fails. Multiply that by a thousand concurrent users and you have the cascading failure the breaker exists to prevent.

**Explain it:** why jitter, and not just backoff? Why do retries stop at the job deadline? Why must workers be upgraded before the API when `RunJob` moves to version 2? What does an open breaker save: the caller, the dependency, or both?

**Read.** Marc Brooker, [*Exponential Backoff And Jitter*](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/) (AWS Architecture Blog); *Site Reliability Engineering* Ch. 22, *Addressing Cascading Failures*; Martin Fowler, [*CircuitBreaker*](https://martinfowler.com/bliki/CircuitBreaker.html). Carry this question in: when do retries make an outage *worse*?

---

## Step 6: gRPC and Protocol Buffers

**The problem.** HTTP with JSON is easy to read and works everywhere, but the contract lives only in your documentation and your tests. Nothing stops a client sending `"duration_ms": "fast"`. Between your own services, teams often prefer a contract that's **written down as code**, checked by a compiler on both sides, and sent in a compact binary form. That's **gRPC**.

**New ideas.**

- **Protocol Buffers** (protobuf) is a language for describing messages and services, plus a compact binary encoding for them. You write a `.proto` file; the **protoc** compiler generates Go code (or Java, Python, and so on) for both server and client.
- Each field has a **field number** (`string description = 1;`). The binary format sends the numbers, not the names. So you can rename a field freely, but **never reuse or change a number**. That's how protobuf stays compatible as it evolves, the same concern as step 5's message versions.
- **gRPC** runs remote procedure calls over HTTP/2: the client calls `CreateJob(ctx, req)` as if it were a local method. Deadlines travel with the call: a client's context timeout reaches the server as a `grpc-timeout` header, and the server's `ctx` gets the same deadline.
- gRPC errors use **status codes** (`InvalidArgument`, `NotFound`, `Unavailable`, ...) instead of HTTP statuses. The mapping is a design decision, just as in step 4 of Phase 1.
- **When to use which.** Use JSON over HTTP for public APIs, browsers and humans with curl. Use gRPC for service-to-service calls, especially between teams and languages. Same use cases, two adapters: the layering from Phase 1 means `jobs.Service` doesn't change at all.

### Install the tools

> **Run locally.** Install the protobuf compiler once: `sudo apt install protobuf-compiler` on Debian or Ubuntu (including WSL), or `brew install protobuf` on macOS. `protoc --version` should print `libprotoc 3.21` or newer.

The two Go code generators are Go programs. Install them into your practice folder's `bin/`, pinned to exact versions, so everyone generates identical code:

<!-- run: GOBIN=$PWD/bin go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12 && GOBIN=$PWD/bin go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2 -->
~~~bash
GOBIN=$PWD/bin go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12
GOBIN=$PWD/bin go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2
~~~

`GOBIN` tells `go install` where to put the programs it builds. They come from two different modules, so they need two commands.

### The contract

Create `proto/kestrel/jobs/v1/jobs.proto`:

<!-- file: proto/kestrel/jobs/v1/jobs.proto -->
~~~protobuf
syntax = "proto3";

package kestrel.jobs.v1;

option go_package = "kestrel/internal/grpcapi/jobsv1";

// Jobs creates and reads jobs. It offers the same use cases as the HTTP API.
service Jobs {
  rpc CreateJob(CreateJobRequest) returns (Job);
  rpc GetJob(GetJobRequest) returns (Job);
}

message CreateJobRequest {
  string description = 1;
  int64 duration_ms = 2;
}

message GetJobRequest {
  int64 id = 1;
}

enum State {
  STATE_UNSPECIFIED = 0;
  STATE_QUEUED = 1;
  STATE_RUNNING = 2;
  STATE_COMPLETED = 3;
  STATE_FAILED = 4;
}

message Job {
  int64 id = 1;
  State state = 2;
  string description = 3;
  int64 duration_ms = 4;
  string failure_reason = 5;
  int64 created_at_unix_ms = 6;
  int64 updated_at_unix_ms = 7;
}
~~~

- The `v1` in the package and the path is the **API version**. A breaking change means a new `v2` package, served side by side with `v1`.
- In proto3 every field is optional and has a zero default: a missing `duration_ms` reads as `0`.
- Enums start with an `..._UNSPECIFIED = 0` value, so "not set" can never be mistaken for a real state.
- Times are milliseconds since 1970 (Unix time). That keeps the example free of extra imports; real APIs often use `google.protobuf.Timestamp`.

Generate the Go code:

<!-- run: PATH=$PWD/bin:$PATH protoc --go_out=. --go_opt=module=kestrel --go-grpc_out=. --go-grpc_opt=module=kestrel proto/kestrel/jobs/v1/jobs.proto -->
~~~bash
PATH=$PWD/bin:$PATH protoc --go_out=. --go_opt=module=kestrel \
  --go-grpc_out=. --go-grpc_opt=module=kestrel proto/kestrel/jobs/v1/jobs.proto
ls internal/grpcapi/jobsv1
~~~

~~~text
jobs.pb.go  jobs_grpc.pb.go
~~~

`jobs.pb.go` holds the message types; `jobs_grpc.pb.go` holds the client, and the interface your server implements. **Never edit generated files**: change the `.proto` and regenerate. Open `jobs_grpc.pb.go` and find `JobsServer` (the interface) and `NewJobsClient`.

Fetch the runtime libraries the generated code needs:

<!-- run: go get google.golang.org/grpc@v1.84.0 google.golang.org/protobuf@v1.36.12 -->
~~~bash
go get google.golang.org/grpc@v1.84.0 google.golang.org/protobuf@v1.36.12
~~~

### The server adapter

Create `internal/grpcapi/server.go`:

<!-- file: internal/grpcapi/server.go -->
~~~go
// Package grpcapi serves the jobs use cases over gRPC. Like httpapi, it only
// translates: protobuf messages in, use-case calls, protobuf and status
// codes out. It holds no business rules.
package grpcapi

import (
	"context"
	"errors"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"kestrel/internal/grpcapi/jobsv1"
	"kestrel/internal/jobs"
)

// JobService is what the gRPC server needs from the jobs service.
type JobService interface {
	Create(ctx context.Context, description string, duration time.Duration) (jobs.Job, error)
	Get(ctx context.Context, id jobs.ID) (jobs.Job, error)
}

type Server struct {
	jobsv1.UnimplementedJobsServer
	jobs JobService
}

func New(service JobService) *Server {
	return &Server{jobs: service}
}

func (s *Server) CreateJob(ctx context.Context, req *jobsv1.CreateJobRequest) (*jobsv1.Job, error) {
	job, err := s.jobs.Create(ctx, req.GetDescription(), time.Duration(req.GetDurationMs())*time.Millisecond)
	if err != nil {
		return nil, toStatus(err)
	}
	return toProto(job), nil
}

func (s *Server) GetJob(ctx context.Context, req *jobsv1.GetJobRequest) (*jobsv1.Job, error) {
	if req.GetId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "id must be a positive integer")
	}
	job, err := s.jobs.Get(ctx, jobs.ID(req.GetId()))
	if err != nil {
		return nil, toStatus(err)
	}
	return toProto(job), nil
}

// toStatus maps domain errors to gRPC codes, as writeDomainError maps them
// to HTTP statuses. Unknown errors become Internal, with no details.
func toStatus(err error) error {
	switch {
	case errors.Is(err, jobs.ErrInvalidDescription), errors.Is(err, jobs.ErrInvalidDuration):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, jobs.ErrNotFound):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, jobs.ErrDispatchFailed):
		return status.Error(codes.Unavailable, "the service is busy; retry later")
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, err.Error())
	default:
		return status.Error(codes.Internal, "internal error")
	}
}

var states = map[jobs.State]jobsv1.State{
	jobs.StateQueued:    jobsv1.State_STATE_QUEUED,
	jobs.StateRunning:   jobsv1.State_STATE_RUNNING,
	jobs.StateCompleted: jobsv1.State_STATE_COMPLETED,
	jobs.StateFailed:    jobsv1.State_STATE_FAILED,
}

func toProto(job jobs.Job) *jobsv1.Job {
	return &jobsv1.Job{
		Id:              int64(job.ID),
		State:           states[job.State],
		Description:     string(job.Description),
		DurationMs:      job.Duration.Milliseconds(),
		FailureReason:   job.FailureReason,
		CreatedAtUnixMs: job.CreatedAt.UnixMilli(),
		UpdatedAtUnixMs: job.UpdatedAt.UnixMilli(),
	}
}
~~~

- Embedding `jobsv1.UnimplementedJobsServer` is required by the generator. If you add an RPC to the `.proto` and regenerate, the server still compiles, and the new method answers `Unimplemented` until you write it.
- The generated getters (`req.GetDescription()`) are safe to call even on a `nil` request.
- `toStatus` is the gRPC twin of `writeDomainError`. Compare them: the same decisions, a different vocabulary.

Test it with **bufconn**, an in-memory network connection, so the test needs no free port. Create `internal/grpcapi/server_test.go`:

<!-- file: internal/grpcapi/server_test.go -->
~~~go
package grpcapi

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/proto"

	"kestrel/internal/grpcapi/jobsv1"
	"kestrel/internal/jobs"
	"kestrel/internal/memstore"
)

// client starts a real gRPC server on an in-memory connection and returns
// a client for it.
func client(t *testing.T) jobsv1.JobsClient {
	t.Helper()
	listener := bufconn.Listen(1 << 20)
	server := grpc.NewServer()
	jobsv1.RegisterJobsServer(server, New(jobs.NewService(memstore.New())))
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)

	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return listener.DialContext(ctx)
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return jobsv1.NewJobsClient(conn)
}

func TestCreateThenGet(t *testing.T) {
	c := client(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	created, err := c.CreateJob(ctx, &jobsv1.CreateJobRequest{Description: "resize", DurationMs: 50})
	if err != nil {
		t.Fatalf("CreateJob: %v", err)
	}
	got, err := c.GetJob(ctx, &jobsv1.GetJobRequest{Id: created.GetId()})
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if got.GetDescription() != "resize" || got.GetState() != jobsv1.State_STATE_QUEUED || got.GetDurationMs() != 50 {
		t.Fatalf("job = %v", got)
	}
}

func TestErrorsBecomeStatusCodes(t *testing.T) {
	c := client(t)
	ctx := context.Background()
	tests := []struct {
		name string
		call func() error
		want codes.Code
	}{
		{"empty description", func() error {
			_, err := c.CreateJob(ctx, &jobsv1.CreateJobRequest{})
			return err
		}, codes.InvalidArgument},
		{"zero id", func() error {
			_, err := c.GetJob(ctx, &jobsv1.GetJobRequest{})
			return err
		}, codes.InvalidArgument},
		{"unknown job", func() error {
			_, err := c.GetJob(ctx, &jobsv1.GetJobRequest{Id: 99})
			return err
		}, codes.NotFound},
	}
	for _, tt := range tests {
		if got := status.Code(tt.call()); got != tt.want {
			t.Errorf("%s: code = %v, want %v", tt.name, got, tt.want)
		}
	}
}

func TestProtobufIsSmallerThanJSON(t *testing.T) {
	job := toProto(jobs.Job{ID: 12345, State: jobs.StateCompleted, Description: "resize images",
		Duration: 300 * time.Millisecond, CreatedAt: time.Now(), UpdatedAt: time.Now()})
	binary, _ := proto.Marshal(job)
	text, _ := json.Marshal(map[string]any{
		"id": 12345, "state": "completed", "description": "resize images", "duration_ms": 300,
		"created_at": time.Now().UTC(), "updated_at": time.Now().UTC(),
	})
	t.Logf("protobuf: %d bytes, JSON: %d bytes", len(binary), len(text))
	if len(binary) >= len(text) {
		t.Fatalf("protobuf %d bytes >= JSON %d bytes", len(binary), len(text))
	}
}
~~~

`grpc.NewClient` doesn't connect immediately; the connection is made on the first call. `passthrough:///bufnet` is a placeholder address: the dialer function ignores it and connects to the in-memory listener.

<!-- run: go mod tidy && go vet ./internal/grpcapi/... && go test -race ./internal/grpcapi/... -->

### Serve gRPC next to HTTP

`cmd/api` serves both protocols from the same service. In `cmd/api/main.go`, add the address. Change:

<!-- edit: cmd/api/main.go -->
~~~go
type config struct {
	ListenAddr       string
~~~

to:

~~~go
type config struct {
	ListenAddr       string
	GRPCAddr         string
~~~

and change:

<!-- edit: cmd/api/main.go -->
~~~go
	if cfg.ListenAddr, err = envconfig.HostPort(getenv, "LISTEN_ADDR", "127.0.0.1:8080"); err != nil {
		return config{}, err
	}
~~~

to:

~~~go
	if cfg.ListenAddr, err = envconfig.HostPort(getenv, "LISTEN_ADDR", "127.0.0.1:8080"); err != nil {
		return config{}, err
	}
	if cfg.GRPCAddr, err = envconfig.HostPort(getenv, "GRPC_ADDR", "127.0.0.1:9090"); err != nil {
		return config{}, err
	}
~~~

Start the gRPC server once the HTTP listener is up. **Reflection** lets tools such as `grpcurl` ask the server what it offers. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(listener) }()
~~~

to:

~~~go
	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(listener) }()

	grpcListener, err := net.Listen("tcp", cfg.GRPCAddr)
	if err != nil {
		return err
	}
	grpcServer := grpc.NewServer()
	jobsv1.RegisterJobsServer(grpcServer, grpcapi.New(service))
	reflection.Register(grpcServer)
	go func() { _ = grpcServer.Serve(grpcListener) }()
	logger.Info("grpc listening", "addr", grpcListener.Addr().String())
~~~

Stop it gracefully alongside HTTP. `GracefulStop` waits for calls in progress, so give it until the grace period ends, then force it. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	// 2. Stop consuming, and wait for running handlers up to the grace period.
~~~

to:

~~~go
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

	// 2. Stop consuming, and wait for running handlers up to the grace period.
~~~

and add the imports. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"github.com/prometheus/client_golang/prometheus"

	"kestrel/internal/breaker"
~~~

to:

~~~go
	"github.com/prometheus/client_golang/prometheus"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"

	"kestrel/internal/breaker"
~~~

and:

<!-- edit: cmd/api/main.go -->
~~~go
	"kestrel/internal/eventing"
	"kestrel/internal/httpapi"
~~~

to:

~~~go
	"kestrel/internal/eventing"
	"kestrel/internal/grpcapi"
	"kestrel/internal/grpcapi/jobsv1"
	"kestrel/internal/httpapi"
~~~

The `main` tests start the API on a random HTTP port; the gRPC port must be random too, or tests running together would collide on 9090. In `cmd/api/main_test.go`, change:

<!-- edit: cmd/api/main_test.go -->
~~~go
	vars := map[string]string{"LISTEN_ADDR": "127.0.0.1:0"}
~~~

to:

~~~go
	vars := map[string]string{"LISTEN_ADDR": "127.0.0.1:0", "GRPC_ADDR": "127.0.0.1:0"}
~~~

### A small gRPC client

A command-line client shows the other side of the contract: code generated from the same `.proto`, calling over the network. Create `cmd/jobsctl/main.go`:

<!-- file: cmd/jobsctl/main.go -->
~~~go
// Command jobsctl calls the jobs API over gRPC.
//
//	jobsctl create DESCRIPTION [DURATION_MS]
//	jobsctl get ID
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	"kestrel/internal/grpcapi/jobsv1"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "jobsctl:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	addr := os.Getenv("GRPC_ADDR")
	if addr == "" {
		addr = "127.0.0.1:9090"
	}
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	defer conn.Close()
	client := jobsv1.NewJobsClient(conn)

	// The deadline travels with the call; the server sees it too.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	var job *jobsv1.Job
	switch {
	case len(args) >= 2 && args[0] == "create":
		duration := int64(0)
		if len(args) == 3 {
			if duration, err = strconv.ParseInt(args[2], 10, 64); err != nil {
				return fmt.Errorf("DURATION_MS must be a whole number: %w", err)
			}
		}
		job, err = client.CreateJob(ctx, &jobsv1.CreateJobRequest{Description: args[1], DurationMs: duration})
	case len(args) == 2 && args[0] == "get":
		id, parseErr := strconv.ParseInt(args[1], 10, 64)
		if parseErr != nil {
			return fmt.Errorf("ID must be a whole number: %w", parseErr)
		}
		job, err = client.GetJob(ctx, &jobsv1.GetJobRequest{Id: id})
	default:
		return errors.New("usage: jobsctl create DESCRIPTION [DURATION_MS] | jobsctl get ID")
	}
	if err != nil {
		s := status.Convert(err)
		return fmt.Errorf("%s: %s", s.Code(), s.Message())
	}
	fmt.Printf("job %d: %s %q (%d ms)\n", job.GetId(), job.GetState(), job.GetDescription(), job.GetDurationMs())
	return nil
}
~~~

`status.Convert(err)` turns a gRPC error back into its code and message, so the CLI can print them separately.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

**Run it.** Start the API (`go run ./cmd/api`). Its log now has a second listener:

~~~text
{"time":"...","level":"INFO","msg":"grpc listening","addr":"127.0.0.1:9090"}
~~~

Then, in another terminal, use the client:

~~~bash
go run ./cmd/jobsctl create "resize images" 300
go run ./cmd/jobsctl get 1
go run ./cmd/jobsctl get 99
go run ./cmd/jobsctl create ""
~~~

~~~text
job 1: STATE_QUEUED "resize images" (300 ms)
job 1: STATE_COMPLETED "resize images" (300 ms)
jobsctl: NotFound: job not found
jobsctl: InvalidArgument: description must be between 1 and 200 characters
~~~

The last two exit with status 1. `curl -s http://127.0.0.1:8080/jobs/1` shows the same job: one service, two front doors. If you have [grpcurl](https://github.com/fullstorydev/grpcurl) installed, reflection lets it explore the API with no `.proto` file: `grpcurl -plaintext 127.0.0.1:9090 list`.

Run the size test with `-v` to see the encodings compared:

~~~bash
go test -run TestProtobufIsSmallerThanJSON -v ./internal/grpcapi/
~~~

~~~text
server_test.go:99: protobuf: 37 bytes, JSON: 172 bytes
~~~

The same job is **under a quarter of the size** in protobuf. The field names aren't sent, numbers are packed tightly, and enums are single bytes. Most of the time that doesn't matter. At millions of messages a second, or on Phase 5's constrained links, it does.

**Break it: the compatibility rule.** In `jobs.proto`, swap the numbers of `description` and `duration_ms` in `CreateJobRequest` (make `description = 2` and `duration_ms = 1`), regenerate the *server* only, and keep running the old `jobsctl` binary against it. Create a job: the server reads the client's description bytes as if they were the duration, and rejects or garbles the request. Field numbers **are** the contract on the wire. Changing one silently breaks every client built from the old file. Undo the swap and regenerate.

**Explain it:** why are protobuf field numbers permanent, but field names free to change? Map each of `InvalidArgument`, `NotFound` and `Unavailable` to the HTTP status this API uses for the same situation. When would you choose gRPC over JSON, and when not?

**Read.** The [gRPC introduction](https://grpc.io/docs/what-is-grpc/introduction/) and [core concepts](https://grpc.io/docs/what-is-grpc/core-concepts/); the protobuf guide's section [*Updating A Message Type*](https://protobuf.dev/programming-guides/proto3/#updating); DDIA Ch. 4, *Encoding and Evolution*. Carry this question in: what's the difference between backward and forward compatibility, and which one does each of your services need?

---

## Step 7: Look at the wire

**The problem.** So far, "the network" has been an abstraction. Every claim in this phase (connections, handshakes, a message "on the wire") is about bytes moving between sockets. In this step you watch them. There's no new code.

> **Run locally.** `tcpdump` needs `sudo`, and CI can't watch your loopback interface. Run these on your own machine; the expected output is described for each command.

**New ideas.**

- A **socket** is one end of a connection, identified by an IP address and a port. A TCP connection is a pair of sockets: `127.0.0.1:56020 ↔ 127.0.0.1:5672`. The client's port is **ephemeral**, picked by the OS for this connection only.
- **The TCP three-way handshake** opens a connection:
  1. the client sends **SYN** ("I'd like to talk; here's my starting sequence number");
  2. the server answers **SYN-ACK**;
  3. the client sends **ACK**.

  Only then does data flow. **FIN** closes each direction. **RST** aborts.
- **Keep-alive** reuses one connection for many HTTP requests, skipping the handshake. That's why the Python Bridge's `kload` kept its connections open.
- **Multiplexing** puts many logical streams inside one connection. AMQP channels and HTTP/2 streams (which gRPC uses) both do it.

### See the connections

With RabbitMQ, the API and a worker running (step 3's three terminals, with `WORKERS=2`), list the established TCP connections to the broker, with their owning processes:

~~~bash
ss -tnp state established '( sport = :5672 or dport = :5672 )'
~~~

You'll see one connection from the API and **one** from the worker, each from an ephemeral port to `127.0.0.1:5672`:

~~~text
127.0.0.1:56020  127.0.0.1:5672  users:(("api",...))
127.0.0.1:56036  127.0.0.1:5672  users:(("worker",...))
~~~

The worker runs two consumers, but they share one TCP connection, as two AMQP **channels** inside it. `ss -ltnp | grep -E ':8080|:9090'` shows the API **listening** on both its HTTP and gRPC ports. A listening socket waits; an established one talks.

### Watch a handshake and an HTTP request

In one terminal, capture traffic on the loopback interface to port 8080:

~~~bash
sudo tcpdump -i lo -nn -A 'tcp port 8080'
~~~

`-i lo` is the loopback interface (on macOS it's `lo0`), `-nn` keeps addresses and ports as numbers, and `-A` prints packet contents as text. In another terminal, run `curl -s http://127.0.0.1:8080/health`. You'll see, in order:

1. `Flags [S]`: the SYN, from curl's ephemeral port to 8080;
2. `Flags [S.]`: the SYN-ACK (the `.` means ACK);
3. `Flags [.]`: the ACK. The connection is open;
4. `Flags [P.]` with the readable text `GET /health HTTP/1.1` and `Host: 127.0.0.1:8080`. `P` means "push this data to the application";
5. `Flags [P.]` from port 8080 back, with `HTTP/1.1 200 OK`, the headers and `{"status":"ok"}`;
6. `Flags [F.]` packets as each side closes, and their ACKs.

Everything in Phase 0's request diagram is there, byte for byte. HTTP is just text on a TCP connection.

Now capture port 9090 and run `go run ./cmd/jobsctl get 1`. After the same handshake, the data is **not** readable text: HTTP/2 frames and protobuf bytes, with only fragments like the path `/kestrel.jobs.v1.Jobs/GetJob` recognisable. Then capture port 5672 while creating a job: AMQP is binary too, but you'll spot the JSON payload of the `RunJob` command inside it.

### Back to the 7-second tail

The Python Bridge left an open question: after a 1-second server freeze, some requests took about 7 seconds, and the kernel counted SYN retransmissions. Now you can test the hypothesis. Run `sudo tcpdump -i lo -nn 'tcp port 8080 and tcp[tcpflags] & tcp-syn != 0'` (SYN packets only), then repeat the bridge's freeze experiment with `--max-in-flight 200`. If the hypothesis is right, you'll see SYNs for one ephemeral port **repeated** with gaps of about 1, 2 and 4 seconds: TCP's retransmission backoff, the same idea as step 5's retry backoff, built into the kernel. Write down what you observe, whether it confirms the hypothesis, and what you'd change in the load generator (for example, opening connections before the test starts, or capping new ones).

**Explain it:** what do the three packets of a handshake each say? Why does a worker with two consumers have one TCP connection? Why can you read HTTP/1.1 in `tcpdump`, but not gRPC?

**Read.** Kurose & Ross §2.7 (socket programming) and §3.5 (TCP, especially connection management); CSAPP Ch. 11; Beej's *Guide to Network Programming*, sections 5–6. Carry this question in: which layer, application or kernel, did each failure in this phase actually happen in?

---

## Rebuild it yourself

Close the guide. In your own `kestrel` repository, rebuild Phase 2 from these contracts:
- the message types and their versions;
- the queue names and their dead-letter queues;
- the HTTP and gRPC APIs;
- the three idempotency defences;
- the retry and breaker policies.

Use TDD throughout. Then repeat the two key experiments on *your* code: kill a worker mid-job, and freeze the broker. Record the evidence.

## Checkpoint

You're ready for the Rust Bridge when you can, without the guide:

1. Explain synchronous vs asynchronous work, backpressure, and Little's law with numbers.
2. Explain commands vs events, bounded contexts, and why only messages connect the API and the worker.
3. State the three delivery guarantees, and explain why "exactly once in effect" needs idempotency.
4. Explain what makes a RabbitMQ message survive a broker restart, and when ack happens and why.
5. Kill a worker mid-job and explain every step of what happens next.
6. Name the three sources of duplicates and the defence against each.
7. Explain backoff with full jitter, upcasting, and why readers deploy before writers.
8. Draw the circuit breaker's states, and show the freeze experiment's numbers.
9. Describe a TCP handshake from a `tcpdump` you captured.

## If it goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| RabbitMQ container exits at start-up with `.erlang.cookie: eacces` | The container starts as root and can't read its cookie | Keep `user: "999:999"` in `compose.yaml` |
| `connect to RabbitMQ: dial tcp ...:5672: connect: connection refused` | The broker isn't running or isn't healthy yet | `docker compose up -d --wait`; check `docker compose ps` |
| `PRECONDITION_FAILED - inequivalent arg 'x-max-length'` | The queue already exists with different arguments | Delete it in the management UI (or `docker compose down -v`), then start again |
| The API exits with `lost the message bus` | The broker went away (crash-only design) | Start the broker, then the API |
| Jobs stay `queued` | No worker is running in RabbitMQ mode | Start `cmd/worker` with the same `AMQP_URL` |
| Every request returns 503 at once | The breaker is open | Wait `BREAKER_COOLDOWN`; check `dispatch_breaker_state` and the broker |
| `protoc-gen-go: program not found` | The plugins aren't on `PATH` | Prefix the command with `PATH=$PWD/bin:$PATH` |
| `all arguments must refer to packages in the same module` | Two modules in one `go install` | Install each plugin separately |
| Integration tests say `SKIP` | `KESTREL_AMQP_URL` isn't set | `KESTREL_AMQP_URL=amqp://guest:guest@localhost:5672/ go test ./internal/rabbit/` |
| A test passes once and fails with `-count=20` | A race or an ordering assumption (remember `select`) | Run concurrent tests many times; never trust one pass |

## Reading list for this phase

| When | Reading | Question to carry in |
|---|---|---|
| Step 1 | *Site Reliability Engineering* Ch. 21, *Handling Overload* | Why reject early rather than queue? |
| Step 2 | DDIA Ch. 11, first section; *Understanding Distributed Systems*, messaging | What does each delivery guarantee cost? |
| Step 3 | RabbitMQ docs: *Confirms*, *Quorum Queues*; MapReduce paper §3.3 | What exactly does the broker promise? |
| Step 4 | Stripe, *Designing robust and predictable APIs with idempotency*; the IETF Idempotency-Key draft | How long should a key live? |
| Step 5 | Brooker, *Exponential Backoff And Jitter*; SRE Ch. 22; Fowler, *CircuitBreaker* | When do retries make an outage worse? |
| Step 6 | gRPC docs; protobuf *Updating A Message Type*; DDIA Ch. 4 | Backward vs forward compatibility? |
| Step 7 | Kurose & Ross §2.7, §3.5; CSAPP Ch. 11; Beej's guide | Which layer did each failure happen in? |
| After the phase | van Steen & Tanenbaum §4.2–4.3; *Software Architecture: The Hard Parts* Ch. 7 | Where should the line between services go? |
