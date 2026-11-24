# 11 Logs, metrics and panic recovery

> Module: Go runtime and reliable services · Time: ~5 h · Builds on: 10

## The problem

When something goes wrong in production, you can't attach a debugger. You need **logs**, which say what happened to individual requests, and **metrics**, which say how the service is doing overall. And a single bug that panics shouldn't drop the connection without a response or a trace.

## The mental model

- A **structured log** is one record per event, as key-value pairs, often JSON. Machines can filter it (`status >= 500`, `route = "POST /jobs/{id}/run"`) without guessing at text. Go's standard `log/slog` writes them.
- **What not to log:** request bodies, descriptions, tokens, names. Logs are copied to many places and kept for a long time, and core 08 treats them as sensitive data. Log the *shape* of a request (method, route, status, duration), not its content.
- A **metric** is a number tracked over time:
  - a **counter** only goes up (requests served);
  - a **histogram** sorts observations into buckets (how many requests took under 5 ms, under 10 ms, ...), so you can compute percentiles later.
- **Labels** split a metric: `route`, `method`, `code`. Use the **route pattern** `GET /jobs/{id}`, never the raw path `/jobs/1`, `/jobs/2`, and so on. Every distinct label value is a separate time series, so raw paths would create millions of them (a **cardinality** explosion).
- These are the **golden signals** from Google's SRE book: **latency, traffic, errors and saturation**. The histogram gives latency, the counter gives traffic, and errors are counts where `code` is 5xx. Saturation arrives with the queue in lesson 13.
- **Prometheus** scrapes `GET /metrics` on a timer and stores the series. The *Kubernetes and delivery* unit runs Prometheus itself; for now you just read the endpoint.
## The pattern

**Observe the shape of every request, never its content, and survive your own bugs.** One log line and one set of metric updates per request, labelled by the route pattern; and a panic in one request becomes a logged `500`, not a dropped connection.

- A **panic** is Go's crash for "impossible" situations. `recover()` inside a deferred function stops it from unwinding further. Recovery middleware turns a panic into a logged 500.

## Build it

### Step 1: Logging, metrics and recovery middleware

Replace `internal/httpapi/middleware.go` with the finished version:

<!-- file: internal/httpapi/middleware.go -->
~~~go
package httpapi

import (
	"context"
	"log/slog"
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

// statusRecorder remembers the status a handler wrote, so middleware can
// log and count it afterwards.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(status int) {
	s.status = status
	s.ResponseWriter.WriteHeader(status)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

// withRequestLog writes one structured record per request. It logs the
// route pattern rather than the raw path, and never logs bodies.
func withRequestLog(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(recorder, r)
		logger.Info("request",
			"method", r.Method,
			"route", routeOf(r),
			"status", recorder.status,
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}

// withRecover turns a panic in any handler into a 500 instead of a dropped
// connection, and logs it.
func withRecover(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				logger.Error("panic", "method", r.Method, "path", r.URL.Path, "panic", v)
				writeError(w, http.StatusInternalServerError, "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// routeOf returns the pattern the router matched, such as "GET /jobs/{id}".
// The router sets r.Pattern on the request it was given, so middleware that
// passed that same request can read it after calling next. Logging the
// pattern instead of the raw path keeps labels few: /jobs/1 and /jobs/2
// are one route. Unmatched requests have no pattern.
func routeOf(r *http.Request) string {
	if r.Pattern == "" {
		return "unmatched"
	}
	return r.Pattern
}
~~~

`statusRecorder` **embeds** `http.ResponseWriter`: it gets all of the writer's methods and overrides two, so it can see the status as it passes through. It's the same embedding trick as `slowGetRepository` in lesson 07.

### Step 2: Metrics with Prometheus

Create `internal/httpapi/metrics.go`:

<!-- file: internal/httpapi/metrics.go -->
~~~go
package httpapi

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics owns its own registry instead of using Prometheus's global one,
// so each test (and each service) gets a clean, independent set.
type Metrics struct {
	registry *prometheus.Registry
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
}

func NewMetrics() *Metrics {
	m := &Metrics{
		registry: prometheus.NewRegistry(),
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "HTTP requests by route, method and status code.",
		}, []string{"route", "method", "code"}),
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency by route and method.",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
		}, []string{"route", "method"}),
	}
	m.registry.MustRegister(m.requests, m.duration)
	return m
}

// Handler serves the metrics in Prometheus's text format.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{})
}

func (m *Metrics) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(recorder, r)

		route := routeOf(r)
		m.requests.WithLabelValues(route, r.Method, strconv.Itoa(recorder.status)).Inc()
		m.duration.WithLabelValues(route, r.Method).Observe(time.Since(start).Seconds())
	})
}
~~~

This is the first third-party dependency, and adding it takes two commands:

~~~bash
go get github.com/prometheus/client_golang@v1.24.1
go mod tidy
~~~

`go get` pins the version: it writes `require github.com/prometheus/client_golang v1.24.1` into `go.mod`. It doesn't fetch everything that library needs in turn, so a build straight after it fails with `missing go.sum entry`. `go mod tidy` reads your imports, downloads every package they pull in, and writes their checksums into `go.sum`. Commit both files: they make the build reproducible. (`@latest` would also work, but it gives a different version as time passes; naming the version makes this guide give everyone the same result.)

<!-- run: go get github.com/prometheus/client_golang@v1.24.1 && go mod tidy -->

### Step 3: Wrap the router, in order

`NewHandler` gains `WithLogger` and `WithMetrics` options, and wraps the router in a fixed order.

Make these changes to `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	jobs JobService
~~~

to:

~~~go
	jobs   JobService
	logger *slog.Logger
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
type config struct {
	requestTimeout time.Duration
~~~

to:

~~~go
type config struct {
	logger         *slog.Logger
	metrics        *Metrics
	requestTimeout time.Duration
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go

// WithRequestTimeout bounds how long any one request may run.
~~~

to:

~~~go

func WithLogger(logger *slog.Logger) Option {
	return func(c *config) { c.logger = logger }
}

func WithMetrics(metrics *Metrics) Option {
	return func(c *config) { c.metrics = metrics }
}

// WithRequestTimeout bounds how long any one request may run.
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
// NewHandler builds the routes and gives every request a deadline.
~~~

to:

~~~go
// NewHandler builds the routes and wraps them in middleware. The outermost
// middleware runs first on the way in and last on the way out.
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	cfg := config{requestTimeout: 2 * time.Second}
~~~

to:

~~~go
	cfg := config{
		logger:         slog.New(slog.DiscardHandler),
		requestTimeout: 2 * time.Second,
	}
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	h := &handlers{jobs: service}
~~~

to:

~~~go
	h := &handlers{jobs: service, logger: cfg.logger}
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	return withTimeout(cfg.requestTimeout, mux)
~~~

to:

~~~go
	if cfg.metrics != nil {
		mux.Handle("GET /metrics", cfg.metrics.Handler())
	}

	// Logging and metrics must receive the same *http.Request the router
	// does, so they can read the route it matched (r.Pattern). withTimeout
	// makes a copy of the request with r.WithContext, so it goes outside them.
	var handler http.Handler = mux
	if cfg.metrics != nil {
		handler = cfg.metrics.instrument(handler)
	}
	handler = withRequestLog(cfg.logger, handler)
	handler = withTimeout(cfg.requestTimeout, handler)
	handler = withRecover(cfg.logger, handler)
	return handler
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
		// The client hung up. There is nobody left to answer.
~~~

to:

~~~go
		h.logger.Info("client went away during run", "job_id", id)
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
		slog.Error("unexpected error", "method", r.Method, "path", r.URL.Path, "error", err)
~~~

to:

~~~go
		h.logger.Error("unexpected error", "method", r.Method, "path", r.URL.Path, "error", err)
~~~


Wrapping happens inside-out, so the request passes through **recover → timeout → log → metrics → router** on the way in, and back out in reverse:

~~~mermaid
flowchart LR
    REQ[request] --> RC[withRecover] --> TO[withTimeout] --> LG[withRequestLog] --> MT[metrics] --> MUX[router + handler]
~~~

`main.go` now builds a JSON logger, `slog.New(slog.NewJSONHandler(stdout, nil))`, and passes it plus `httpapi.NewMetrics()` to `NewHandler`. Those `main.go` changes follow.



### Step 4: Tests

Make these changes to `internal/httpapi/handler_test.go`:

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
import (
	"encoding/json"
	"io"
	"net/http"
~~~

to:

~~~go
import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
~~~

Add this at the end of the file:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
func TestRequestLogUsesRoutePattern(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&logs, nil))
	h := newTestHandler(WithLogger(logger))

	do(t, h, http.MethodGet, "/jobs/42", "")

	var record map[string]any
	if err := json.Unmarshal(logs.Bytes(), &record); err != nil {
		t.Fatalf("log line %q: %v", logs.String(), err)
	}
	if record["route"] != "GET /jobs/{id}" || record["status"] != float64(404) {
		t.Fatalf("log record = %v", record)
	}
}

func TestMetricsCountRequests(t *testing.T) {
	h := newTestHandler(WithMetrics(NewMetrics()))
	do(t, h, http.MethodGet, "/health", "")
	do(t, h, http.MethodGet, "/health", "")

	body := do(t, h, http.MethodGet, "/metrics", "").Body.String()
	want := `http_requests_total{code="200",method="GET",route="GET /health"} 2`
	if !strings.Contains(body, want) {
		t.Fatalf("metrics missing %q:\n%s", want, body)
	}
}

type panickingService struct{ JobService }

func (panickingService) Get(context.Context, jobs.ID) (jobs.Job, error) { panic("boom") }

func TestPanicBecomes500(t *testing.T) {
	h := NewHandler(panickingService{}, WithLogger(slog.New(slog.NewTextHandler(io.Discard, nil))))
	response := do(t, h, http.MethodGet, "/jobs/1", "")
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", response.Code)
	}
}
~~~




### Step 5: A JSON logger in `main`

Make these changes to `cmd/switchyard/main.go`:

Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	"log"
~~~

to:

~~~go
	"io"
	"log/slog"
~~~

Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	if err := run(os.Getenv); err != nil {
~~~

to:

~~~go
	if err := run(os.Getenv, os.Stdout); err != nil {
~~~

Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
// run builds the service from its configuration and serves it. Taking the
// environment as a parameter instead of calling os.Getenv inside is what
// makes it testable.
func run(getenv func(string) string) error {
~~~

to:

~~~go
// run builds the service from its configuration and serves it. It takes
// its environment and output as parameters so tests can supply their own.
func run(getenv func(string) string, stdout io.Writer) error {
~~~

Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
		return err
	}

	service := jobs.NewService(memstore.New())
	handler := httpapi.NewHandler(service, httpapi.WithRequestTimeout(cfg.RequestTimeout))
~~~

to:

~~~go
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	service := jobs.NewService(memstore.New())
	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(httpapi.NewMetrics()),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
	)
~~~

Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	log.Printf("listening on http://%s", cfg.ListenAddr)
~~~

to:

~~~go
	logger.Info("listening", "addr", cfg.ListenAddr)
~~~


~~~bash
go test -race ./...
~~~

~~~text
ok  	switchyard/cmd/switchyard	1.033s
ok  	switchyard/drills/byhand	1.024s
ok  	switchyard/drills/escape	1.021s [no tests to run]
?   	switchyard/drills/gc	[no test files]
?   	switchyard/drills/sched	[no test files]
?   	switchyard/drills/spin	[no test files]
?   	switchyard/drills/stacks	[no test files]
?   	switchyard/drills/stdhttp	[no test files]
ok  	switchyard/internal/httpapi	1.145s
ok  	switchyard/internal/jobs	1.065s
ok  	switchyard/internal/memstore	1.027s
~~~

### Step 6: Read the logs and metrics

Start it with a 1-second deadline, its log in a file, and make one request of each kind:

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && REQUEST_TIMEOUT=1s /tmp/switchyard > /tmp/switchyard.log &
sleep 0.5; U=http://127.0.0.1:8080; J='Content-Type: application/json'
curl -s -o /dev/null -X POST $U/jobs -H "$J" -d '{"description":"quick","duration_ms":300}'
curl -s -o /dev/null -X POST $U/jobs -H "$J" -d '{"description":"slow","duration_ms":3000}'
curl -s -o /dev/null $U/jobs/1; curl -s -o /dev/null $U/jobs/abc; curl -s -o /dev/null $U/jobs/99
curl -s -o /dev/null -X POST $U/jobs/1/run; curl -s -o /dev/null -X POST $U/jobs/1/run
curl -s -o /dev/null -X POST $U/jobs/2/run
curl -s $U/metrics | grep '^http_requests_total'
~~~

~~~text
http_requests_total{code="200",method="GET",route="GET /jobs/{id}"} 1
http_requests_total{code="200",method="POST",route="POST /jobs/{id}/run"} 1
http_requests_total{code="201",method="POST",route="POST /jobs"} 2
http_requests_total{code="400",method="GET",route="GET /jobs/{id}"} 1
http_requests_total{code="404",method="GET",route="GET /jobs/{id}"} 1
http_requests_total{code="409",method="POST",route="POST /jobs/{id}/run"} 1
http_requests_total{code="504",method="POST",route="POST /jobs/{id}/run"} 1
~~~

One time series per route pattern, method and status, never per job ID. And the log, one JSON line per request:

~~~bash
grep '"msg":"request"' /tmp/switchyard.log | tail -3; kill %1
~~~

~~~text
{"time":"2026-11-20T04:14:27.379355732Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/run","status":409,"duration_ms":0}
{"time":"2026-11-20T04:14:28.387857119Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/run","status":504,"duration_ms":1000}
{"time":"2026-11-20T04:14:28.401660831Z","level":"INFO","msg":"request","method":"GET","route":"GET /metrics","status":200,"duration_ms":0}
~~~

Read the `504` line: its `duration_ms` is `1000`, the deadline, not the job's 3 seconds. That's the kind of evidence you'll use in incidents.

## Break it

**Middleware order.** Move `withTimeout` *inside* the logger: put `handler = withTimeout(...)` straight after `var handler http.Handler = mux`. Then run `go test ./internal/httpapi`:

~~~text
--- FAIL: TestRequestLogUsesRoutePattern (0.00s)
    handler_test.go:245: log record = map[duration_ms:0 level:INFO method:GET msg:request route:unmatched status:404 time:2026-11-20T04:14:33.195710974Z]
--- FAIL: TestMetricsCountRequests (0.00s)
    handler_test.go:257: metrics missing "http_requests_total{code=\"200\",method=\"GET\",route=\"GET /health\"} 2":
        # HELP http_request_duration_seconds HTTP request latency by route and method.
        # TYPE http_request_duration_seconds histogram
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="0.005"} 2
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="0.01"} 2
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="0.025"} 2
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="0.05"} 2
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="0.1"} 2
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="0.25"} 2
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="0.5"} 2
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="1"} 2
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="2.5"} 2
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="5"} 2
        http_request_duration_seconds_bucket{method="GET",route="unmatched",le="+Inf"} 2
        http_request_duration_seconds_sum{method="GET",route="unmatched"} 8.7757e-05
        http_request_duration_seconds_count{method="GET",route="unmatched"} 2
        # HELP http_requests_total HTTP requests by route, method and status code.
        # TYPE http_requests_total counter
        http_requests_total{code="200",method="GET",route="unmatched"} 2
FAIL
FAIL	switchyard/internal/httpapi	0.087s
FAIL
~~~

Every route became `unmatched`. `r.WithContext` returns a **copy** of the request. The router wrote `Pattern` onto the copy, and the logger was still holding the original. Order isn't style: it changes behaviour. Restore it.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race ./...
~~~

Then answer: why log the route pattern rather than the path? Name the four golden signals and which metric gives each one.

*Site Reliability Engineering* (free at sre.google), Ch. 6, *Monitoring Distributed Systems*. Carry this question in: which of your metrics would page someone at 3 a.m., and which are just for dashboards?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

That proves every request leaves a record and a count, and a panic leaves a `500` and a stack trace instead of a dead connection. It doesn't make stopping the service safe: the next lesson does.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `missing go.sum entry for module providing package github.com/prometheus/...` | `go get` pinned the version but the packages it needs weren't downloaded | `go mod tidy` |
| `duplicate metrics collector registration attempted` | `NewMetrics` registered twice in one registry | Make one per handler, as `NewMetrics` does with its own registry |
| Every route is `unmatched` | Middleware that copies the request runs before the logger | Keep the order: recover, timeout, log, metrics, router |
| `/metrics` grows by thousands of series | A raw path or an ID used as a label | Label with `r.Pattern`, never `r.URL.Path` |
| A panic kills the whole program | It happened in a goroutine the handler started, not the handler | `recover` only catches panics in its own goroutine |

