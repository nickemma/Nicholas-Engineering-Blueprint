# 13 Worker pools and backpressure

> Module: Go runtime and reliable services · Time: ~6 h · Builds on: 12

## The problem

`POST /jobs/{id}/run` holds the HTTP request open for the whole job. A caller with a 30-second timeout can't run a 60-second job. A thousand callers mean a thousand goroutines doing work at once, with no limit. And there's no way to say "not now, I'm full".

## The mental model

~~~text
 POST /jobs ──► store the job ──► Dispatch ──► [ queue: capacity N ] ──► worker 1 ─┐
                                     │          id id id ...             worker 2 ─┼─► Service.Run
                                     │                                   worker 3 ─┘
                                     └─ queue full? refuse now: 503 + Retry-After
~~~

- **Synchronous vs asynchronous.** Synchronous means the caller waits for the result. Asynchronous means the service *accepts* the work, answers immediately, and does it later; the caller checks back with `GET /jobs/{id}`.
- The **producer/consumer** pattern: the API (the producer) puts work on a **queue**; **workers** (the consumers) take it off and do it. A **worker pool** is a fixed number of workers, so the amount of work in progress has a limit you chose.
- A **bounded queue** has a fixed capacity. That's not a weakness. An unbounded queue doesn't remove overload; it moves it into memory, where it grows silently until the process is killed.
- **Backpressure** means telling the producer to slow down when the consumer can't keep up. Here, a full queue makes `POST /jobs` answer **503 Service Unavailable** with a `Retry-After` header: "I'm overloaded; try again in a second." (429 Too Many Requests is a different signal: one *client* is over its own limit.)
- **Saturation**, the golden signal lesson 11 left for later, now has a number: **queue depth**.

**Little's law** connects three averages for anything that holds items for a while: a queue, a shop, a server.

~~~text
 L = λ × W

 L  how many items are inside, on average          (jobs waiting)
 λ  how many go through per second, on average      (jobs per second)
 W  how long each one stays inside, on average      (seconds waiting)
~~~

It needs no assumptions about the order of arrivals or the kind of work: only that what goes in eventually comes out. Two consequences you'll measure in step 7:

- **Capacity is arithmetic.** With 2 workers and half-second jobs, at most 4 jobs a second get done. If 10 a second arrive, the queue grows by 6 a second, and a 20-slot queue is full after about 20 ÷ 6 ≈ 3.3 seconds. No code changes that; only more workers, faster jobs or fewer arrivals do.
- **A full queue is a delay.** Once full, 20 jobs wait and 4 a second leave, so each waits about 20 ÷ 4 = 5 seconds. A bigger queue doesn't serve anyone faster; it only makes them wait longer before they get an answer.

The new contract. `POST /jobs/{id}/run` disappears, because workers run jobs now.

| Request | Response |
|---|---|
| `POST /jobs` | `201` with the job `queued`. A worker picks it up shortly |
| `POST /jobs` when the queue is full | `503`, `Retry-After: 1`, `{"error":"the service is busy; retry later"}`. The job is recorded as `failed` with reason `not dispatched: queue is full` |
| `GET /jobs/{id}` | The job, whose state moves `queued → running → completed` (or `failed`) on its own |

## The pattern

**Accept quickly, bound the work, refuse loudly.** The request path only stores and enqueues; a fixed pool does the work; a full queue is an immediate, honest `503`, never a request that hangs. And every limit (workers, queue size, job timeout) is a setting, because the right numbers come from measurement, not from the code.

## Build it

### Step 1: A queued job may fail without running

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

### Step 2: A port for "send this job to be run"

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
~~~

Read that comment carefully, because it names a flaw that follows Switchyard for a long time. Storing a job and dispatching it are **two separate writes to two separate systems**: the map and the queue now, a database and a broker later. No code can make two independent systems change together, atomically. If dispatch fails with an error, `Create` compensates by marking the job failed. But if the *process crashes* between the two writes, there's no code left running to compensate, and the job sits `queued` forever. This is the **dual-write problem**. The *Event streams* unit solves it with the transactional outbox; until then, know that the gap is there.

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

### Step 3: The queue and its workers

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
- `Serve` starts the worker goroutines and waits for all of them, using a `WaitGroup` as in lesson 06's concurrent test.
- The `ctx.Err()` check before the `select` is there because of a real bug. *Break it* shows what goes wrong without it.

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

### Step 4: The API answers 503 when the queue is full

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

### Step 5: Wiring it together: two contexts for a clean stop

`main` now builds the queue, starts the workers, and has a harder shutdown problem: there are requests in flight **and** jobs in flight. Shutdown happens in order:

1. Stop accepting HTTP requests, so no new jobs arrive.
2. Tell the workers to stop *taking* jobs, but let each one finish the job it holds.
3. If the grace period runs out first, *interrupt* the running jobs. They're recorded as `failed` with reason `cancelled`, never left `running`.

That needs **two** contexts: one that means "stop taking" and one that means "stop running". Replace `cmd/switchyard/main.go`:

<!-- file: cmd/switchyard/main.go -->
~~~go
// Command switchyard runs Switchyard's control plane: an HTTP API plus a
// pool of workers that run jobs from an in-process queue.
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

	"switchyard/internal/httpapi"
	"switchyard/internal/jobs"
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
- `Service.Run` is lesson 07's code, unchanged. Only its caller changed, from an HTTP handler to a worker. The layering paid off: the use case didn't care who called it.
- Jobs still waiting in the queue at exit are **lost**: the queue lives in this process's memory. `jobs_left_in_queue` in the final log line says how many. Core 03 keeps jobs in PostgreSQL, and the *Messaging and resilience* unit moves the queue into a durable broker.

Replace `cmd/switchyard/main_test.go` with tests for the new behaviour:

<!-- file: cmd/switchyard/main_test.go -->
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

### Step 6: Overload it by hand

Start the service with one worker and room for two waiting jobs, so it's easy to overload:

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && WORKERS=1 QUEUE_CAPACITY=2 /tmp/switchyard > /tmp/switchyard.log &
sleep 0.5
~~~

Send five 1-second jobs as fast as possible, then read the queue depth:

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
for i in 1 2 3 4 5; do curl -s http://127.0.0.1:8080/jobs/$i; done
~~~

~~~text
{"id":1,"state":"running","description":"slow","duration_ms":1000,"created_at":"2026-11-20T04:32:03.800773748Z","updated_at":"2026-11-20T04:32:03.801068552Z"}
{"id":2,"state":"queued","description":"slow","duration_ms":1000,"created_at":"2026-11-20T04:32:03.811043085Z","updated_at":"2026-11-20T04:32:03.811043085Z"}
{"id":3,"state":"queued","description":"slow","duration_ms":1000,"created_at":"2026-11-20T04:32:03.820005253Z","updated_at":"2026-11-20T04:32:03.820005253Z"}
{"id":4,"state":"failed","description":"slow","duration_ms":1000,"failure_reason":"not dispatched: queue is full","created_at":"2026-11-20T04:32:03.827551184Z","updated_at":"2026-11-20T04:32:03.827552466Z"}
{"id":5,"state":"failed","description":"slow","duration_ms":1000,"failure_reason":"not dispatched: queue is full","created_at":"2026-11-20T04:32:03.835536459Z","updated_at":"2026-11-20T04:32:03.835537651Z"}
~~~

Job 1 is `running`, 2 and 3 are `queued`, and 4 and 5 are `failed` with the reason. A refused job doesn't vanish: the caller who asks about it learns what happened. Jobs 1–3 complete one per second (one worker, 1-second jobs), so after three seconds the queue is empty. Wait that long, stop the server, and read its last log line:

~~~bash
sleep 3; kill %1; sleep 0.5; tail -1 /tmp/switchyard.log
~~~

~~~text
{"time":"2026-11-20T04:32:06.885625657Z","level":"INFO","msg":"stopped","jobs_left_in_queue":0}
~~~

### Step 7: Little's law, measured

Five requests by hand show the shape. To check the arithmetic, you need a steady stream of jobs and the averages. Create `cmd/loadjobs/main.go`:

<!-- file: cmd/loadjobs/main.go -->
~~~go
// Command loadjobs sends jobs to Switchyard at a steady rate, waits for every
// accepted job to finish, and checks Little's law against what it saw.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type job struct {
	ID        int       `json:"id"`
	State     string    `json:"state"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

func main() {
	addr := flag.String("addr", "http://127.0.0.1:8080", "Switchyard's address")
	rate := flag.Float64("rate", 10, "jobs to send per second")
	dur := flag.Duration("for", 10*time.Second, "how long to keep sending")
	work := flag.Duration("job", 500*time.Millisecond, "how long each job runs")
	flag.Parse()
	client := &http.Client{Timeout: 5 * time.Second}

	// Sample the queue depth every 100 ms until told to stop.
	var samples []float64
	stopSampling := make(chan struct{})
	sampled := make(chan struct{})
	go func() {
		defer close(sampled)
		tick := time.NewTicker(100 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-stopSampling:
				return
			case <-tick.C:
				if d, err := queueDepth(client, *addr); err == nil {
					samples = append(samples, d)
				}
			}
		}
	}()

	// Send one job per tick. Each request runs in its own goroutine, so a
	// slow answer doesn't delay the next arrival.
	body := fmt.Sprintf(`{"description":"load","duration_ms":%d}`, work.Milliseconds())
	var (
		mu       sync.Mutex
		accepted []int
		refused  int
		first503 time.Duration
		wg       sync.WaitGroup
	)
	start := time.Now()
	tick := time.NewTicker(time.Duration(float64(time.Second) / *rate))
	sent := 0
	for time.Since(start) < *dur {
		<-tick.C
		sent++
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, err := client.Post(*addr+"/jobs", "application/json", strings.NewReader(body))
			if err != nil {
				fmt.Fprintln(os.Stderr, "send:", err)
				return
			}
			defer resp.Body.Close()
			var j job
			_ = json.NewDecoder(resp.Body).Decode(&j)
			mu.Lock()
			defer mu.Unlock()
			switch resp.StatusCode {
			case http.StatusCreated:
				accepted = append(accepted, j.ID)
			case http.StatusServiceUnavailable:
				if refused == 0 {
					first503 = time.Since(start)
				}
				refused++
			}
		}()
	}
	tick.Stop()
	wg.Wait()
	sending := time.Since(start)

	// Wait until every accepted job has finished, then stop sampling.
	var done []job
	for _, id := range accepted {
		for {
			j, err := getJob(client, *addr, id)
			if err == nil && (j.State == "completed" || j.State == "failed") {
				done = append(done, j)
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	close(stopSampling)
	<-sampled
	total := time.Since(start)

	fmt.Printf("sent %d jobs in %.1f s (%.1f/s): %d accepted, %d refused with 503\n",
		sent, sending.Seconds(), float64(sent)/sending.Seconds(), len(accepted), refused)
	if refused > 0 {
		fmt.Printf("first 503 after %.1f s\n", first503.Seconds())
	}
	if len(done) == 0 {
		return
	}
	// Time in the system, from the server's own timestamps: created when
	// accepted, updated for the last time when it finished.
	var inSystem time.Duration
	for _, j := range done {
		inSystem += j.UpdatedAt.Sub(j.CreatedAt)
	}
	w := inSystem / time.Duration(len(done))
	wait := w - *work
	lambda := float64(len(done)) / total.Seconds()
	var sum float64
	for _, s := range samples {
		sum += s
	}
	fmt.Printf("all done after %.1f s: %d jobs finished, %.2f per second\n", total.Seconds(), len(done), lambda)
	fmt.Printf("time in the system: %.2f s on average (%.2f s waiting + %.2f s running)\n",
		w.Seconds(), wait.Seconds(), work.Seconds())
	fmt.Printf("Little's law: %.2f/s x %.2f s waiting = %.1f jobs waiting on average\n",
		lambda, wait.Seconds(), lambda*wait.Seconds())
	fmt.Printf("measured:     queue depth averaged %.1f over %d samples\n", sum/float64(len(samples)), len(samples))
}

// queueDepth reads jobs_queue_depth from the /metrics page.
func queueDepth(client *http.Client, addr string) (float64, error) {
	resp, err := client.Get(addr + "/metrics")
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		if v, ok := strings.CutPrefix(scanner.Text(), "jobs_queue_depth "); ok {
			return strconv.ParseFloat(v, 64)
		}
	}
	return 0, fmt.Errorf("no jobs_queue_depth in /metrics")
}

func getJob(client *http.Client, addr string, id int) (job, error) {
	resp, err := client.Get(fmt.Sprintf("%s/jobs/%d", addr, id))
	if err != nil {
		return job{}, err
	}
	defer resp.Body.Close()
	var j job
	err = json.NewDecoder(resp.Body).Decode(&j)
	return j, err
}
~~~

How it measures:

- It sends on a **schedule**: one job every `1/rate` seconds, each in its own goroutine, whether or not earlier ones have been answered. A load generator that waits for each answer before sending the next would slow down exactly when the server does, and hide the overload. Core 02 lesson 05 comes back to this.
- **L** comes from the server: every 100 ms it reads `jobs_queue_depth` from `/metrics`, and averages the samples.
- **W** comes from the jobs: `updated_at − created_at` is how long each one spent in the system, and subtracting the job's own duration leaves the time it spent waiting.
- **λ** is the number of jobs that went through, divided by the whole run.
- It then prints λ × W next to the sampled L. They're measured independently: one from the queue, one from the jobs' timestamps.

<!-- run: go vet ./cmd/loadjobs -->

Overload first: 2 workers, a 20-slot queue, half-second jobs, 10 a second for 10 seconds. Predict before you run it: when does the first `503` come, and how many jobs a second get done?

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && WORKERS=2 QUEUE_CAPACITY=20 /tmp/switchyard > /dev/null &
sleep 0.5
go run ./cmd/loadjobs -rate 10 -for 10s -job 500ms; kill %1
~~~

~~~text
sent 100 jobs in 10.0 s (10.0/s): 60 accepted, 40 refused with 503
first 503 after 3.5 s
all done after 15.3 s: 60 jobs finished, 3.93 per second
time in the system: 4.00 s on average (3.50 s waiting + 0.50 s running)
Little's law: 3.93/s x 3.50 s waiting = 13.7 jobs waiting on average
measured:     queue depth averaged 14.0 over 152 samples
~~~

- The first `503` came after 3.5 seconds, close to the 3.3 predicted: the queue grew by about 6 a second until its 20 slots were full.
- Jobs finished at about 4 a second, the most 2 workers can do with half-second jobs, however fast they arrive. The rest were refused.
- The average wait is under the 5 seconds a full queue means, because the jobs accepted in the first 3 seconds found a shorter queue.
- And Little's law holds: λ × W predicts the average number of jobs waiting, and the queue depth sampled from `/metrics` agrees, to within the noise of sampling every 100 ms.

Now the same jobs with capacity to spare: 4 workers (8 jobs a second) and 6 arrivals a second:

~~~bash
WORKERS=4 QUEUE_CAPACITY=20 /tmp/switchyard > /dev/null &
sleep 0.5
go run ./cmd/loadjobs -rate 6 -for 10s -job 500ms; kill %1
~~~

~~~text
sent 60 jobs in 10.0 s (6.0/s): 60 accepted, 0 refused with 503
all done after 10.5 s: 60 jobs finished, 5.71 per second
time in the system: 0.50 s on average (0.00 s waiting + 0.50 s running)
Little's law: 5.71/s x 0.00 s waiting = 0.0 jobs waiting on average
measured:     queue depth averaged 0.0 over 105 samples
~~~

No job waited at all. That's partly this generator's doing: it spaces arrivals perfectly evenly, so a worker is always free when the next job comes. Real traffic arrives in bursts, and a burst queues even when the average rate is well under capacity. That's why queue depth is worth a metric and an alert: the average rate can look healthy while the queue grows.

## Break it

**Go's `select` is random.** Delete the `if ctx.Err() != nil { return }` check in `Serve`, then run the queue tests twenty times:

~~~bash
go test -race -count=20 ./internal/queue
~~~

~~~text
--- FAIL: TestServeStopsTakingJobsButFinishesTheCurrentOne (0.30s)
    queue_test.go:84: finished 3 jobs, want exactly the 1 in progress
--- FAIL: TestServeStopsTakingJobsButFinishesTheCurrentOne (0.20s)
    queue_test.go:84: finished 2 jobs, want exactly the 1 in progress
--- FAIL: TestServeStopsTakingJobsButFinishesTheCurrentOne (0.20s)
    queue_test.go:84: finished 2 jobs, want exactly the 1 in progress
--- FAIL: TestServeStopsTakingJobsButFinishesTheCurrentOne (0.30s)
    queue_test.go:84: finished 3 jobs, want exactly the 1 in progress
--- FAIL: TestServeStopsTakingJobsButFinishesTheCurrentOne (0.20s)
    queue_test.go:84: finished 2 jobs, want exactly the 1 in progress
--- FAIL: TestServeStopsTakingJobsButFinishesTheCurrentOne (0.20s)
    queue_test.go:84: finished 2 jobs, want exactly the 1 in progress
--- FAIL: TestServeStopsTakingJobsButFinishesTheCurrentOne (0.30s)
    queue_test.go:84: finished 3 jobs, want exactly the 1 in progress
FAIL
FAIL	switchyard/internal/queue	5.099s
FAIL
~~~

It fails some of the time, not every time. After `cancel()`, two `select` cases are ready at once: `ctx.Done()` is closed **and** jobs are waiting. When several cases are ready, Go chooses **at random**, deliberately, so no case can starve the others. Some of the time, a "stopped" worker grabs one more job. A test run once would usually pass, which is why `-count=20` matters for concurrent code. Restore the check: it runs before the `select`, so cancellation wins whenever it has already happened.

**No backpressure.** In `Dispatch`, delete the `default:` case and its `return ErrFull`, so a full queue makes the sender wait. Run the queue tests, with a short timeout:

~~~bash
go test -timeout 5s ./internal/queue 2>&1 | grep -E -A1 '^panic|running tests|chan send'
~~~

~~~text
panic: test timed out after 5s
	running tests:
		TestFullQueueRefusesImmediately (5s)
--
goroutine 3 [chan send]:
switchyard/internal/queue.(*Queue).Dispatch(...)
~~~

The test didn't fail; it **hung**, until the 5-second timeout killed it. The stack shows where: a goroutine stuck in `Dispatch` on a `chan send`. Now the same through the API. Rebuild, start it with one worker and two slots again, and time the five requests:

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && WORKERS=1 QUEUE_CAPACITY=2 /tmp/switchyard > /dev/null &
sleep 0.5
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -w "job $i: %{http_code} after %{time_total} s\n" \
    -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' \
    -d '{"description":"slow","duration_ms":1000}'
done
kill %1
~~~

~~~text
job 1: 201 after 0.001592 s
job 2: 201 after 0.001093 s
job 3: 201 after 0.000829 s
job 4: 201 after 0.967855 s
job 5: 201 after 0.986393 s
~~~

Every job is "accepted", but jobs 4 and 5 each hung for about a second, until the worker freed a slot. With slower jobs they'd hang far past the 2-second request deadline, because a plain channel send ignores the context entirely. The caller can't tell "slow" from "overloaded", and every waiting request holds a goroutine and a connection. That's how overload spreads from one service to everything that calls it. Restore the `default` case.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race -count=3 ./...
~~~

Then answer: with 4 workers and 1-second jobs, how long does the last job in a full 100-slot queue wait? Why `503` and not `429`? What does a refused job look like in `GET /jobs/{id}`, and why is that better than the job vanishing?

Read *Site Reliability Engineering* (free at sre.google), Ch. 21, *Handling Overload*, and Harchol-Balter, *Performance Modeling and Design of Computer Systems*, Ch. 6 (*Little's Law and Other Operational Laws*). Carry this question in: why reject early rather than queue?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

That proves the service accepts work without being swamped by it, and says so when it's full. But a `503` asks the caller to try again, and a retried `POST` creates a second job. The next lesson makes retries safe.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `POST /jobs` hangs instead of answering `503` | `Dispatch` blocks: its `default` case is missing | Restore the non-blocking send |
| A queue test passes once and fails with `-count=20` | An ordering assumption (remember `select` is random) | Run concurrent tests many times; never trust one pass |
| Jobs stay `queued` forever | The workers never started, or stopped | Check that `run` starts `work.Serve`; the `listening` log line shows the worker count |
| `WORKERS must be a positive whole number, got "0"` | The setting is `0` or not a number | Use `1` or more |
| `loadjobs` prints `send: ... connection refused` | Switchyard isn't running at `-addr` | Start it first, and check the port |
| `loadjobs` never finishes | An accepted job never reached `completed` or `failed` | Press Ctrl+C, then read Switchyard's log |
