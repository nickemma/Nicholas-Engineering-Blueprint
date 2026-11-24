# 04 Limit what the gateway can read and record

## The problem

A gateway expands which clients can request data. Every new route, log field, and configuration permission can expand which data they can reach.

## The pattern

Use a canonical request with only the three allowed command fields. Forward to one fixed path on a trusted peer socket. Authorize before dialing and bound the request and response. Report an upstream failure with one outcome code. Keep a private configuration directory and give the process its leaf key plus the public trust root. Keep the CA key with the signer.

The metadata value is deliberately stored by Raft, so its persistence is part of the data inventory. The canary check covers observable logs and probes. It is a check of those named outputs for that synthetic value.

## Build it

### Step 1. Forward a permitted command

Accept one bounded JSON command, verify its role, and recreate the upstream request yourself. Use the same request deadline when reading its response.

<details>
<summary>Hint</summary>

Use a private Unix socket transport and a fixed upstream path. Keep the successful response value out of log messages.

</details>

<details>
<summary>Completed files</summary>

Create `internal/edge/gateway.go`.

<!-- file: internal/edge/gateway.go -->
~~~go
package edge

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"time"
)

const ResponseLimit = 4096

type Metadata struct {
	Found bool   `json:"found"`
	Value string `json:"value,omitempty"`
}

func UnixTransport(path string) *http.Transport {
	return &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", path)
		},
	}
}

func Gateway(client *http.Client, logger *log.Logger) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /command", func(w http.ResponseWriter, r *http.Request) {
		status := http.StatusBadRequest
		defer func() { logger.Printf("command status=%d", status) }()
		c, err := Decode(http.MaxBytesReader(w, r.Body, CommandLimit))
		if err != nil {
			http.Error(w, "invalid command", status)
			return
		}
		if !allowed(Principal(r.TLS), c.Op) {
			status = http.StatusForbidden
			http.Error(w, "command forbidden", status)
			return
		}
		status = http.StatusServiceUnavailable
		body, _ := json.Marshal(c)
		ctx, cancel := context.WithTimeout(r.Context(), 750*time.Millisecond)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://metad/command", bytes.NewReader(body))
		if err != nil {
			http.Error(w, "upstream unavailable", status)
			return
		}
		req.Header.Set("Content-Type", "application/json")
		res, err := client.Do(req)
		if err != nil {
			http.Error(w, "upstream unavailable", status)
			return
		}
		defer res.Body.Close()
		raw, err := io.ReadAll(io.LimitReader(res.Body, ResponseLimit+1))
		var value *Metadata
		if res.StatusCode != http.StatusOK || err != nil || len(raw) > ResponseLimit ||
			json.Unmarshal(raw, &value) != nil || value == nil {
			http.Error(w, "upstream unavailable", status)
			return
		}
		status = http.StatusOK
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(value)
	})
	return mux
}
~~~

</details>
### Step 2. Start and stop the gateway

Make the certificate and upstream paths configurable. Bind a local listener and use a bounded shutdown on SIGTERM.

<details>
<summary>Hint</summary>

Pass the restricted TLS config into a TLS listener. The restart in the game day should keep the same client endpoint.

</details>

<details>
<summary>Completed files</summary>

Create `cmd/ship-gateway/main.go`.

<!-- file: cmd/ship-gateway/main.go -->
~~~go
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"switchyard/metad/internal/edge"
)

func run() error {
	listen := flag.String("listen", "127.0.0.1:0", "gateway address")
	upstream := flag.String("upstream", "", "private metad socket")
	ca := flag.String("ca", "", "client trust root PEM")
	cert := flag.String("cert", "", "gateway certificate PEM")
	key := flag.String("key", "", "gateway private key PEM")
	flag.Parse()

	if err := edge.CheckSocketPath(*upstream); err != nil {
		return err
	}
	cfg, err := edge.TLSConfig(*ca, *cert, *key, true)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	defer listener.Close()
	transport := edge.UnixTransport(*upstream)
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	server := &http.Server{
		Handler: edge.Gateway(client, log.Default()), ReadTimeout: time.Second,
		WriteTimeout: 2 * time.Second, IdleTimeout: 3 * time.Second,
		ErrorLog: log.New(io.Discard, "", 0),
	}
	log.Printf("listen=%s", listener.Addr())
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	done := make(chan error, 1)
	go func() { done <- server.Serve(tls.NewListener(listener, cfg)) }()
	select {
	case err = <-done:
	case <-ctx.Done():
		drain, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if err := server.Shutdown(drain); err != nil {
			server.Close()
			return err
		}
		err = <-done
	}
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
~~~

</details>
### Step 3. Observe the boundary

Count calls reaching a fake upstream. Compare the reader's denied write with the writer's permitted write. Seed a synthetic value and assert that it stays out of logging.

<details>
<summary>Hint</summary>

Check both the status and the number of forwards. Temporary files make the permission cases reproducible.

</details>

<details>
<summary>Completed files</summary>

Create `internal/edge/gateway_test.go`.

<!-- file: internal/edge/gateway_test.go -->
~~~go
package edge

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (fn transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return fn(r) }

func TestGatewayBoundary(t *testing.T) {
	var logs bytes.Buffer
	forwards := 0
	upstream := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		forwards++
		c, err := Decode(r.Body)
		if err != nil || r.URL.Path != "/command" || c.Value != "test-canary" || c.Op != "put" {
			t.Fatal("wrong upstream request", c, err)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(
			`{"found":true,"value":"test-canary"}`,
		))}, nil
	})}
	handler := Gateway(upstream, log.New(&logs, "", 0))
	for _, x := range []struct {
		role string
		want int
	}{{"reader", 403}, {"writer", 200}} {
		r := httptest.NewRequest("POST", "/command", strings.NewReader(
			`{"Op":"put","Key":"test-key","Value":"test-canary"}`,
		))
		name, err := url.Parse("urn:switchyard:" + x.role)
		if err != nil {
			t.Fatal(err)
		}
		r.TLS = &tls.ConnectionState{VerifiedChains: [][]*x509.Certificate{{{URIs: []*url.URL{name}}}}}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != x.want {
			t.Fatalf("%s got %d; want %d", x.role, w.Code, x.want)
		}
	}
	if forwards != 1 || strings.Contains(logs.String(), "test-canary") || strings.Contains(logs.String(), "test-key") {
		t.Fatalf("forwards=%d logs=%q", forwards, logs.String())
	}
	t.Log("only the writer reached the upstream; the log omitted the key and value")
}

func TestPrivatePaths(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if CheckSocketPath(filepath.Join(dir, "metad.sock")) == nil {
		t.Fatal("accepted group-readable socket directory")
	}
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := CheckSocketPath(filepath.Join(dir, "metad.sock")); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "key.pem")
	if err := os.WriteFile(path, []byte("fixture"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadPair("unused", path); err == nil || !strings.Contains(err.Error(), "owner-restricted") {
		t.Fatal("did not refuse shared key permissions", err)
	}
	t.Log("shared upstream directory and readable private key were both rejected")
}
~~~

</details>

## Check it

~~~bash
go vet ./internal/edge ./cmd/ship-gateway && go test -race -count=1 -run '^Test' -v ./internal/edge
~~~

<!-- run: go vet ./internal/edge ./cmd/ship-gateway && go test -race -count=1 -run '^Test' -v ./internal/edge -->

~~~text
    gateway_test.go:57: only the writer reached the upstream; the log omitted the key and value
    gateway_test.go:84: shared upstream directory and readable private key were both rejected
~~~

The gate repeats the boundary check with the real gateway and peers.

[Captured output](../evidence/04-boundary.txt)

## Explain it

Which access assumptions have to hold for the Unix socket directory to be an effective boundary?
