# 13 Trace and profile the wire

## The problem

An HTTP request delays while talking to the data plane. Its duration alone gives no attribution for the delay.

## The mental model

The trace relates an HTTP request to a Go client span. CPU samples show where the Go process was computing. Neither measurement replaces the on-the-wire drop count.

## The pattern

Trace communication boundaries, collect CPU profiles under equal offered load, and turn an observed hotspot into a small testable code change.

## Build it

### Step 1. Export a parent and client span

Start the server span from the trace context on the incoming request. The Go client span is its child, and covers the exchange with Rust. This lab prints the two spans from Go. The Rust process independently checks the frames.

~~~bash
cd wire/control && go get go.opentelemetry.io/otel@v1.47.0 go.opentelemetry.io/otel/sdk@v1.47.0
~~~

<!-- run: cd wire/control && go get go.opentelemetry.io/otel@v1.47.0 go.opentelemetry.io/otel/sdk@v1.47.0 -->

Create `wire/control/internal/wire/trace.go`.

<!-- file: wire/control/internal/wire/trace.go -->
~~~go
package wire

import (
	"context"
	"encoding/json"
	"io"
	"net/http"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

type traceExport struct {
	output io.Writer
}

func (e traceExport) ExportSpans(_ context.Context, spans []sdktrace.ReadOnlySpan) error {
	encoder := json.NewEncoder(e.output)
	for _, span := range spans {
		info := map[string]any{
			"span":   span.Name(),
			"trace":  span.SpanContext().TraceID().String(),
			"id":     span.SpanContext().SpanID().String(),
			"parent": span.Parent().SpanID().String(),
			"kind":   span.SpanKind().String(),
			"status": span.Status().Code.String(),
		}
		if err := encoder.Encode(info); err != nil {
			return err
		}
	}
	return nil
}

func (traceExport) Shutdown(context.Context) error { return nil }

func NewTraceProvider(output io.Writer) *sdktrace.TracerProvider {
	return sdktrace.NewTracerProvider(sdktrace.WithSyncer(traceExport{output: output}))
}

type tracedClient struct {
	inner  RoundTripper
	tracer trace.Tracer
}

func (c tracedClient) RoundTrip(ctx context.Context, payload []byte) (uint64, error) {
	ctx, span := c.tracer.Start(ctx, "rust.exchange",
		trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(attribute.Int("wire.request_bytes", len(payload))))
	defer span.End()
	n, err := c.inner.RoundTrip(ctx, payload)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "exchange failed")
	}
	return n, err
}

func TracedHandler(client RoundTripper, tracer trace.Tracer) http.Handler {
	inner := Handler(tracedClient{inner: client, tracer: tracer})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		parent := propagation.TraceContext{}.Extract(r.Context(), propagation.HeaderCarrier(r.Header))
		ctx, span := tracer.Start(parent, "POST /wire", trace.WithSpanKind(trace.SpanKindServer))
		defer span.End()
		inner.ServeHTTP(w, r.WithContext(ctx))
	})
}
~~~

Create `wire/control/internal/wire/profile.go`.

<!-- file: wire/control/internal/wire/profile.go -->
~~~go
package wire

import (
	"errors"
	"net"
	"net/http"
	"net/http/pprof"
	"time"
)

func ListenProfile(address string) (*http.Server, string, error) {
	host, _, err := net.SplitHostPort(address)
	if err != nil || !net.ParseIP(host).IsLoopback() {
		return nil, "", errors.New("profiler requires a numeric loopback address and port")
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return nil, "", err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /debug/pprof/profile", pprof.Profile)
	server := &http.Server{Handler: mux, ReadHeaderTimeout: 3 * time.Second}
	go func() { _ = server.Serve(listener) }()
	return server, listener.Addr().String(), nil
}
~~~

### Step 2. Expose the profiler on a loopback listener

Select WIRE_TRACE=1 during the trace drill. Use WIRE_PROFILE_ADDR=127.0.0.1:0 to get a separate local profiler endpoint. Leave tracing off during the load experiment so the instrumented path stays the same across builds.

Edit `wire/control/cmd/switchyard/main.go`.

<!-- edit: wire/control/cmd/switchyard/main.go -->
~~~go
}

type config struct {
	WireTarget             string
	ListenAddr             string
	GRPCAddr               string
~~~

~~~go
}

type config struct {
	WireProfileAddr        string
	WireTrace              bool
	WireTarget             string
	ListenAddr             string
	GRPCAddr               string
~~~

<!-- edit: wire/control/cmd/switchyard/main.go -->
~~~go
		return config{}, err
	}
	cfg.WireTarget = getenv("WIRE_TARGET")
	cfg.DatabaseURL = getenv("SWITCHYARD_DATABASE_URL")
	if cfg.DatabaseMaxConns, err = positiveIntFromEnv(getenv, "DATABASE_MAX_CONNS", 4); err != nil {
		return config{}, err
~~~

~~~go
		return config{}, err
	}
	cfg.WireTarget = getenv("WIRE_TARGET")
	cfg.WireProfileAddr = getenv("WIRE_PROFILE_ADDR")
	cfg.WireTrace = getenv("WIRE_TRACE") == "1"
	cfg.DatabaseURL = getenv("SWITCHYARD_DATABASE_URL")
	if cfg.DatabaseMaxConns, err = positiveIntFromEnv(getenv, "DATABASE_MAX_CONNS", 4); err != nil {
		return config{}, err
~~~

<!-- edit: wire/control/cmd/switchyard/main.go -->
~~~go
		}
		defer client.Close()
		wireHandler = wire.Handler(client)
	}

	handler := httpapi.NewHandler(service,
~~~

~~~go
		}
		defer client.Close()
		wireHandler = wire.Handler(client)
		if cfg.WireTrace {
			provider := wire.NewTraceProvider(stdout)
			defer func() {
				finish, cancel := context.WithTimeout(context.Background(), time.Second)
				defer cancel()
				_ = provider.Shutdown(finish)
			}()
			wireHandler = wire.TracedHandler(client, provider.Tracer("switchyard/wire"))
		}
	}

	if cfg.WireProfileAddr != "" {
		profile, addr, err := wire.ListenProfile(cfg.WireProfileAddr)
		if err != nil {
			return fmt.Errorf("WIRE_PROFILE_ADDR: %w", err)
		}
		defer profile.Close()
		logger.Info("wire profiler listening", "addr", addr)
	}

	handler := httpapi.NewHandler(service,
~~~

### Step 3. Keep two builds for the measurement

Edit `wire/control/internal/wire/checksum.go`.

<!-- edit: wire/control/internal/wire/checksum.go -->
~~~go
package wire

func checksum(payload []byte) uint32 {
~~~

~~~go
//go:build slowwire

package wire

func checksum(payload []byte) uint32 {
~~~

Create `wire/control/internal/wire/checksum_fast.go`.

<!-- file: wire/control/internal/wire/checksum_fast.go -->
~~~go
//go:build !slowwire

package wire

import "hash/crc32"

func checksum(payload []byte) uint32 {
	return crc32.Checksum(payload, table)
}
~~~

Create `wire/control/internal/wire/trace_test.go`.

<!-- file: wire/control/internal/wire/trace_test.go -->
~~~go
package wire

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestChildUsesInboundTrace(t *testing.T) {
	var output bytes.Buffer
	provider := NewTraceProvider(&output)
	defer provider.Shutdown(context.Background())
	handler := TracedHandler(testClient{}, provider.Tracer("test"))
	req := httptest.NewRequest(http.MethodPost, "/wire", strings.NewReader("job"))
	req.Header.Set("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
	handler.ServeHTTP(httptest.NewRecorder(), req)
	dec := json.NewDecoder(&output)
	var child, parent map[string]string
	if err := dec.Decode(&child); err != nil {
		t.Fatal(err)
	}
	if err := dec.Decode(&parent); err != nil {
		t.Fatal(err)
	}
	if child["span"] != "rust.exchange" || parent["span"] != "POST /wire" ||
		child["parent"] != parent["id"] || child["trace"] != parent["trace"] ||
		parent["trace"] != "4bf92f3577b34da6a3ce929d0e0e4736" ||
		parent["parent"] != "00f067aa0ba902b7" {
		t.Fatalf("child=%v parent=%v", child, parent)
	}
	t.Logf("%s -> %s shares inbound trace", parent["span"], child["span"])
}

func TestProfileRejectsPublicBind(t *testing.T) {
	if _, _, err := ListenProfile("0.0.0.0:0"); err == nil {
		t.Fatal("profiler accepted a non-loopback bind")
	}
}

func BenchmarkRequestChecksum(b *testing.B) {
	payload := bytes.Repeat([]byte("job "), 16*1024)
	b.SetBytes(int64(len(payload)))
	var result uint32
	for b.Loop() {
		result = checksum(payload)
	}
	if result == 0 {
		b.Fatal("unexpected checksum")
	}
}
~~~

~~~bash
cd wire/control && go mod tidy && go vet ./internal/wire ./cmd/switchyard && go test -race ./internal/wire ./cmd/switchyard && go test -tags slowwire ./internal/wire
~~~

<!-- run: cd wire/control && go mod tidy && go vet ./internal/wire ./cmd/switchyard && go test -race ./internal/wire ./cmd/switchyard && go test -tags slowwire ./internal/wire -->

~~~text
trace_test.go:35: POST /wire -> rust.exchange shares inbound trace
--- PASS: TestChildUsesInboundTrace (0.00s)
--- PASS: TestProfileRejectsPublicBind (0.00s)
~~~

### Step 4. Profile the baseline before judging the fix

Use the slowwire build first in lesson 14. In the CPU flame graph, look for wide frames above the HTTP handler. Cross-check the flat and cumulative columns. Both builds pass the same frame-byte contract. The microbenchmark holds the request body fixed and changes only its checksum implementation.

~~~bash
cd wire/control && go test -tags slowwire -run "^$" -bench BenchmarkRequestChecksum ./internal/wire && go test -run "^$" -bench BenchmarkRequestChecksum ./internal/wire
~~~

~~~text
goos: linux
goarch: amd64
pkg: switchyard/internal/wire
cpu: AMD Ryzen 7 PRO 5850U with Radeon Graphics     
BenchmarkRequestChecksum-16    	     268	   4408876 ns/op	  14.86 MB/s
PASS
ok  	switchyard/internal/wire	1.203s
goos: linux
goarch: amd64
pkg: switchyard/internal/wire
cpu: AMD Ryzen 7 PRO 5850U with Radeon Graphics     
BenchmarkRequestChecksum-16    	  237770	      5232 ns/op	12524.83 MB/s
PASS
ok  	switchyard/internal/wire	1.266s
~~~

## Check it

Identify the parent and child spans by their IDs. Use the measured baseline in lesson 14 to say whether CRC was a CPU bottleneck and what remains after the change.

## If it goes wrong

Use a numeric loopback address for the profiler. If its profile is empty, check that the load overlapped the sample window and that the request target really enabled the wire route.
