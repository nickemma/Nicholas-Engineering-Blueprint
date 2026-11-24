# 15 gRPC and Protocol Buffers

> Module: Go runtime and reliable services · Time: ~5 h · Builds on: 14

## The problem

HTTP with JSON is easy to read and works everywhere, but the contract lives only in your documentation and your tests. Nothing stops a client sending `"duration_ms": "fast"`. Between your own services, teams often prefer a contract that's **written down as code**, checked by a compiler on both sides, and sent in a compact binary form. That's **gRPC**. In lesson 16, Switchyard's workers move into processes of their own and talk to it over gRPC; this lesson builds the first gRPC API they'll stand next to.

## The mental model

~~~text
                    ┌── HTTP + JSON  :8080 ── httpapi ──┐
 curl, browsers ────┘                                   ├── jobs.Service ── memstore, queue, workers
 jobsctl, services ─── gRPC + protobuf :9090 ── grpcapi ┘
                         ▲
                  jobs.proto: the contract, compiled into Go for both the server and the client
~~~

- **Protocol Buffers** (protobuf) is a language for describing messages and services, plus a compact binary encoding for them. You write a `.proto` file; the **protoc** compiler generates Go code (or Java, Python, and so on) for both server and client.
- Each field has a **field number** (`string description = 1;`). The binary format sends the numbers, not the names. So you can rename a field freely, but **never reuse or change a number**. That's how protobuf stays compatible as it evolves, with clients you can't update all at once.
- **gRPC** runs remote procedure calls over HTTP/2: the client calls `CreateJob(ctx, req)` as if it were a local method. Deadlines travel with the call: a client's context timeout reaches the server as a `grpc-timeout` header, and the server's `ctx` gets the same deadline.
- gRPC errors use **status codes** (`InvalidArgument`, `NotFound`, `Unavailable`, ...) instead of HTTP statuses. The mapping is a design decision, just as lesson 08's mapping to HTTP statuses was.
- **When to use which.** Use JSON over HTTP for public APIs, browsers and humans with curl. Use gRPC for service-to-service calls, especially between teams and languages.

## The pattern

**Same use cases, two adapters.** `grpcapi` is to gRPC what `httpapi` is to HTTP: it translates, and holds no rules. Because lessons 05–08 kept the rules in `jobs.Service`, adding a second protocol doesn't change it at all.

## Build it

### Step 1: Install the tools

Install the protobuf compiler once: `sudo apt install protobuf-compiler` on Debian or Ubuntu (including WSL), or `brew install protobuf` on macOS. `protoc --version` should print `libprotoc 3.21` or newer.

The two Go code generators are Go programs. Install them into your `switchyard` folder's `bin/`, pinned to exact versions, so everyone generates identical code:

<!-- run: GOBIN=$PWD/bin go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12 && GOBIN=$PWD/bin go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2 -->
~~~bash
GOBIN=$PWD/bin go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12
GOBIN=$PWD/bin go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2
~~~

`GOBIN` tells `go install` where to put the programs it builds. They come from two different modules, so they need two commands.

`bin/` holds programs, not source, so keep it out of your repository. Create `.gitignore`:

<!-- file: .gitignore -->
~~~text
# Tools installed into this folder (lesson 15). Rebuilt from pinned versions,
# never committed.
/bin/
~~~

### Step 2: The contract

Create `proto/switchyard/jobs/v1/jobs.proto`:

<!-- file: proto/switchyard/jobs/v1/jobs.proto -->
~~~protobuf
syntax = "proto3";

package switchyard.jobs.v1;

option go_package = "switchyard/internal/grpcapi/jobsv1";

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

<!-- run: PATH=$PWD/bin:$PATH protoc --go_out=. --go_opt=module=switchyard --go-grpc_out=. --go-grpc_opt=module=switchyard proto/switchyard/jobs/v1/jobs.proto -->
~~~bash
PATH=$PWD/bin:$PATH protoc --go_out=. --go_opt=module=switchyard \
  --go-grpc_out=. --go-grpc_opt=module=switchyard proto/switchyard/jobs/v1/jobs.proto
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

### Step 3: The server adapter

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

	"switchyard/internal/grpcapi/jobsv1"
	"switchyard/internal/jobs"
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

	"switchyard/internal/grpcapi/jobsv1"
	"switchyard/internal/jobs"
	"switchyard/internal/memstore"
)

// client starts a real gRPC server, backed by an in-memory jobs service, on
// an in-memory connection and returns a client for it.
func client(t *testing.T) jobsv1.JobsClient {
	t.Helper()
	return clientFor(t, jobs.NewService(memstore.New()))
}

// clientFor does the same for any JobService, such as a test's fake.
func clientFor(t *testing.T, service JobService) jobsv1.JobsClient {
	t.Helper()
	listener := bufconn.Listen(1 << 20)
	server := grpc.NewServer()
	jobsv1.RegisterJobsServer(server, New(service))
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

A deadline set by the client must reach the server, or the server keeps working for a caller that has given up (lesson 10). Prove it travels. Add at the end of `internal/grpcapi/server_test.go`:

<!-- append: internal/grpcapi/server_test.go -->
~~~go
// waitingService never answers: it reports the deadline its caller gave it,
// then waits until that caller's context ends.
type waitingService struct{ left chan time.Duration }

func (w waitingService) Create(ctx context.Context, _ string, _ time.Duration) (jobs.Job, error) {
	deadline, _ := ctx.Deadline() // the zero time if there is none
	w.left <- time.Until(deadline)
	<-ctx.Done()
	return jobs.Job{}, ctx.Err()
}

func (w waitingService) Get(context.Context, jobs.ID) (jobs.Job, error) {
	return jobs.Job{}, jobs.ErrNotFound
}

func TestTheDeadlineTravelsWithTheCall(t *testing.T) {
	svc := waitingService{left: make(chan time.Duration, 1)}
	c := clientFor(t, svc)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := c.CreateJob(ctx, &jobsv1.CreateJobRequest{Description: "slow"})
	if status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("code = %v, want DeadlineExceeded", status.Code(err))
	}
	if took := time.Since(start); took > time.Second {
		t.Fatalf("the call took %v; the 200 ms deadline should have ended it", took)
	}
	if left := <-svc.left; left <= 0 || left > 200*time.Millisecond {
		t.Fatalf("the server had %v left; want a deadline inside the client's 200 ms", left)
	}
}
~~~

`waitingService` is a fake `JobService` that never answers. The client gives the call 200 ms; gRPC sends that as a `grpc-timeout` header, and the server's `ctx` gets a deadline of its own. The test checks both sides: the client gets `DeadlineExceeded` on time, and the server *saw* a deadline inside the client's 200 ms.

<!-- run: go mod tidy && go vet ./internal/grpcapi/... && go test -race ./internal/grpcapi/... -->

### Step 4: Serve gRPC next to HTTP

`main` serves both protocols from the same service. In `cmd/switchyard/main.go`, add the address. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
type config struct {
	ListenAddr     string

~~~

to:

~~~go
type config struct {
	ListenAddr     string
	GRPCAddr       string

~~~

Give it a default. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
		ListenAddr:     "127.0.0.1:8080",

~~~

to:

~~~go
		ListenAddr:     "127.0.0.1:8080",
		GRPCAddr:       "127.0.0.1:9090",

~~~

Two addresses need the same check, so the `LISTEN_ADDR` code from lesson 09 becomes a helper, the twin of `durationFromEnv`. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	if v := getenv("LISTEN_ADDR"); v != "" {
		if _, _, err := net.SplitHostPort(v); err != nil {
			return config{}, fmt.Errorf("LISTEN_ADDR must look like host:port, got %q", v)
		}
		cfg.ListenAddr = v
	}
	var err error

~~~

to:

~~~go
	var err error
	if cfg.ListenAddr, err = hostPortFromEnv(getenv, "LISTEN_ADDR", cfg.ListenAddr); err != nil {
		return config{}, err
	}
	if cfg.GRPCAddr, err = hostPortFromEnv(getenv, "GRPC_ADDR", cfg.GRPCAddr); err != nil {
		return config{}, err
	}

~~~

and add the helper above `durationFromEnv`. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
func durationFromEnv(
~~~

to:

~~~go
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

func durationFromEnv(
~~~

Start the gRPC server once the HTTP listener is up. **Reflection** lets tools such as `grpcurl` ask the server what it offers. Change:

<!-- edit: cmd/switchyard/main.go -->
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

Stop it gracefully alongside HTTP: after HTTP stops accepting requests, and before the workers are told to stop. `GracefulStop` waits for calls in progress, so give it until the grace period ends, then force it. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	// 2. Let workers finish the jobs they hold, until the grace period ends.

~~~

to:

~~~go
	// gRPC creates jobs too: stop it the same way, waiting for calls in
	// progress until the grace period ends, then forcing it.
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

	// 2. Let workers finish the jobs they hold, until the grace period ends.

~~~

and add the imports. Change:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	"github.com/prometheus/client_golang/prometheus"

	"switchyard/internal/chaos"

~~~

to:

~~~go
	"github.com/prometheus/client_golang/prometheus"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"

	"switchyard/internal/chaos"

~~~

and:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	"switchyard/internal/chaos"
	"switchyard/internal/httpapi"

~~~

to:

~~~go
	"switchyard/internal/chaos"
	"switchyard/internal/grpcapi"
	"switchyard/internal/grpcapi/jobsv1"
	"switchyard/internal/httpapi"

~~~

The `main` tests start the service on a random HTTP port; the gRPC port must be random too, or tests running together would collide on 9090. In `cmd/switchyard/main_test.go`, change:

<!-- edit: cmd/switchyard/main_test.go -->
~~~go
	vars := map[string]string{"LISTEN_ADDR": "127.0.0.1:0"}
~~~

to:

~~~go
	vars := map[string]string{"LISTEN_ADDR": "127.0.0.1:0", "GRPC_ADDR": "127.0.0.1:0"}
~~~

### Step 5: A small gRPC client

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

	"switchyard/internal/grpcapi/jobsv1"
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

### Step 6: One service, two front doors

Start Switchyard. Its log now has a second listener:

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && /tmp/switchyard > /tmp/switchyard.log &
sleep 0.5
grep 'grpc listening' /tmp/switchyard.log
~~~

~~~text
{"time":"2026-11-20T04:52:37.059517879Z","level":"INFO","msg":"grpc listening","addr":"127.0.0.1:9090"}
~~~

Build the client, and use it:

~~~bash
go build -o /tmp/jobsctl ./cmd/jobsctl
/tmp/jobsctl create "resize images" 300
sleep 0.5; /tmp/jobsctl get 1
/tmp/jobsctl get 99; echo "exit $?"
/tmp/jobsctl create ""; echo "exit $?"
curl -s http://127.0.0.1:8080/jobs/1
~~~

~~~text
job 1: STATE_QUEUED "resize images" (300 ms)
job 1: STATE_COMPLETED "resize images" (300 ms)
jobsctl: NotFound: job not found
exit 1
jobsctl: InvalidArgument: description must be between 1 and 200 characters
exit 1
{"id":1,"state":"completed","description":"resize images","duration_ms":300,"created_at":"2026-11-20T04:52:38.42592189Z","updated_at":"2026-11-20T04:52:38.726509901Z"}
~~~

Job 1 was created over gRPC, a worker completed it, and `curl` reads the same job over HTTP: one service, two front doors. The errors arrive as status codes, and `jobsctl` exits with status 1. If you have [grpcurl](https://github.com/fullstorydev/grpcurl) installed, reflection lets it explore the API with no `.proto` file: `grpcurl -plaintext 127.0.0.1:9090 list`.

Run the size test with `-v` to see the encodings compared:

~~~bash
go test -run TestProtobufIsSmallerThanJSON -v ./internal/grpcapi | grep bytes
~~~

~~~text
    server_test.go:105: protobuf: 37 bytes, JSON: 172 bytes
~~~

The same job is **under a quarter of the size** in protobuf. The field names aren't sent, numbers are packed tightly, and enums are single bytes. Most of the time that doesn't matter. At millions of messages a second, or on a slow, metered link, it does.

## Break it

**The compatibility rule.** Keep the server running from step 6, and keep `/tmp/jobsctl`: it was built from the original contract, like a client another team shipped last month. Now, in `jobs.proto`, swap the numbers of `description` and `duration_ms` in `CreateJobRequest` (make `description = 2` and `duration_ms = 1`). Regenerate, rebuild and restart the server, and create a job with the old client:

~~~bash
kill %1
PATH=$PWD/bin:$PATH protoc --go_out=. --go_opt=module=switchyard \
  --go-grpc_out=. --go-grpc_opt=module=switchyard proto/switchyard/jobs/v1/jobs.proto
go build -o /tmp/switchyard ./cmd/switchyard && /tmp/switchyard > /dev/null &
sleep 0.5
/tmp/jobsctl create "resize images" 300; echo "exit $?"
kill %1
~~~

~~~text
jobsctl: InvalidArgument: description must be between 1 and 200 characters
exit 1
~~~

The old client still puts the description in field 1 and the duration in field 2. The new server reads field 1 as `duration_ms`, an integer, so the text doesn't fit and is skipped as an unknown field; field 2, the `300`, doesn't fit a string either. The server saw an empty request, and rejected it. That was the lucky case. Swap two fields of the *same* type, two strings say, and the server would accept the wrong values without a word. Field numbers **are** the contract on the wire. Changing one breaks every client built from the old file, and nothing warned you: both sides compiled. Undo the swap, and regenerate.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race ./...
~~~

Then answer: why are protobuf field numbers permanent, but field names free to change? Map each of `InvalidArgument`, `NotFound` and `Unavailable` to the HTTP status this API uses for the same situation. How does a deadline set by `jobsctl` reach the server? When would you choose gRPC over JSON, and when not?

Read the [gRPC introduction](https://grpc.io/docs/what-is-grpc/introduction/) and [core concepts](https://grpc.io/docs/what-is-grpc/core-concepts/); the protobuf guide's section [*Updating A Message Type*](https://protobuf.dev/programming-guides/proto3/#updating); and DDIA Ch. 4, *Encoding and Evolution*. Carry this question in: what's the difference between backward and forward compatibility, and which one does each of your services need?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

That proves Switchyard speaks a compiled contract next to its JSON one, and that deadlines cross the wire. The workers still live inside it. The last lesson moves them out, and makes the system survive losing them.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `protoc: command not found` | The protobuf compiler isn't installed | `sudo apt install -y protobuf-compiler` (macOS: `brew install protobuf`) |
| `protoc-gen-go: program not found or is not executable` | The plugins aren't on `PATH` | Prefix the command with `PATH=$PWD/bin:$PATH` |
| `all arguments must refer to packages in the same module` | Two modules in one `go install` | Install each plugin with its own command |
| `undefined: jobsv1.UnimplementedJobsServer` | The generated code is missing or stale | Run the `protoc` command again |
| `listen tcp 127.0.0.1:9090: bind: address already in use` | Another Switchyard (or a test) holds the port | Stop it, or set `GRPC_ADDR=127.0.0.1:0` |
| A change to `jobs.proto` has no effect | The generated files weren't regenerated | Never edit `*.pb.go`; change the `.proto` and run `protoc` |
