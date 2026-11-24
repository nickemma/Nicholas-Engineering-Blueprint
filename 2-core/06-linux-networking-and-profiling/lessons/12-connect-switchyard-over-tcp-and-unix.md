# 12 Connect Switchyard over TCP and Unix sockets

## The problem

The Go control plane needs to talk to the Rust process and reject malformed replies. A slow Rust receiver must not tie up unbounded Go handlers.

## The mental model

The existing HTTP router accepts one bounded body at POST /wire. The wire client borrows a socket from its pool, writes a frame and waits for an acknowledgment. The Rust process validates the frame and returns a checksummed length.

## The pattern

Use one framing contract for both transports. Keep complete exchanges exclusive per connection. Bound waiting and discard a connection if its framing state becomes uncertain.

## Build it

### Step 1. Continue the Switchyard checkout

Keep Go under `wire/control` and leave the profiling exercise in the module root. The replay starts with the control plane you built in Core 03.

<!-- continue: ../../03-docker-and-postgres into wire/control -->

### Step 2. Encode the same frame in Go

The format stays byte-for-byte compatible with the Rust frame. Keep the original bit-at-a-time CRC for the first measurement. The header guard and small acknowledgment already use the standard library.

Create `wire/control/internal/wire/checksum.go`.

<!-- file: wire/control/internal/wire/checksum.go -->
~~~go
package wire

func checksum(payload []byte) uint32 {
	const reflectedCastagnoli = 0x82f63b78
	crc := ^uint32(0)
	for _, value := range payload {
		crc ^= uint32(value)
		for range 8 {
			if crc&1 != 0 {
				crc = (crc >> 1) ^ reflectedCastagnoli
			} else {
				crc >>= 1
			}
		}
	}
	return ^crc
}
~~~

Create `wire/control/internal/wire/client.go`.

<!-- file: wire/control/internal/wire/client.go -->
~~~go
package wire

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"net"
	"strings"
	"sync"
	"time"
)

const HeaderSize = 12
const MaxRequest = 96 * 1024

var table = crc32.MakeTable(crc32.Castagnoli)
var errClosed = errors.New("wire client closed")

type Client struct {
	network string
	address string
	timeout time.Duration
	active  chan struct{}
	idle    chan net.Conn
	mu      sync.Mutex
	closed  bool
}

func NewClient(target string, capacity int, timeout time.Duration) (*Client, error) {
	network, address, found := strings.Cut(target, "://")
	if !found || address == "" || (network != "tcp" && network != "unix") {
		return nil, errors.New("use tcp://host:port or unix:///path")
	}
	if network == "tcp" {
		if _, _, err := net.SplitHostPort(address); err != nil {
			return nil, fmt.Errorf("invalid TCP address: %w", err)
		}
	}
	if capacity <= 0 || timeout <= 0 {
		return nil, errors.New("capacity and timeout must be positive")
	}
	return &Client{
		network: network, address: address, timeout: timeout,
		active: make(chan struct{}, capacity), idle: make(chan net.Conn, capacity),
	}, nil
}

func (c *Client) take(ctx context.Context) (net.Conn, error) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil, errClosed
	}
	select {
	case conn := <-c.idle:
		c.mu.Unlock()
		return conn, nil
	default:
		c.mu.Unlock()
		return (&net.Dialer{}).DialContext(ctx, c.network, c.address)
	}
}

func (c *Client) release(conn net.Conn, reusable bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if reusable && !c.closed {
		c.idle <- conn
		return
	}
	_ = conn.Close()
}

func (c *Client) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closed = true
	for {
		select {
		case conn := <-c.idle:
			_ = conn.Close()
		default:
			return
		}
	}
}

func (c *Client) RoundTrip(parent context.Context, payload []byte) (uint64, error) {
	if len(payload) > MaxRequest {
		return 0, errors.New("wire request too large")
	}
	ctx, cancel := context.WithTimeout(parent, c.timeout)
	defer cancel()
	select {
	case c.active <- struct{}{}:
		defer func() { <-c.active }()
	case <-ctx.Done():
		return 0, ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	conn, err := c.take(ctx)
	if err != nil {
		return 0, err
	}
	deadline, _ := ctx.Deadline()
	if err := conn.SetDeadline(deadline); err != nil {
		c.release(conn, false)
		return 0, err
	}
	interrupted := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		_ = conn.SetDeadline(time.Now())
		close(interrupted)
	})
	n, err := exchange(conn, payload)
	if !stop() {
		<-interrupted
	}
	cancelled := ctx.Err()
	c.release(conn, err == nil && cancelled == nil)
	if cancelled != nil {
		return 0, cancelled
	}
	return n, err
}

func frameHeader(payload []byte) [HeaderSize]byte {
	var header [HeaderSize]byte
	binary.LittleEndian.PutUint32(header[:4], uint32(len(payload)))
	binary.LittleEndian.PutUint32(header[4:8], checksum(payload))
	binary.LittleEndian.PutUint32(header[8:12], crc32.Checksum(header[:8], table))
	return header
}

func exchange(conn net.Conn, payload []byte) (uint64, error) {
	header := frameHeader(payload)
	vectors := net.Buffers{header[:], payload}
	if _, err := vectors.WriteTo(conn); err != nil {
		return 0, err
	}
	var ack [HeaderSize + 8]byte
	if _, err := io.ReadFull(conn, ack[:]); err != nil {
		return 0, err
	}
	if binary.LittleEndian.Uint32(ack[:4]) != 8 ||
		binary.LittleEndian.Uint32(ack[8:12]) != crc32.Checksum(ack[:8], table) ||
		binary.LittleEndian.Uint32(ack[4:8]) != crc32.Checksum(ack[HeaderSize:], table) {
		return 0, errors.New("bad acknowledgment frame")
	}
	n := binary.LittleEndian.Uint64(ack[HeaderSize:])
	if n != uint64(len(payload)) {
		return 0, errors.New("acknowledged length differs from sent length")
	}
	return n, nil
}
~~~

The channel bounds outstanding exchanges. Idle connections are reused by one caller at a time. The deadline covers waiting, dialing, writing, and reading. A failed exchange closes the connection. Any later retry is a separate decision for the caller.

### Step 3. Put the probe on the existing Go HTTP server

Create `wire/control/internal/wire/http.go`.

<!-- file: wire/control/internal/wire/http.go -->
~~~go
package wire

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
)

type RoundTripper interface {
	RoundTrip(context.Context, []byte) (uint64, error)
}

func Handler(client RoundTripper) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxRequest))
		var oversized *http.MaxBytesError
		if errors.As(err, &oversized) {
			http.Error(w, "wire request too large", http.StatusRequestEntityTooLarge)
			return
		}
		if err != nil {
			http.Error(w, "cannot read request", http.StatusBadRequest)
			return
		}
		n, err := client.RoundTrip(r.Context(), body)
		var networkErr net.Error
		if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &networkErr) && networkErr.Timeout()) {
			http.Error(w, "data plane timed out", http.StatusGatewayTimeout)
			return
		}
		if err != nil {
			http.Error(w, "data plane exchange failed", http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, "{\"bytes\":%d}\n", n)
	})
}
~~~

Edit `wire/control/cmd/switchyard/main.go`.

<!-- edit: wire/control/cmd/switchyard/main.go -->
~~~go
	"switchyard/internal/memstore"
	"switchyard/internal/pgstore"
	"switchyard/internal/queue"
)

func main() {
~~~

~~~go
	"switchyard/internal/memstore"
	"switchyard/internal/pgstore"
	"switchyard/internal/queue"
	"switchyard/internal/wire"
)

func main() {
~~~

<!-- edit: wire/control/cmd/switchyard/main.go -->
~~~go
}

type config struct {
	ListenAddr             string
	GRPCAddr               string
	RequestTimeout         time.Duration
~~~

~~~go
}

type config struct {
	WireTarget             string
	ListenAddr             string
	GRPCAddr               string
	RequestTimeout         time.Duration
~~~

<!-- edit: wire/control/cmd/switchyard/main.go -->
~~~go
	if cfg.LeaseTTL, err = durationFromEnv(getenv, "LEASE_TTL", cfg.LeaseTTL); err != nil {
		return config{}, err
	}
	cfg.DatabaseURL = getenv("SWITCHYARD_DATABASE_URL")
	if cfg.DatabaseMaxConns, err = positiveIntFromEnv(getenv, "DATABASE_MAX_CONNS", 4); err != nil {
		return config{}, err
~~~

~~~go
	if cfg.LeaseTTL, err = durationFromEnv(getenv, "LEASE_TTL", cfg.LeaseTTL); err != nil {
		return config{}, err
	}
	cfg.WireTarget = getenv("WIRE_TARGET")
	cfg.DatabaseURL = getenv("SWITCHYARD_DATABASE_URL")
	if cfg.DatabaseMaxConns, err = positiveIntFromEnv(getenv, "DATABASE_MAX_CONNS", 4); err != nil {
		return config{}, err
~~~

<!-- edit: wire/control/cmd/switchyard/main.go -->
~~~go
		)
	}

	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
~~~

~~~go
		)
	}

	var wireHandler http.Handler
	if cfg.WireTarget != "" {
		client, err := wire.NewClient(cfg.WireTarget, 16, time.Second)
		if err != nil {
			return fmt.Errorf("WIRE_TARGET: %w", err)
		}
		defer client.Close()
		wireHandler = wire.Handler(client)
	}

	handler := httpapi.NewHandler(service,
		httpapi.WithWire(wireHandler),
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
~~~

Edit `wire/control/internal/httpapi/handler.go`.

<!-- edit: wire/control/internal/httpapi/handler.go -->
~~~go
}

type config struct {
	keyed          KeyedSubmitter
	logger         *slog.Logger
	metrics        *Metrics
~~~

~~~go
}

type config struct {
	wire           http.Handler
	keyed          KeyedSubmitter
	logger         *slog.Logger
	metrics        *Metrics
~~~

<!-- edit: wire/control/internal/httpapi/handler.go -->
~~~go

// Option configures the handler built by NewHandler.
type Option func(*config)

func WithLogger(logger *slog.Logger) Option {
	return func(c *config) { c.logger = logger }
~~~

~~~go

// Option configures the handler built by NewHandler.
type Option func(*config)

// WithWire enables the data-plane probe when a target is configured.
func WithWire(handler http.Handler) Option {
	return func(c *config) { c.wire = handler }
}

func WithLogger(logger *slog.Logger) Option {
	return func(c *config) { c.logger = logger }
~~~

<!-- edit: wire/control/internal/httpapi/handler.go -->
~~~go
		create = idempotency.Middleware(cfg.idempotency, maxBodyBytes, create)
	}
	mux.Handle("POST /jobs", create)
	mux.HandleFunc("GET /jobs/{id}", h.getJob)
	mux.HandleFunc("POST /jobs/{id}/cancel", h.cancelJob)
	if cfg.effects != nil {
~~~

~~~go
		create = idempotency.Middleware(cfg.idempotency, maxBodyBytes, create)
	}
	mux.Handle("POST /jobs", create)
	if cfg.wire != nil {
		mux.Handle("POST /wire", cfg.wire)
	}
	mux.HandleFunc("GET /jobs/{id}", h.getJob)
	mux.HandleFunc("POST /jobs/{id}/cancel", h.cancelJob)
	if cfg.effects != nil {
~~~

### Step 4. Check the header and the HTTP bounds

Create `wire/control/internal/wire/client_test.go`.

<!-- file: wire/control/internal/wire/client_test.go -->
~~~go
package wire

import (
	"context"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestFrameMatchesRustFixture(t *testing.T) {
	header := frameHeader([]byte("job"))
	if got := hex.EncodeToString(header[:]); got != "03000000117863d6389d964c" {
		t.Fatalf("header = %s", got)
	}
}

func TestQueueWaitRespectsCancellation(t *testing.T) {
	client, err := NewClient("tcp://127.0.0.1:1", 1, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	client.active <- struct{}{}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := client.RoundTrip(ctx, nil); err != context.Canceled {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
}

type testClient struct{}

func (testClient) RoundTrip(_ context.Context, payload []byte) (uint64, error) {
	return uint64(len(payload)), nil
}

func TestHTTPChecksSizeAndAcknowledgment(t *testing.T) {
	handler := Handler(testClient{})
	for _, tc := range []struct{ size, status int }{{3, 200}, {MaxRequest + 1, 413}} {
		req := httptest.NewRequest(http.MethodPost, "/wire", strings.NewReader(strings.Repeat("a", tc.size)))
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, req)
		if response.Code != tc.status {
			t.Fatalf("size %d: status = %d, want %d", tc.size, response.Code, tc.status)
		}
	}
}
~~~

~~~bash
cd wire/control && go vet ./internal/wire && go test -race ./internal/wire ./internal/httpapi ./cmd/switchyard
~~~

<!-- run: cd wire/control && go vet ./internal/wire && go test -race ./internal/wire ./internal/httpapi ./cmd/switchyard -->

~~~text
ok  	switchyard/internal/wire	1.045s
ok  	switchyard/internal/httpapi	1.098s
ok  	switchyard/cmd/switchyard	1.216s
~~~

Use `WIRE_TARGET=tcp://127.0.0.1:PORT` or `WIRE_TARGET=unix:///absolute/path`. Start Rust first, then the Go API, and POST three raw bytes to `/wire`. Lesson 14 runs both socket types from a fresh checkout.

## Check it

Explain why ReadFull is used for the acknowledgment, how a cancellation interrupts an active operation, and why the pool must wait for the interruption callback before returning the connection.

## If it goes wrong

For a 502, inspect the Rust listener address and logs. For a 504, check the total exchange deadline and pool occupancy. A missing /wire route means WIRE_TARGET was unset.
