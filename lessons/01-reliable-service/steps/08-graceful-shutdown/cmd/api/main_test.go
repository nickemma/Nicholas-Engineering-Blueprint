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
