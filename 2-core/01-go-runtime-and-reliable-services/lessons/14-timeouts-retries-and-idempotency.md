# 14 Timeouts, retries and idempotency

> Module: Go runtime and reliable services · Time: ~6 h · Builds on: 13

## The problem

Lesson 13's `503` tells the caller to try again. So does every timeout: a client sends `POST /jobs`, the network drops the answer, and the client can't tell whether the job was created. If it retries, there may be two jobs. If it doesn't, there may be none.

The work has the same problem from the other side. Work fails for passing reasons (a network blip, a dependency that's restarting, a lock held a moment too long), and the worker should try again. But if an attempt did its job and only the *answer* was lost, trying again does the job twice: two charges on a card, two emails, two copies of a file.

Retrying is how a distributed system survives failures. This lesson makes it safe.

## The mental model

Duplicates now come from two places, and lesson 16 adds a third:

~~~text
 client ──POST /jobs──► API ──► queue ──► worker ──► the work ──► its effect
   │ retry: the answer was lost      │ retry: the work failed        (a payment, an email)
   ▼                                 ▼
 defence: an idempotency key     defence: the effect is recorded under a key
 the API remembers the answer    the job owns, so it's recorded once
                                 (lesson 16: a second worker runs the same job; same key)
~~~

Two words first:

- An operation is **idempotent** if doing it twice has the same result as doing it once. `GET` is idempotent by definition, and so is "set job 7's result to X". "Add a payment" and "create a job" aren't.
- **At-least-once** delivery is what retries give you: every operation happens, possibly more than once. Making the *effect* idempotent turns at-least-once into "exactly once in effect", which is the only kind of "exactly once" that exists between machines.

For the client's retries:

- An **idempotency key** is a unique value the *client* chooses for one logical operation and sends with every retry of it: `Idempotency-Key: 9f1c...`. The server remembers the key with the response it gave. A retry with the same key gets the **same response** back, and the work isn't done again. Stripe's API popularised this, and an IETF draft standardises the header.
- A key is bound to *one* request. Reusing it with a different body is a client bug, answered with **422 Unprocessable Content**.
- If a retry arrives while the original is **still being processed**, the server can't replay a response it doesn't have yet. It answers **409 Conflict** with `Retry-After`.
- Only *final* answers are remembered. A 5xx means "something went wrong on our side", so the key is released and the client may retry for real.
- A **fingerprint** is a hash of the request (method, path, body) that identifies "the same request" cheaply. **SHA-256** is a cryptographic hash: any change to the input gives a completely different 32-byte output.
- Remembered keys **expire** after a while (here, 24 hours by default). Otherwise memory grows forever. Removing expired keys on a timer is a **background job**: work that runs on a schedule, not in response to a request.

For the worker's retries:

- A **transient** failure might succeed if tried again. A **permanent** one never will (a malformed request, a validation error). Only retry transient failures.
- **Exponential backoff**: wait longer before each retry (100 ms, 200 ms, 400 ms, ...) up to a cap, giving the dependency room to recover.
- **Jitter**: randomise each wait. With "full jitter", the wait is a random value between 0 and the backoff ceiling. Without jitter, a thousand clients that failed together retry together, again and again: a **thundering herd**. AWS's analysis found full jitter does the least total work while finishing fastest.
- **A retry budget**: a fixed number of attempts, and all of them inside the job's deadline. Retries never extend a deadline; they spend it. That's where the timeouts of lesson 10 come back: the deadline is what stops a retry loop from running forever.

## The pattern

**Retry freely; make every effect idempotent.** Retries handle the failures; keys make the retries harmless. The key must name the *operation*, not the attempt: the client's key covers every retry of one request, and the effect's key, derived from the job's ID, covers every attempt at one job, by any worker.

## Build it

### Step 1: The idempotency store and middleware

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

- `Begin` does **claim, check and look up in one locked step**. Two copies of a request arriving together can't both see "unknown key": one claims it, and the other gets `ErrInProgress`. It's lesson 07's check-then-act race, solved the same way: decide and write under one lock.
- The body is read once to fingerprint it, then put back with `io.NopCloser(bytes.NewReader(body))`, so the real handler can read it again.
- `responseRecorder` writes the response through to the client **and** keeps a copy. It's the same embedding trick as lesson 11's `statusRecorder`.
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


### Step 2: Wire it into the API

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
	"switchyard/internal/jobs"
)
~~~

to:

~~~go
	"switchyard/internal/idempotency"
	"switchyard/internal/jobs"
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

	"switchyard/internal/jobs"
~~~

to:

~~~go
	"strings"
	"testing"
	"time"

	"switchyard/internal/idempotency"
	"switchyard/internal/jobs"
~~~

<!-- run: go vet ./internal/... && go test -race ./internal/httpapi/... -->

### Step 3: A background job: sweeping expired keys

`main` creates the store, passes it to the handler, exposes how many keys it holds, and runs `Sweep` every minute until shutdown. In `cmd/switchyard/main.go`, add the setting. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	QueueCapacity  int
	JobTimeout     time.Duration
}
~~~

to:

~~~go
	QueueCapacity  int
	JobTimeout     time.Duration
	IdempotencyTTL time.Duration
}
~~~

Give it a default. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
		JobTimeout:     10 * time.Second,
	}
~~~

to:

~~~go
		JobTimeout:     10 * time.Second,
		IdempotencyTTL: 24 * time.Hour,
	}
~~~

and read it from the environment. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	if cfg.QueueCapacity, err = positiveIntFromEnv(getenv, "QUEUE_CAPACITY", cfg.QueueCapacity); err != nil {
		return config{}, err
	}
	return cfg, nil
~~~

to:

~~~go
	if cfg.QueueCapacity, err = positiveIntFromEnv(getenv, "QUEUE_CAPACITY", cfg.QueueCapacity); err != nil {
		return config{}, err
	}
	if cfg.IdempotencyTTL, err = durationFromEnv(getenv, "IDEMPOTENCY_TTL", cfg.IdempotencyTTL); err != nil {
		return config{}, err
	}
	return cfg, nil
~~~

Create the store and pass it to the handler. Change:

<!-- edit: cmd/switchyard/main.go -->
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

Start the sweeper next to the workers. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	workersDone := make(chan struct{})
	go func() {
		work.Serve(stopTaking, cfg.Workers, runJob)
		close(workersDone)
	}()

~~~

to:

~~~go
	workersDone := make(chan struct{})
	go func() {
		work.Serve(stopTaking, cfg.Workers, runJob)
		close(workersDone)
	}()

	// A background job: forget expired idempotency keys once a minute,
	// until the service starts shutting down.
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
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

<!-- edit: cmd/switchyard/main.go -->
~~~go
	"switchyard/internal/httpapi"
	"switchyard/internal/jobs"
~~~

to:

~~~go
	"switchyard/internal/httpapi"
	"switchyard/internal/idempotency"
	"switchyard/internal/jobs"
~~~

`time.NewTicker` sends the current time on its channel `C` at a fixed interval. The `select` waits for the next tick *or* shutdown, the same shape as `Simulate`. The ticker is stopped with `defer`, so it doesn't keep running after the goroutine exits. The sweeper watches `ctx`, the context that's cancelled on SIGTERM, so it's the first thing to stop.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

### Step 4: Retry the same create

Start Switchyard, and send the same request twice with the same key, the way a client retries after losing an answer:

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && /tmp/switchyard > /dev/null &
sleep 0.5
for i in 1 2; do
  curl -s -i -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: order-42' -d '{"description":"resize","duration_ms":100}' | grep -v '^Date'
  echo
done
curl -s -w "  [%{http_code}]\n" http://127.0.0.1:8080/jobs/2
~~~

~~~text
HTTP/1.1 201 Created
Content-Type: application/json
Location: /jobs/1
Content-Length: 159

{"id":1,"state":"queued","description":"resize","duration_ms":100,"created_at":"2026-11-20T04:42:39.380510679Z","updated_at":"2026-11-20T04:42:39.380510679Z"}

HTTP/1.1 201 Created
Content-Type: application/json
Idempotent-Replayed: true
Location: /jobs/1
Content-Length: 159

{"id":1,"state":"queued","description":"resize","duration_ms":100,"created_at":"2026-11-20T04:42:39.380510679Z","updated_at":"2026-11-20T04:42:39.380510679Z"}

{"error":"job not found"}
  [404]
~~~

The second response is the first one, replayed, with `Idempotent-Replayed: true`, and job 2 doesn't exist: one job was created. Notice the replay still says `"state":"queued"`, though a worker finished job 1 within a tenth of a second. A replay is the **original answer**, not the current state. The client asked "did my create happen?", and the answer is "yes, and here's exactly what I told you then". To see the job now, it calls `GET /jobs/1`.

Reuse the key with a different body, then count the keys:

~~~bash
curl -s -i -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: order-42' -d '{"description":"thumbnail"}' | grep -v '^Date'
echo
curl -s http://127.0.0.1:8080/metrics | grep '^idempotency_keys'
kill %1
~~~

~~~text
HTTP/1.1 422 Unprocessable Entity
Content-Type: application/json
Content-Length: 69

{"error":"Idempotency-Key was already used for a different request"}

idempotency_keys 1
~~~

### Step 5: Retry with backoff and jitter

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
- `math/rand/v2` gives a fast random number that is **not** cryptographically secure. That's fine for jitter; anything an attacker mustn't guess, such as a session token, needs `crypto/rand`.
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

### Step 6: An effect that happens once

So far a job's work is `Simulate`: it waits, and changes nothing. Real work has an **effect**, the one change in the world the job exists to make. Switchyard's jobs now record theirs in a **ledger**, and the ledger is where "exactly once" is decided: the work may run twice, but the effect is written under a key, and a key is recorded once.

Create `internal/ledger/ledger.go`:

<!-- file: internal/ledger/ledger.go -->
~~~go
// Package ledger records each job's effect: the one change in the world the
// job exists to make, such as a payment taken, an email sent or a file
// written. Work can run more than once (a retry, a second worker), so the
// effect must not: Apply records each key once, however often it is called.
package ledger

import (
	"fmt"
	"sync"
	"time"

	"switchyard/internal/jobs"
)

// Entry is one recorded effect.
type Entry struct {
	Key   string
	JobID jobs.ID
	At    time.Time
}

// Ledger is an in-memory, concurrency-safe record of effects.
type Ledger struct {
	mu         sync.Mutex
	entries    map[string]Entry
	perJob     map[jobs.ID]int
	duplicates int
}

func New() *Ledger {
	return &Ledger{entries: make(map[string]Entry), perJob: make(map[jobs.ID]int)}
}

// Apply records the effect named by key, for the given job, unless that key
// was recorded before. It reports whether this call recorded it. Checking
// and recording happen under one lock, so two concurrent calls with the
// same key can't both record it.
func (l *Ledger) Apply(key string, job jobs.ID, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if _, done := l.entries[key]; done {
		l.duplicates++
		return false
	}
	l.entries[key] = Entry{Key: key, JobID: job, At: now}
	l.perJob[job]++
	return true
}

// EffectsFor is how many effects were recorded for a job. For a correct
// system it is 1 for every completed job, and never more.
func (l *Ledger) EffectsFor(job jobs.ID) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.perJob[job]
}

// Counts returns how many effects were recorded, and how many repeated
// calls were recognised and ignored.
func (l *Ledger) Counts() (applied, duplicates int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.entries), l.duplicates
}

// KeyFor is the idempotency key for a job's effect. It is derived from the
// job's ID alone, so every attempt at the same job, by any worker, uses the
// same key.
func KeyFor(job jobs.ID) string {
	return fmt.Sprintf("job-%d", job)
}
~~~

- `Apply` is the idempotent write: "record effect `job-7`", not "add another effect". It's a check-then-act, so the check and the write happen under one lock, as in lesson 07.
- `KeyFor` derives the key from the job's ID **alone**. Every attempt at job 7, whichever worker makes it, uses `job-7`. That's the whole trick: the key names the operation, not the attempt.
- `EffectsFor` exists so tests, and later the module's gate, can check the promise: one effect per job, never two.

Create `internal/ledger/ledger_test.go`:

<!-- file: internal/ledger/ledger_test.go -->
~~~go
package ledger

import (
	"sync"
	"testing"
	"time"
)

func TestApplyRecordsAKeyOnce(t *testing.T) {
	l := New()
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	if !l.Apply(KeyFor(7), 7, now) {
		t.Fatal("first Apply = false, want true")
	}
	if l.Apply(KeyFor(7), 7, now) {
		t.Fatal("second Apply = true, want false: the effect was already recorded")
	}
	if got := l.EffectsFor(7); got != 1 {
		t.Fatalf("EffectsFor(7) = %d, want 1", got)
	}
	if applied, duplicates := l.Counts(); applied != 1 || duplicates != 1 {
		t.Fatalf("Counts = %d applied, %d duplicates; want 1 and 1", applied, duplicates)
	}
}

func TestConcurrentAppliesRecordOnce(t *testing.T) {
	l := New()
	var wg sync.WaitGroup
	var mu sync.Mutex
	recorded := 0
	for range 50 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if l.Apply(KeyFor(1), 1, time.Now()) {
				mu.Lock()
				recorded++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if recorded != 1 || l.EffectsFor(1) != 1 {
		t.Fatalf("recorded by %d callers, %d effects for job 1; want 1 and 1", recorded, l.EffectsFor(1))
	}
}

func TestKeysAreStablePerJob(t *testing.T) {
	if KeyFor(3) != KeyFor(3) || KeyFor(3) == KeyFor(4) {
		t.Fatalf("KeyFor(3) = %q, KeyFor(4) = %q: want the same key per job, different keys across jobs", KeyFor(3), KeyFor(4))
	}
}
~~~

<!-- run: go test -race -count=3 ./internal/ledger/... -->

### Step 7: Retry the work

`Service.Run` gets a retry policy. In `internal/jobs/service.go`, import the package. Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	"fmt"
	"time"
)
~~~

to:

~~~go
	"fmt"
	"time"

	"switchyard/internal/retry"
)
~~~

Add the policy to `Service`. Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	now      func() time.Time
	work     WorkFunc
}
~~~

to:

~~~go
	now      func() time.Time
	work     WorkFunc
	retry    retry.Policy
}
~~~

Add an option, next to `WithDispatcher`. Change:

<!-- edit: internal/jobs/service.go -->
~~~go
// WithDispatcher sends every created job to d.
~~~

to:

~~~go
// WithRetry retries work that fails, following p. Without it, work is
// tried once.
func WithRetry(p retry.Policy) Option {
	return func(s *Service) { s.retry = p }
}

// WithDispatcher sends every created job to d.
~~~

Without the option, work is tried once, as before. The new field makes `gofmt` re-align the defaults, so here are all four. Change:

<!-- edit: internal/jobs/service.go -->
~~~go
		repo: repo,
		now:  func() time.Time { return time.Now().UTC() },
		work: Simulate,
	}
~~~

to:

~~~go
		repo:  repo,
		now:   func() time.Time { return time.Now().UTC() },
		work:  Simulate,
		retry: retry.Policy{Attempts: 1},
	}
~~~

And retry the work. Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	workErr := s.work(ctx, job)

~~~

to:

~~~go
	// Retry failed work while the job's deadline allows. Once the context
	// is done, another attempt can't succeed, so stop at once.
	workErr := s.retry.Do(ctx, func(ctx context.Context) error {
		err := s.work(ctx, job)
		if err != nil && ctx.Err() != nil {
			return retry.Stop(err)
		}
		return err
	})

~~~

If an attempt fails because the job's deadline passed or it was cancelled, `retry.Stop` ends the loop at once: another attempt would fail the same way. Everything else is retried, which is right for this work; a job whose work could fail *permanently* would return `retry.Stop` itself.

Test the three outcomes. In `internal/jobs/service_test.go`, add the import. Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	"switchyard/internal/jobs"
	"switchyard/internal/memstore"
)
~~~

to:

~~~go
	"switchyard/internal/jobs"
	"switchyard/internal/memstore"
	"switchyard/internal/retry"
)
~~~

and add at the end of the file:

<!-- append: internal/jobs/service_test.go -->
~~~go
// noWait is a retry policy that doesn't sleep, so tests run instantly.
func noWait(attempts int) retry.Policy {
	return retry.Policy{
		Attempts: attempts,
		Base:     time.Millisecond,
		Max:      time.Millisecond,
		Sleep:    func(context.Context, time.Duration) error { return nil },
	}
}

func TestRunRetriesFailedWork(t *testing.T) {
	calls := 0
	failTwice := func(context.Context, jobs.Job) error {
		calls++
		if calls <= 2 {
			return errors.New("transient failure")
		}
		return nil
	}
	svc := jobs.NewService(memstore.New(), jobs.WithWork(failTwice), jobs.WithRetry(noWait(3)))
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)

	done, err := svc.Run(ctx, job.ID)
	if err != nil || done.State != jobs.StateCompleted || calls != 3 {
		t.Fatalf("state = %s, err = %v, work ran %d times; want completed, nil, 3", done.State, err, calls)
	}
}

func TestRunGivesUpAfterTheLastAttempt(t *testing.T) {
	calls := 0
	alwaysFail := func(context.Context, jobs.Job) error {
		calls++
		return errors.New("transient failure")
	}
	svc := jobs.NewService(memstore.New(), jobs.WithWork(alwaysFail), jobs.WithRetry(noWait(3)))
	ctx := context.Background()
	job, _ := svc.Create(ctx, "resize", 0)

	done, err := svc.Run(ctx, job.ID)
	if !errors.Is(err, jobs.ErrWorkFailed) || done.State != jobs.StateFailed || calls != 3 {
		t.Fatalf("state = %s, err = %v, work ran %d times; want failed, ErrWorkFailed, 3", done.State, err, calls)
	}
	if done.FailureReason != "failed after 3 attempts: transient failure" {
		t.Fatalf("reason = %q", done.FailureReason)
	}
}

func TestRunDoesNotRetryPastTheDeadline(t *testing.T) {
	calls := 0
	slow := func(ctx context.Context, job jobs.Job) error {
		calls++
		return jobs.Simulate(ctx, job)
	}
	svc := jobs.NewService(memstore.New(), jobs.WithWork(slow), jobs.WithRetry(noWait(5)))
	job, _ := svc.Create(context.Background(), "slow", time.Second)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	done, _ := svc.Run(ctx, job.ID)
	if calls != 1 || done.FailureReason != "deadline exceeded" {
		t.Fatalf("work ran %d times, reason %q; want 1 and \"deadline exceeded\"", calls, done.FailureReason)
	}
}
~~~

`noWait` replaces the policy's `Sleep`, so three attempts take no time at all. That's why `Policy` made `Sleep` injectable.

<!-- run: go test -race ./internal/jobs/... -->

To watch retries happen, you need failures, and the most dangerous kind: the work, and its effect, happened, but the result was lost on the way back. Create `internal/chaos/chaos.go`:

<!-- file: internal/chaos/chaos.go -->
~~~go
// Package chaos injects failures on purpose, to show how the rest of the
// system copes. Breaking things deliberately, in a controlled way, is the
// idea behind chaos engineering.
package chaos

import (
	"context"
	"errors"

	"switchyard/internal/jobs"
)

// ErrResultLost is the failure LoseResults injects.
var ErrResultLost = errors.New("injected: the work was done, but its result was lost")

// LoseResults wraps work so that, with probability rate, an attempt that
// succeeded reports failure anyway. It is the worst kind of transient
// failure: the work, and its effect, really happened, but the caller can't
// know, so it tries again. random returns a number in [0, 1).
func LoseResults(work jobs.WorkFunc, rate float64, random func() float64) jobs.WorkFunc {
	return func(ctx context.Context, job jobs.Job) error {
		if err := work(ctx, job); err != nil {
			return err
		}
		if random() < rate {
			return ErrResultLost
		}
		return nil
	}
}
~~~

Create `internal/chaos/chaos_test.go`:

<!-- file: internal/chaos/chaos_test.go -->
~~~go
package chaos

import (
	"context"
	"errors"
	"testing"

	"switchyard/internal/jobs"
)

func TestLoseResultsRunsTheWorkThenFails(t *testing.T) {
	ran := 0
	work := func(context.Context, jobs.Job) error { ran++; return nil }

	lossy := LoseResults(work, 0.5, func() float64 { return 0.2 }) // 0.2 < 0.5: lose it
	if err := lossy(context.Background(), jobs.Job{}); !errors.Is(err, ErrResultLost) || ran != 1 {
		t.Fatalf("err = %v, work ran %d times; want ErrResultLost after the work ran once", err, ran)
	}
	kept := LoseResults(work, 0.5, func() float64 { return 0.7 }) // 0.7 >= 0.5: keep it
	if err := kept(context.Background(), jobs.Job{}); err != nil || ran != 2 {
		t.Fatalf("err = %v, work ran %d times; want nil and 2", err, ran)
	}
}
~~~

<!-- run: go test ./internal/chaos/... -->

Now `main` decides what a job's work is: wait for its duration, then record its effect. It counts every attempt, exposes the ledger's counts as metrics, and reads two settings: `RETRY_ATTEMPTS` (default 3) and `FAIL_RATE` (default 0, no injected failures). In `cmd/switchyard/main.go`, add the imports. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	"log/slog"
	"net"

~~~

to:

~~~go
	"log/slog"
	"math/rand/v2"
	"net"

~~~

and:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	"switchyard/internal/httpapi"
	"switchyard/internal/idempotency"
	"switchyard/internal/jobs"
	"switchyard/internal/memstore"
	"switchyard/internal/queue"

~~~

to:

~~~go
	"switchyard/internal/chaos"
	"switchyard/internal/httpapi"
	"switchyard/internal/idempotency"
	"switchyard/internal/jobs"
	"switchyard/internal/ledger"
	"switchyard/internal/memstore"
	"switchyard/internal/queue"
	"switchyard/internal/retry"

~~~

Add the settings. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	JobTimeout     time.Duration
	IdempotencyTTL time.Duration
}
~~~

to:

~~~go
	JobTimeout     time.Duration
	IdempotencyTTL time.Duration
	RetryAttempts  int
	FailRate       float64
}
~~~

and:

<!-- edit: cmd/switchyard/main.go -->
~~~go
		IdempotencyTTL: 24 * time.Hour,
	}
~~~

to:

~~~go
		IdempotencyTTL: 24 * time.Hour,
		RetryAttempts:  3,
	}
~~~

Read them. `FAIL_RATE` is a fraction, so it gets its own check. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	if cfg.IdempotencyTTL, err = durationFromEnv(getenv, "IDEMPOTENCY_TTL", cfg.IdempotencyTTL); err != nil {
		return config{}, err
	}
	return cfg, nil
}
~~~

to:

~~~go
	if cfg.IdempotencyTTL, err = durationFromEnv(getenv, "IDEMPOTENCY_TTL", cfg.IdempotencyTTL); err != nil {
		return config{}, err
	}
	if cfg.RetryAttempts, err = positiveIntFromEnv(getenv, "RETRY_ATTEMPTS", cfg.RetryAttempts); err != nil {
		return config{}, err
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
~~~

Build the work, the ledger and the metrics, and give the service its work and its retry policy. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	work := queue.New(cfg.QueueCapacity)
	service := jobs.NewService(memstore.New(), jobs.WithDispatcher(work))

	metrics := httpapi.NewMetrics()

~~~

to:

~~~go
	metrics := httpapi.NewMetrics()

	// A job's work: wait for its duration, then record its effect in the
	// ledger, under a key that every attempt at this job shares.
	effects := ledger.New()
	attempts := prometheus.NewCounter(prometheus.CounterOpts{
		Name: "job_attempts_total",
		Help: "Attempts at a job's work, retries included.",
	})
	var jobWork jobs.WorkFunc = func(ctx context.Context, job jobs.Job) error {
		attempts.Inc()
		if err := jobs.Simulate(ctx, job); err != nil {
			return err
		}
		effects.Apply(ledger.KeyFor(job.ID), job.ID, time.Now().UTC())
		return nil
	}
	if cfg.FailRate > 0 {
		jobWork = chaos.LoseResults(jobWork, cfg.FailRate, rand.Float64)
	}
	metrics.MustRegister(attempts,
		prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "effects_applied_total",
			Help: "Job effects recorded in the ledger.",
		}, func() float64 { applied, _ := effects.Counts(); return float64(applied) }),
		prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "effects_duplicate_total",
			Help: "Repeated effects the ledger recognised and ignored.",
		}, func() float64 { _, duplicates := effects.Counts(); return float64(duplicates) }),
	)

	work := queue.New(cfg.QueueCapacity)
	service := jobs.NewService(memstore.New(),
		jobs.WithDispatcher(work),
		jobs.WithWork(jobWork),
		jobs.WithRetry(retry.Policy{Attempts: cfg.RetryAttempts, Base: 100 * time.Millisecond, Max: 2 * time.Second}),
	)


~~~

- `prometheus.NewCounterFunc` is a counter whose value comes from a function, like lesson 13's gauge. The ledger already counts, so the metrics just read it.
- `chaos.LoseResults` wraps the work only when `FAIL_RATE` is set: in normal running, nothing is injected.
- The metrics registry moved up, because the work's counter is registered on it before the service is built.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

### Step 8: Lose half the results

Start Switchyard with `FAIL_RATE=0.5`: half of all attempts do their work, record their effect, and then report failure anyway. Create 20 short jobs, give the workers three seconds, then read the counters and the jobs' states:

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && FAIL_RATE=0.5 /tmp/switchyard > /dev/null &
sleep 0.5
for i in $(seq 20); do
  curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' \
    -d '{"description":"charge","duration_ms":50}'
done
sleep 3
curl -s http://127.0.0.1:8080/metrics | grep -E '^(job_attempts_total|effects_)'
for i in $(seq 20); do curl -s http://127.0.0.1:8080/jobs/$i; done | grep -o '"state":"[a-z]*"' | sort | uniq -c
kill %1
~~~

`seq 20` prints the numbers 1 to 20, and `sort | uniq -c` counts the states.

~~~text
effects_applied_total 20
effects_duplicate_total 15
job_attempts_total 35
     16 "state":"completed"
      4 "state":"failed"
~~~

Predict, then check:

- A job fails only if all three attempts lose their result: 0.5 × 0.5 × 0.5 = 12.5%, or 2.5 jobs in 20 on average. With only 20 jobs, anything from 1 to 5 is ordinary luck. Without retries, about **ten** would have failed.
- Attempts: every job makes a first attempt, half make a second, a quarter a third. 20 × (1 + 0.5 + 0.25) = 35 on average.
- Effects: **exactly 20**, one per job. Every attempt after the first called `Apply` again with the same key, and the ledger recognised it: that's `effects_duplicate_total`, the attempts minus the jobs.

Look hard at the failed jobs. Their work ran three times, and their effect *was* recorded, once, yet they say `failed`, because every attempt's result was lost. From where the service stands, that's the truth: it can't know. "Failed" means "we don't know that it worked", not "it didn't happen". That's exactly why the effect must be safe to repeat: the only way to find out is to try again.

### The defences, together

| Duplicate from | Defence | Where |
|---|---|---|
| A client retries `POST /jobs` | An idempotency key: the API replays the stored answer | `internal/idempotency`, steps 1–3 |
| A worker retries a job's work | The effect is recorded under the job's key, once | `internal/ledger`, step 6 |
| A second worker runs a job whose first worker vanished | The same ledger key, and lesson 07's compare-and-swap on the job | Lesson 16 |

The ledger here is in the same process as the work, so it's easy. When the effect is somewhere else, the usual techniques are:

- **Write results keyed by the job's ID** (an upsert: "set the result for job 7"), never append ("add another result").
- **Pass an idempotency key to anything with side effects.** A payment provider, an email service and a webhook receiver can each deduplicate if you send the same key on a retry. The job's ID plus the step name would do.
- **Record "done" and the effect in one transaction.** That needs a database, and it's called the **inbox** pattern: a table of processed IDs, written in the same transaction as the effect. The *Event streams* unit builds it.

Remember this the next time someone says their system has "exactly-once processing". Ask which of these they built.

**Limits.** The idempotency keys and the ledger live in this process's memory, so they're lost on restart and not shared between two copies of the API behind a load balancer. A database fixes both, with a unique constraint doing the claiming.

## Break it

**Drop the fingerprint.** In `Begin`, delete the fingerprint check (`if r.fingerprint != fingerprint { return nil, ErrMismatch }`) and run the idempotency tests:

~~~bash
go test ./internal/idempotency
~~~

~~~text
--- FAIL: TestReusedKeyWithDifferentBodyIsRejected (0.00s)
    idempotency_test.go:70: status = 201, want 422
FAIL
FAIL	switchyard/internal/idempotency	0.059s
FAIL
~~~

Without the fingerprint, a client that reuses a key by mistake for a *different* job gets a reply about the old job, a cheerful `201` for work that was never done. Silent wrong answers are the worst kind. Restore the check.

**A key per attempt.** In `main.go`, make the effect's key "more unique": change `ledger.KeyFor(job.ID)` to `fmt.Sprintf("job-%d-%d", job.ID, time.Now().UnixNano())`. Rebuild, and run step 8 again:

~~~text
effects_applied_total 35
effects_duplicate_total 0
job_attempts_total 35
     17 "state":"completed"
      3 "state":"failed"
~~~

Every attempt is now a new effect: about 35 effects for 20 jobs, and the ledger saw no duplicates, because no two keys were ever the same. A key that changes on every attempt isn't an idempotency key at all. Put `ledger.KeyFor(job.ID)` back.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race -count=3 ./...
~~~

Then answer: why must claiming a key and checking it happen under one lock? Why are 5xx responses not remembered? Why jitter, and not just backoff? Why do retries stop at the job's deadline? A job says `failed`: did its effect happen?

Read Stripe's engineering post [*Designing robust and predictable APIs with idempotency*](https://stripe.com/blog/idempotency), the IETF draft [*The Idempotency-Key HTTP Header Field*](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/), and Marc Brooker, [*Exponential Backoff And Jitter*](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/) (AWS Architecture Blog). Carry this question in: when do retries make an outage *worse*?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

That proves a retried request creates one job, and a retried job records one effect. Everything still runs in one process. The next lesson gives Switchyard a second way in, gRPC, so that in lesson 16 the workers can move out into processes of their own.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| A retried `POST /jobs` creates a second job | The `Idempotency-Key` header wasn't sent, or differs | Send the same key with every retry of one request |
| `422` on a retry | The retry's body differs from the original's, even by a space | Send exactly the same body; a new request needs a new key |
| `409` with `Retry-After` on a retry | The original is still being processed | Wait and retry; the replay comes once it finishes |
| Every job fails with `failed after 3 attempts` | `FAIL_RATE` is set too high, or set when you didn't mean it | Unset it: `unset FAIL_RATE` |
| `FAIL_RATE must be a fraction...` | `1`, a percentage, or text | Use a number such as `0.5` |
| `effects_applied_total` is higher than the number of jobs | The effect's key changes between attempts | Derive it from the job's ID alone: `ledger.KeyFor(job.ID)` |
| A retry test sleeps for seconds | The test's policy uses the real `Sleep` | Use a policy whose `Sleep` returns at once, like `noWait` |
