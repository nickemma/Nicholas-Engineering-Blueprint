# 12 Signals and graceful shutdown

> Module: Go runtime and reliable services · Time: ~4 h · Builds on: 11, and Foundations 02 lesson 04

## The problem

Deploying a new version means stopping the old process. If it dies instantly, every request in flight gets a broken connection: a user's job may have run, but they never hear back. A reliable service stops **gracefully**: it stops accepting new work, finishes what it started, and then exits.

## The mental model

- **Signals** (Foundations 02 lesson 04): Ctrl+C sends **SIGINT**; `kill PID` and Kubernetes send **SIGTERM**; **SIGKILL** (`kill -9`) can't be caught, and the process just vanishes. So graceful shutdown can only ever handle SIGINT and SIGTERM.
- `signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)` returns a context that is cancelled when either signal arrives. Shutdown becomes "wait for `ctx.Done()`", the same idea you've used all module.
- `server.Shutdown(ctx)`:
  1. closes the listening socket, so new connections are refused;
  2. closes idle connections;
  3. waits for active requests to finish, or until `ctx` expires.

  `server.Close()` drops everything immediately.
- A **grace period** bounds the wait. Kubernetes gives a pod 30 seconds by default between SIGTERM and SIGKILL, so the grace must be shorter than that.
## The pattern

**Stop taking work, finish what you started, then exit, within a bound.** Shutdown is just another context being cancelled; the grace period is just another deadline.

- `run` now takes a `context.Context` and a `ready` callback, and listens with `net.Listen` first. That's so a test can listen on port `0` (meaning "any free port") and learn which port it got.

## Build it

### Step 1: `run` waits for a signal

Replace `cmd/switchyard/main.go` with the finished version:

<!-- file: cmd/switchyard/main.go -->
~~~go
// Command switchyard runs Switchyard's control plane.
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
	"syscall"
	"time"

	"switchyard/internal/httpapi"
	"switchyard/internal/jobs"
	"switchyard/internal/memstore"
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
}

func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{
		ListenAddr:     "127.0.0.1:8080",
		RequestTimeout: 2 * time.Second,
		ShutdownGrace:  10 * time.Second,
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

// run starts the server and blocks until ctx is cancelled, then shuts down
// gracefully. Taking its environment, output and context as parameters
// instead of reading globals is what makes it testable.
func run(ctx context.Context, getenv func(string) string, stdout io.Writer, ready func(addr string)) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	service := jobs.NewService(memstore.New())
	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(httpapi.NewMetrics()),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
	)

	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      cfg.RequestTimeout + 5*time.Second,
		IdleTimeout:       60 * time.Second,
	}

	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}
	logger.Info("listening", "addr", listener.Addr().String())
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

	// Stop accepting new connections, then wait for in-flight requests to
	// finish, but never longer than the grace period.
	logger.Info("shutting down", "grace", cfg.ShutdownGrace.String())
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	logger.Info("stopped")
	return nil
}
~~~

How it fits together:

~~~mermaid
sequenceDiagram
    participant OS
    participant Main as run()
    participant Srv as http.Server
    participant H as in-flight handler
    Main->>Srv: Serve(listener) in a goroutine
    OS->>Main: SIGTERM → ctx.Done()
    Main->>Srv: Shutdown(10s grace)
    Srv->>Srv: close listener: new connections refused
    H-->>Srv: finishes and writes its response
    Srv-->>Main: Shutdown returns
    Main->>Main: log "stopped", return nil, exit 0
~~~

- `server.Serve` runs in its own goroutine and sends its result on `serveErr`, so `run` can wait for *either* a serve error *or* a shutdown signal with `select`.
- The shutdown context is built from `context.Background()`, not from `ctx`. `ctx` is already cancelled at this point, and a grace period derived from it would be zero.
- After `Shutdown`, `Serve` returns `http.ErrServerClosed`. That's the normal case, not an error.

### Step 2: A test that stops the server mid-request

The test that proves it, in `cmd/switchyard/main_test.go` below, starts the server on a free port, begins a 300 ms run, cancels the context 100 ms in, and checks three things:

- the in-flight request still gets `200` with `completed`;
- `run` returns `nil`;
- a new request afterwards is refused.


Replace `cmd/switchyard/main_test.go`:

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
	if err != nil || cfg.ListenAddr != "127.0.0.1:8080" || cfg.RequestTimeout != 2*time.Second {
		t.Fatalf("defaults = %+v, %v", cfg, err)
	}

	cfg, err = loadConfig(env(map[string]string{"LISTEN_ADDR": "0.0.0.0:9000", "REQUEST_TIMEOUT": "500ms"}))
	if err != nil || cfg.ListenAddr != "0.0.0.0:9000" || cfg.RequestTimeout != 500*time.Millisecond {
		t.Fatalf("overrides = %+v, %v", cfg, err)
	}

	if _, err := loadConfig(env(map[string]string{"LISTEN_ADDR": "8080"})); err == nil {
		t.Error("LISTEN_ADDR without a host:port form was accepted")
	}
	for _, bad := range []string{"soon", "-1s", "0s"} {
		if _, err := loadConfig(env(map[string]string{"SHUTDOWN_GRACE": bad})); err == nil {
			t.Errorf("SHUTDOWN_GRACE=%q was accepted", bad)
		}
	}
}

// syncBuffer lets the server goroutine write logs while the test reads them.
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

func TestGracefulShutdownFinishesInFlightRequest(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	addrCh := make(chan string, 1)
	runErr := make(chan error, 1)
	var logs syncBuffer
	go func() {
		runErr <- run(ctx, env(map[string]string{"LISTEN_ADDR": "127.0.0.1:0"}), &logs, func(addr string) { addrCh <- addr })
	}()
	base := "http://" + <-addrCh

	create, err := http.Post(base+"/jobs", "application/json", strings.NewReader(`{"description":"slow","duration_ms":300}`))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	create.Body.Close()

	// Start a 300ms run, then ask the server to stop while it is in flight.
	type result struct {
		status int
		state  string
		err    error
	}
	inFlight := make(chan result, 1)
	go func() {
		resp, err := http.Post(base+"/jobs/1/run", "application/json", nil)
		if err != nil {
			inFlight <- result{err: err}
			return
		}
		defer resp.Body.Close()
		var body struct{ State string }
		_ = json.NewDecoder(resp.Body).Decode(&body)
		inFlight <- result{status: resp.StatusCode, state: body.State}
	}()
	time.Sleep(100 * time.Millisecond)
	cancel()

	got := <-inFlight
	if got.err != nil || got.status != http.StatusOK || got.state != "completed" {
		t.Fatalf("in-flight request: status=%d state=%q err=%v; graceful shutdown should let it finish", got.status, got.state, got.err)
	}
	if err := <-runErr; err != nil {
		t.Fatalf("run returned %v", err)
	}

	if _, err := http.Get(base + "/health"); err == nil {
		t.Fatal("server still accepted a request after shutdown")
	}
	for _, msg := range []string{`"msg":"shutting down"`, `"msg":"stopped"`} {
		if !strings.Contains(logs.String(), msg) {
			t.Errorf("logs missing %s:\n%s", msg, logs.String())
		}
	}
}

func TestRunFailsOnBadConfig(t *testing.T) {
	err := run(context.Background(), env(map[string]string{"REQUEST_TIMEOUT": "fast"}), io.Discard, nil)
	if err == nil || !strings.Contains(err.Error(), "REQUEST_TIMEOUT") {
		t.Fatalf("error = %v, want a REQUEST_TIMEOUT config error", err)
	}
}
~~~

~~~bash
go test -race ./...
~~~

~~~text
ok  	switchyard/cmd/switchyard	1.421s
ok  	switchyard/drills/byhand	(cached)
ok  	switchyard/drills/escape	(cached) [no tests to run]
?   	switchyard/drills/gc	[no test files]
?   	switchyard/drills/sched	[no test files]
?   	switchyard/drills/spin	[no test files]
?   	switchyard/drills/stacks	[no test files]
?   	switchyard/drills/stdhttp	[no test files]
ok  	switchyard/internal/httpapi	(cached)
ok  	switchyard/internal/jobs	(cached)
ok  	switchyard/internal/memstore	(cached)
~~~

### Step 3: SIGTERM in the middle of a request

Start a 1.5-second job, and send the server SIGTERM 0.3 seconds into it:

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && /tmp/switchyard > /tmp/switchyard.log & p=$!
sleep 0.5
curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"slow","duration_ms":1500}'
curl -s -X POST http://127.0.0.1:8080/jobs/1/run & sleep 0.3; kill -TERM $p; wait
echo; cat /tmp/switchyard.log
~~~

~~~text
{"id":1,"state":"completed","description":"slow","duration_ms":1500,"created_at":"2026-11-20T04:14:38.228680602Z","updated_at":"2026-11-20T04:14:39.741943533Z"}

{"time":"2026-11-20T04:14:37.728522497Z","level":"INFO","msg":"listening","addr":"127.0.0.1:8080"}
{"time":"2026-11-20T04:14:38.228872326Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs","status":201,"duration_ms":0}
{"time":"2026-11-20T04:14:38.534385936Z","level":"INFO","msg":"shutting down","grace":"10s"}
{"time":"2026-11-20T04:14:39.742261296Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/run","status":200,"duration_ms":1500}
{"time":"2026-11-20T04:14:40.103927832Z","level":"INFO","msg":"stopped"}
~~~

The request that was running when SIGTERM arrived still got its answer, `completed`, and then the server stopped.

### Step 4: What the process holds

While it runs, look at it the way Foundations 02 taught you:

~~~bash
/tmp/switchyard > /tmp/switchyard.log & p=$!; sleep 0.5
ps -o pid,stat,nlwp,comm -p $p
ls -l /proc/$p/fd | awk 'NR > 1 {print $9, $10, $11}'
grep 'open files' /proc/$p/limits
~~~

~~~text
    PID STAT NLWP COMMAND
  11612 Sl      8 switchyard
0 -> /dev/null
1 -> /tmp/switchyard.log
2 -> /cap/1203-proc.txt
3 -> /sys/fs/cgroup/cpu.max
4 -> socket:[3448848]
5 -> anon_inode:[eventpoll]
6 -> anon_inode:[eventfd]
Max open files            1048575              1048576              files     
~~~

- `nlwp` is the number of threads: a few, for the Go runtime.
- Descriptors 0, 1 and 2 are standard input, output and error; one `socket` is the listener; `eventpoll` is how Go waits on many sockets at once (the "netpoller", core 06). Each client connection adds a socket.
- Descriptor 3, `/sys/fs/cgroup/cpu.max`, is the CPU limit of the process's control group. The Go runtime keeps it open and rereads it, so `GOMAXPROCS` follows the limit if a container's CPU quota changes. You'll see it on any Linux with cgroup v2, container or not.
- `open files` is the per-process descriptor limit: the ceiling a connection leak eventually hits. Compare it with your shell's `ulimit -n` (often `1024`): the Go runtime raises its own soft limit to (almost) the hard limit when it starts, so a Go server can hold far more connections than `ulimit -n` suggests. Most other programs started from that shell, `cat /proc/self/limits` for one, keep the shell's limit.

Two hundred requests at once, using only the shell:

~~~bash
seq 1 200 | xargs -P 20 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"burst"}' \
  | sort | uniq -c
curl -s -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"one more"}'; echo
kill $p
~~~

~~~text
    200 201
{"id":201,"state":"queued","description":"one more","duration_ms":0,"created_at":"2026-11-20T04:14:42.009219728Z","updated_at":"2026-11-20T04:14:42.009219728Z"}
~~~

`xargs -P 20` runs 20 `curl`s at a time; `sort | uniq -c` counts the status codes. All 200 created, and the next job is number 201: no ID was lost or repeated. Core 02 builds a load generator that measures latency too.

## Break it

**Close instead of Shutdown.** Replace the `Shutdown` call with `server.Close()` and delete the two `shutdownCtx` lines above it. Run `go test ./cmd/switchyard`:

~~~text
--- FAIL: TestGracefulShutdownFinishesInFlightRequest (0.11s)
    main_test.go:99: in-flight request: status=0 state="" err=Post "http://127.0.0.1:35365/jobs/1/run": EOF; graceful shutdown should let it finish
FAIL
FAIL	switchyard/cmd/switchyard	0.122s
FAIL
~~~

`EOF`: the connection was cut mid-request. The job ran on the server, but the client never found out, and might retry it. Restore `Shutdown`.

**Graceful shutdown doesn't mean "never lose work".** If the grace period expires, remaining requests are cut off. If the process gets SIGKILL or the machine loses power, nothing graceful happens at all. And the jobs in memory are lost on every exit; core 03 moves them into a database. What happens to a job whose worker vanishes is lesson 16's subject.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race ./...
~~~

Then answer: what's the difference between SIGINT, SIGTERM and SIGKILL, and which can a program handle? Why is the shutdown context built from `context.Background()`?

Read CSAPP §8.1–8.2 and §8.4–8.5 (processes and signals), and OSTEP Ch. 5 (*Process API*). Carry this question in: what exactly happens, step by step, between pressing Ctrl+C and your `select` waking up?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

That proves an ordinary stop loses nothing in flight. The service still does all of a job's work inside the request that asked for it: the next lesson separates accepting work from doing it.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| The server exits at once on Ctrl+C, cutting requests | `signal.NotifyContext` not used, or its context not passed to `run` | Build `ctx` from `NotifyContext` in `main` |
| Shutdown waits the whole grace period | A request or a background goroutine never finishes | Find it: every long wait must watch a context |
| `http: Server closed` reported as an error | `http.ErrServerClosed` treated as a failure | It's the normal result of `Shutdown` |
| The shutdown grace is zero | The shutdown context was derived from the cancelled `ctx` | Build it from `context.Background()` |
| `ls: cannot access '/proc/...'` on macOS | No `/proc` | `lsof -p PID` |

