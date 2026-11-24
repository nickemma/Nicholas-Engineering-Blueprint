# 10 Deadlines and cancellation

> Module: Go runtime and reliable services · Time: ~5 h · Builds on: 09

## The problem

Run a job with `duration_ms: 5000` and the request takes five seconds. If the work hung forever, so would the request, holding a goroutine, memory and a connection the whole time. Every request needs an upper bound, and when the caller gives up, the work should stop too.

## The mental model

- A **deadline** is a point in time after which the work is pointless. `context.WithTimeout(parent, d)` returns a child context that is cancelled when `d` passes **or** when the parent is cancelled, whichever comes first.
- Contexts form a **tree**. Cancelling a parent cancels every descendant. The HTTP server cancels `r.Context()` when the client disconnects. The middleware adds a deadline below that, and `Simulate`'s `select` watches `ctx.Done()`. So one signal reaches the bottom of the call stack.

  ~~~mermaid
  flowchart TD
      A["r.Context()<br/>cancelled if the client disconnects"] --> B["withTimeout: WithTimeout 2s<br/>cancelled at the deadline"]
      B --> C["Service.Run(ctx)"]
      C --> D["Simulate: select on ctx.Done()"]
  ~~~

## The pattern

**Bound every request, and let cancellation flow down.** A deadline at the top of the call tree reaches the bottom through the context, and every piece of work that can wait watches `ctx.Done()`.

- **Middleware** is a function that takes a handler and returns a new handler that does something before or after the original. It's the **decorator pattern** again, this time for HTTP.
- **504 Gateway Timeout** tells the caller "this took too long on our side", which is different from a client-side timeout.

## Build it

### Step 1: Middleware with a deadline

Create `internal/httpapi/middleware.go`:

<!-- file: internal/httpapi/middleware.go -->
~~~go
package httpapi

import (
	"context"
	"net/http"
	"time"
)

// withTimeout gives every request a deadline. Handlers pass r.Context() down,
// so the work below them stops when the deadline passes.
func withTimeout(d time.Duration, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), d)
		defer cancel()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
~~~

`defer cancel()` releases the timer the context holds, even if the request finishes early. Always call the `cancel` you're given; `go vet` warns if you don't. `http.HandlerFunc(...)` turns an ordinary function into an `http.Handler`.

### Step 2: Options for the handler

`NewHandler` gains functional options, the same pattern as the service (lesson 07). Make these changes to `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
// NewHandler builds the routes. Each pattern names a method and a path, so
// the router itself answers 405 for a known path with the wrong method.
func NewHandler(service JobService) http.Handler {
~~~

to:

~~~go
type config struct {
	requestTimeout time.Duration
}

// Option configures the handler built by NewHandler.
type Option func(*config)

// WithRequestTimeout bounds how long any one request may run.
func WithRequestTimeout(d time.Duration) Option {
	return func(c *config) { c.requestTimeout = d }
}

// NewHandler builds the routes and gives every request a deadline.
func NewHandler(service JobService, opts ...Option) http.Handler {
	cfg := config{requestTimeout: 2 * time.Second}
	for _, opt := range opts {
		opt(&cfg)
	}

~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	return mux
~~~

to:

~~~go
	return withTimeout(cfg.requestTimeout, mux)
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	job, err := h.jobs.Run(r.Context(), id)
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toResponse(job))
}

func parseID(w http.ResponseWriter, r *http.Request) (jobs.ID, bool) {
~~~

to:

~~~go
	job, err := h.jobs.Run(r.Context(), id)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, toResponse(job))
	case errors.Is(err, context.DeadlineExceeded):
		writeJSON(w, http.StatusGatewayTimeout, toResponse(job))
	case errors.Is(err, context.Canceled):
		// The client hung up. There is nobody left to answer.
	default:
		h.writeDomainError(w, r, err)
	}
}

func parseID(w http.ResponseWriter, r *http.Request) (jobs.ID, bool) {
~~~


The last change makes `runJob` tell deadline, cancellation and domain errors apart.

`main.go` reads `REQUEST_TIMEOUT` (default `2s`) with a small helper, `durationFromEnv`, and passes `httpapi.WithRequestTimeout(cfg.RequestTimeout)`. The server's `WriteTimeout` becomes the request timeout plus five seconds, so the server never cuts off a response the handler is still allowed to write. Those `main.go` changes follow.



### Step 3: Tests

Make these changes to `internal/httpapi/handler_test.go`:

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	"testing"

~~~

to:

~~~go
	"testing"
	"time"

~~~

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
func newTestHandler() http.Handler {
	return NewHandler(jobs.NewService(memstore.New()))
~~~

to:

~~~go
func newTestHandler(opts ...Option) http.Handler {
	return NewHandler(jobs.NewService(memstore.New()), opts...)
~~~

Add this at the end of the file:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
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




### Step 4: Configure the deadline

Make these changes to `cmd/switchyard/main.go`:

Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	ListenAddr string
~~~

to:

~~~go
	ListenAddr     string
	RequestTimeout time.Duration
~~~

Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
		ListenAddr: "127.0.0.1:8080",
~~~

to:

~~~go
		ListenAddr:     "127.0.0.1:8080",
		RequestTimeout: 2 * time.Second,
~~~

Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	}
	return cfg, nil
}
~~~

to:

~~~go
	}
	var err error
	if cfg.RequestTimeout, err = durationFromEnv(getenv, "REQUEST_TIMEOUT", cfg.RequestTimeout); err != nil {
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
~~~

Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	handler := httpapi.NewHandler(service)
~~~

to:

~~~go
	handler := httpapi.NewHandler(service, httpapi.WithRequestTimeout(cfg.RequestTimeout))
~~~

Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
		WriteTimeout:      15 * time.Second,
~~~

to:

~~~go
		WriteTimeout:      cfg.RequestTimeout + 5*time.Second,
~~~




Make these changes to `cmd/switchyard/main_test.go`:

Change:

<!-- edit: cmd/switchyard/main_test.go -->
~~~go
import "testing"
~~~

to:

~~~go
import (
	"testing"
	"time"
)
~~~

Change:

<!-- edit: cmd/switchyard/main_test.go -->
~~~go
	if err != nil || cfg.ListenAddr != "127.0.0.1:8080" {
~~~

to:

~~~go
	if err != nil || cfg.ListenAddr != "127.0.0.1:8080" || cfg.RequestTimeout != 2*time.Second {
~~~

Change:

<!-- edit: cmd/switchyard/main_test.go -->
~~~go
	cfg, err = loadConfig(env(map[string]string{"LISTEN_ADDR": "0.0.0.0:9000"}))
	if err != nil || cfg.ListenAddr != "0.0.0.0:9000" {
		t.Fatalf("override = %+v, %v", cfg, err)
~~~

to:

~~~go
	cfg, err = loadConfig(env(map[string]string{"LISTEN_ADDR": "0.0.0.0:9000", "REQUEST_TIMEOUT": "500ms"}))
	if err != nil || cfg.ListenAddr != "0.0.0.0:9000" || cfg.RequestTimeout != 500*time.Millisecond {
		t.Fatalf("overrides = %+v, %v", cfg, err)
~~~

Change:

<!-- edit: cmd/switchyard/main_test.go -->
~~~go
	}
}
~~~

to:

~~~go
	}
	for _, bad := range []string{"soon", "-1s", "0s"} {
		if _, err := loadConfig(env(map[string]string{"REQUEST_TIMEOUT": bad})); err == nil {
			t.Errorf("REQUEST_TIMEOUT=%q was accepted", bad)
		}
	}
}
~~~


~~~bash
go test -race ./...
~~~

~~~text
ok  	switchyard/cmd/switchyard	1.024s
ok  	switchyard/drills/byhand	(cached)
ok  	switchyard/drills/escape	(cached) [no tests to run]
?   	switchyard/drills/gc	[no test files]
?   	switchyard/drills/sched	[no test files]
?   	switchyard/drills/spin	[no test files]
?   	switchyard/drills/stacks	[no test files]
?   	switchyard/drills/stdhttp	[no test files]
ok  	switchyard/internal/httpapi	1.101s
ok  	switchyard/internal/jobs	(cached)
ok  	switchyard/internal/memstore	(cached)
~~~

### Step 5: A deadline, then a client that gives up

Start the server with a 1-second deadline, and run a 3-second job:

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && REQUEST_TIMEOUT=1s /tmp/switchyard 2> /dev/null &
sleep 0.5
curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"slow","duration_ms":3000}'
time curl -si -X POST http://127.0.0.1:8080/jobs/1/run
~~~

~~~text
HTTP/1.1 504 Gateway Timeout
Content-Type: application/json
Date: Fri, 20 Nov 2026 04:17:08 GMT
Content-Length: 195

{"id":1,"state":"failed","description":"slow","duration_ms":3000,"failure_reason":"deadline exceeded","created_at":"2026-11-20T04:17:07.794446832Z","updated_at":"2026-11-20T04:17:08.802262195Z"}

real	0m1.010s
user	0m0.000s
sys	0m0.006s
~~~

After one second, `504`, and the job is recorded as `failed` with the reason, thanks to lesson 07's `WithoutCancel`. Now a 1.5-second job (job 2), with a client that gives up after half a second:

~~~bash
curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"slow","duration_ms":1500}'
curl -s --max-time 0.5 -X POST http://127.0.0.1:8080/jobs/2/run; echo "curl exit $?"
sleep 0.2; curl -s http://127.0.0.1:8080/jobs/2; kill %1
~~~

~~~text
curl exit 28
{"id":2,"state":"failed","description":"slow","duration_ms":1500,"failure_reason":"cancelled","created_at":"2026-11-20T04:17:08.816393662Z","updated_at":"2026-11-20T04:17:09.329952562Z"}
~~~

Exit code 28 is `curl`'s "operation timed out". When `curl` hung up, the server noticed the closed connection, cancelled `r.Context()`, the work stopped, and the job was recorded as `failed` with reason `cancelled`. A client-side timeout on its own proves nothing about the server; the stored job is the evidence that the server stopped too.

## Break it

**Work that doesn't listen.** In `Simulate`, replace the `select` with `time.Sleep(job.Duration); return nil`, rebuild, and rerun step 5's first block:

~~~text
HTTP/1.1 200 OK
Content-Type: application/json
Date: Fri, 20 Nov 2026 02:43:41 GMT
Content-Length: 161

{"id":1,"state":"completed","description":"slow","duration_ms":3000,"created_at":"2026-11-20T02:43:38.051381328Z","updated_at":"2026-11-20T02:43:41.060427462Z"}

real	0m3.009s
user	0m0.002s
sys	0m0.005s
~~~

Three full seconds and `200 completed`, with a 1-second deadline. Work that doesn't watch `ctx.Done()` can't be cancelled, whatever deadline sits above it. Put the `select` back.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race ./...
~~~

Then trace a client disconnect from the socket down to `Simulate`. What's the difference between the 504 case and the client-timeout case, from the server's point of view?

*Understanding Distributed Systems* (Vitillo), Part IV, the chapters on downstream resiliency and timeouts. Carry this question in: how do you choose a deadline, and what happens to a caller's caller when you exceed it?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

That proves no request outlives its deadline, and that work stops when its caller leaves. It doesn't tell you what the service is doing while it works: the next lesson adds logs and metrics.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `the cancel function returned by context.WithTimeout should be called` from `go vet` | A `cancel` was dropped | `defer cancel()` right after `WithTimeout` |
| The job stays `running` after a `504` | The final update used the cancelled context | `context.WithoutCancel` (lesson 07) |
| The response is cut off before the handler finishes | `WriteTimeout` shorter than the request timeout | Keep it above the request timeout, as `main` does |
| A `504` takes longer than the deadline | Some work doesn't check the context while it waits | Every wait must `select` on `ctx.Done()` |

