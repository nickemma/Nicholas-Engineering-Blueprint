# 04 Put an admission boundary on Switchyard

A model server is an expensive dependency. Switchyard authenticates before allocating its capacity. Keep Phase 6's JWT issuer, audience, expiry and tenant checks; never trust an `X-Tenant` header. The serving boundary below accepts a verified identity callback so its logic can be tested without replaying the database and broker phases.

Create a separate lab module. When integrating, copy `internal/inference` into your existing `runway` module; keep its existing `go.mod`.

<!-- file: gateway/go.mod -->
~~~text
module phase8gateway

go 1.26
~~~

Reserve prompt tokens plus the maximum output, using the **same chat template and tokenizer** as generation. Counting words is not a token limit. A reservation survives cancellation and backend failure, which is conservative but stops a retry from evading the budget. This lab uses a per-process fixed-minute budget; a multi-replica deployment must use Phase 6's atomic Redis limiter, or explicitly partition budgets. A minute boundary allows a double burst. Production billing would reconcile actual usage in a durable ledger.


<!-- file: gateway/internal/inference/gateway.go -->
~~~go
// Package inference implements bounded admission for an authenticated Runway route.
package inference

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

type Identity func(*http.Request) (string, bool)
type Tokenizer func(context.Context, json.RawMessage) (int, error)

// Reservation atomically reserves prompt plus maximum output for one verified tenant.
type Reservation func(context.Context, string, int) (bool, error)

type Gateway struct {
	hooks    Hooks
	reserve  Reservation
	identity Identity
	tokenize Tokenizer
	url      string
	client   *http.Client
	active   chan struct{}
	admitted chan struct{}
	mu       sync.Mutex
	usage    map[string]int
	minute   int64
	budget   int
	requests atomic.Int64
	failures atomic.Int64
	first    atomic.Int64
	fast     atomic.Int64
}

func New(url string, identity Identity, tokenize Tokenizer, slots, queue, budget int) *Gateway {
	if slots < 1 || queue < 0 || budget < 1 {
		panic("invalid capacity")
	}
	g := &Gateway{identity: identity, tokenize: tokenize, url: url,
		client: &http.Client{}, active: make(chan struct{}, slots),
		admitted: make(chan struct{}, slots+queue), usage: map[string]int{}, budget: budget}
	g.reserve = func(_ context.Context, tenant string, tokens int) (bool, error) { return g.charge(tenant, tokens), nil }
	return g
}

// UseReservation configures shared accounting before serving any requests.
// Failure must be returned, not silently replaced with a per-process budget.
func (g *Gateway) UseReservation(reserve Reservation) {
	if reserve == nil {
		panic("nil reservation")
	}
	g.reserve = reserve
}

// charge reserves prompt + maximum output before admission. Conservatively keep
// reservations on failure/cancellation so retries cannot evade the token budget.
func (g *Gateway) charge(tenant string, tokens int) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	minute := time.Now().Unix() / 60
	if g.minute != minute {
		g.usage = map[string]int{}
		g.minute = minute
	}
	if tokens > g.budget-g.usage[tenant] {
		return false
	}
	g.usage[tenant] += tokens
	return true
}

func (g *Gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	tenant, ok := g.identity(r)
	if !ok || tenant == "" {
		http.Error(w, "unauthorized", 401)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	g.requests.Add(1)
	start := time.Now()
	outcome := "invalid"
	var queued time.Duration
	state := streamState{tokens: -1}
	defer func() {
		if g.hooks.Finish != nil {
			ttft := time.Duration(-1)
			if !state.first.IsZero() {
				ttft = state.first.Sub(start)
			}
			g.hooks.Finish(r.Context(), outcome, ttft, queued, state.tokens)
		}
	}()
	// The deadline includes waiting, tokenization and the full streamed answer.
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if err != nil {
		http.Error(w, "body too large", 413)
		return
	}
	var input struct {
		Messages  json.RawMessage `json:"messages"`
		MaxTokens int             `json:"max_tokens"`
		Stream    bool            `json:"stream"`
	}
	if json.Unmarshal(body, &input) != nil || input.MaxTokens < 1 || input.MaxTokens > 512 || !input.Stream {
		http.Error(w, "stream=true and max_tokens 1..512 required", 400)
		return
	}
	// Bound tokenizer work as well as generation. This is bounded admission,
	// not a strict FIFO queue: Go's semaphore does not promise tenant fairness.
	select {
	case g.admitted <- struct{}{}:
	default:
		w.Header().Set("Retry-After", "1")
		outcome = "overloaded"
		http.Error(w, "overloaded", 503)
		return
	}
	defer func() { <-g.admitted }()
	waitStart := time.Now()
	_, endQueue := g.stage(ctx, "inference.queue")
	select {
	case g.active <- struct{}{}:
		queued = time.Since(waitStart)
		endQueue()
	case <-ctx.Done():
		queued = time.Since(waitStart)
		endQueue()
		outcome = "deadline"
		http.Error(w, "queue deadline", 504)
		return
	}
	defer func() { <-g.active }()
	tokenCtx, endToken := g.stage(ctx, "inference.tokenize")
	n, err := g.tokenize(tokenCtx, input.Messages)
	endToken()
	if err != nil {
		outcome = "backend_error"
		g.failures.Add(1)
		http.Error(w, "tokenizer unavailable", 502)
		return
	}
	if n < 1 || n+input.MaxTokens > 4096 {
		http.Error(w, "invalid context", 400)
		return
	}
	reserveCtx, endReserve := g.stage(ctx, "inference.reserve")
	allowed, reserveErr := g.reserve(reserveCtx, tenant, n+input.MaxTokens)
	endReserve()
	if reserveErr != nil {
		outcome = "budget_unavailable"
		http.Error(w, "budget unavailable", 503)
		return
	}
	if !allowed {
		w.Header().Set("Retry-After", "60")
		outcome = "limited"
		http.Error(w, "token budget", 429)
		return
	}
	// Build a fresh allowlisted request: callers cannot inject a model path,
	// tools, backend URLs or a server-side chat template.
	payload, _ := json.Marshal(map[string]any{"messages": input.Messages,
		"max_tokens": input.MaxTokens, "stream": true, "temperature": 0, "cache_prompt": false, "stream_options": map[string]bool{"include_usage": true}})
	backendCtx, endBackend := g.stage(ctx, "inference.backend_stream")
	defer endBackend()
	outcome = "backend_error"
	req, err := http.NewRequestWithContext(backendCtx, http.MethodPost, g.url+"/v1/chat/completions", bytes.NewReader(payload))
	if err != nil {
		http.Error(w, "backend configuration", 502)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	// Request context cancels the upstream HTTP request on disconnect/deadline.
	res, err := g.client.Do(req)
	if err != nil {
		g.failures.Add(1)
		http.Error(w, "backend unavailable", 502)
		return
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		g.failures.Add(1)
		http.Error(w, "backend rejected", 502)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	buf := make([]byte, 4096)
	recorded := false
	for {
		n, readErr := res.Body.Read(buf)
		if n > 0 {
			if err := state.accept(buf[:n]); err != nil {
				outcome = "protocol_error"
				g.failures.Add(1)
				return
			}
			// HTTP streaming requires a write deadline too: an upstream deadline
			// alone cannot unblock a write to a client that stopped reading.
			_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(5 * time.Second))
			if _, err := w.Write(buf[:n]); err != nil {
				outcome = "cancelled"
				g.failures.Add(1)
				return
			}
			if err := http.NewResponseController(w).Flush(); err != nil {
				outcome = "cancelled"
				g.failures.Add(1)
				return
			}
			if !recorded {
				recorded = true
				g.first.Add(1)
				if time.Since(start) <= time.Second {
					g.fast.Add(1)
				}
			}
			if state.done {
				if state.first.IsZero() {
					outcome = "incomplete"
					g.failures.Add(1)
				} else {
					outcome = "complete"
				}
				return
			}
		}
		if readErr != nil {
			if readErr == io.EOF && state.done && !state.first.IsZero() {
				outcome = "complete"
			} else {
				outcome = "incomplete"
				if ctx.Err() != nil {
					outcome = "cancelled"
				}
				g.failures.Add(1)
			}
			return
		}
	}
}

// These fixed label-free metrics cannot leak tenant IDs or prompt contents.
// First-byte is a transport diagnostic, NOT first-content-token latency.
func (g *Gateway) Metrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "inference_admitted %d\ninference_active %d\ninference_requests_total %d\ninference_transport_failures_total %d\ninference_first_byte_total %d\ninference_first_byte_fast_total %d\n",
		len(g.admitted), len(g.active), g.requests.Load(), g.failures.Load(), g.first.Load(), g.fast.Load())
}
~~~


<!-- file: gateway/internal/inference/tokenizer.go -->
~~~go
package inference

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// LlamaTokenizer uses the pinned server's chat template and tokenizer together.
// Tokenizing raw user text would omit role markers and template overhead.
func LlamaTokenizer(url string) Tokenizer {
	return LlamaTokenizerWithClient(url, &http.Client{})
}

func LlamaTokenizerWithClient(url string, client *http.Client) Tokenizer {
	return func(ctx context.Context, messages json.RawMessage) (int, error) {
		post := func(path string, input, output any) error {
			body, err := json.Marshal(input)
			if err != nil {
				return err
			}
			req, err := http.NewRequestWithContext(ctx, "POST", url+path, bytes.NewReader(body))
			if err != nil {
				return err
			}
			req.Header.Set("Content-Type", "application/json")
			res, err := client.Do(req)
			if err != nil {
				return err
			}
			defer res.Body.Close()
			if res.StatusCode != 200 {
				return fmt.Errorf("tokenizer status %d", res.StatusCode)
			}
			return json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(output)
		}
		var formatted struct {
			Prompt string `json:"prompt"`
		}
		if err := post("/apply-template", map[string]any{"messages": messages, "add_generation_prompt": true}, &formatted); err != nil {
			return 0, err
		}
		var result struct {
			Tokens []int `json:"tokens"`
		}
		err := post("/tokenize", map[string]any{"content": formatted.Prompt, "add_special": true}, &result)
		return len(result.Tokens), err
	}
}
~~~


<!-- file: gateway/internal/inference/gateway_test.go -->
~~~go
package inference

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const request = `{"messages":[{"role":"user","content":"hi"}],"max_tokens":8,"stream":true}`

func identity(r *http.Request) (string, bool)              { return "acme", r.Header.Get("Authorization") == "test" }
func tokens(context.Context, json.RawMessage) (int, error) { return 4, nil }
func call(g *Gateway, authorized bool) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "/v1/chat/completions", strings.NewReader(request))
	if authorized {
		r.Header.Set("Authorization", "test")
	}
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	return w
}
func TestAuthAndTokenReservations(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"river\"}}]}\n\ndata: [DONE]\n\n"))
	}))
	defer backend.Close()
	g := New(backend.URL, identity, tokens, 1, 0, 12)
	if got := call(g, false).Code; got != 401 {
		t.Fatal(got)
	}
	if got := call(g, true).Code; got != 200 {
		t.Fatal(got)
	}
	if got := call(g, true).Code; got != 429 {
		t.Fatal(got)
	}
}
func TestDisconnectCancelsUpstreamAndReleasesSlot(t *testing.T) {
	started := make(chan struct{})
	cancelled := make(chan struct{})
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		close(started)
		<-r.Context().Done()
		close(cancelled)
	}))
	defer backend.Close()
	g := New(backend.URL, identity, tokens, 1, 0, 100)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r := httptest.NewRequest("POST", "/", strings.NewReader(request)).WithContext(ctx)
	r.Header.Set("Authorization", "test")
	done := make(chan struct{})
	go func() { g.ServeHTTP(httptest.NewRecorder(), r); close(done) }()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("backend not reached")
	}
	if got := call(g, true).Code; got != 503 {
		t.Fatal(got)
	}
	cancel()
	select {
	case <-cancelled:
	case <-time.After(2 * time.Second):
		t.Fatal("cancellation lost")
	}
	<-done
	if len(g.active) != 0 || len(g.admitted) != 0 {
		t.Fatal("capacity leaked")
	}
}
~~~

<!-- file: gateway/internal/inference/reservation_test.go -->
~~~go
package inference

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func TestSharedReservationAcrossGatewaysAndFailClosed(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"river\"}}]}\n\ndata: [DONE]\n\n"))
	}))
	defer backend.Close()
	var mu sync.Mutex
	remaining := 12
	reserve := func(context.Context, string, int) (bool, error) {
		mu.Lock()
		defer mu.Unlock()
		if remaining < 12 {
			return false, nil
		}
		remaining -= 12
		return true, nil
	}
	a := New(backend.URL, identity, tokens, 1, 0, 100)
	b := New(backend.URL, identity, tokens, 1, 0, 100)
	a.UseReservation(reserve)
	b.UseReservation(reserve)
	if got := call(a, true).Code; got != 200 {
		t.Fatal(got)
	}
	if got := call(b, true).Code; got != 429 {
		t.Fatal(got)
	}
	b.UseReservation(func(context.Context, string, int) (bool, error) { return false, errors.New("unavailable") })
	if got := call(b, true).Code; got != 503 {
		t.Fatal(got)
	}
}
~~~

The telemetry hooks below are inert until Step 5 configures them. The stream observer keeps transport first byte separate from first nonempty content, requires the terminal event for successful completion, bounds SSE line buffering and uses authoritative usage rather than counting text chunks. A tokenizer transport failure is a backend error, not an invalid prompt.

<!-- file: gateway/internal/inference/observe.go -->
~~~go
package inference

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"
)

// Hooks are installed before serving. Names/outcomes are fixed strings; never
// pass prompts, credentials, answers or tenant identifiers to telemetry.
type Hooks struct {
	Stage  func(context.Context, string) (context.Context, func())
	Finish func(context.Context, string, time.Duration, time.Duration, int)
}

func (g *Gateway) UseHooks(h Hooks)                 { g.hooks = h }
func (g *Gateway) UseTransport(t http.RoundTripper) { g.client.Transport = t }
func (g *Gateway) InFlight() (active, admitted int) { return len(g.active), len(g.admitted) }
func (g *Gateway) stage(ctx context.Context, name string) (context.Context, func()) {
	if g.hooks.Stage != nil {
		return g.hooks.Stage(ctx, name)
	}
	return ctx, func() {}
}

type streamState struct {
	pending []byte
	first   time.Time
	done    bool
	tokens  int
}

func (s *streamState) accept(chunk []byte) error {
	s.pending = append(s.pending, chunk...)
	for {
		i := bytes.IndexByte(s.pending, '\n')
		if i < 0 {
			break
		}
		if i > 64<<10 {
			return errors.New("SSE line exceeds 64 KiB")
		}
		line := bytes.TrimSpace(s.pending[:i])
		s.pending = s.pending[i+1:]
		if !bytes.HasPrefix(line, []byte("data:")) {
			continue
		}
		data := bytes.TrimSpace(line[5:])
		if bytes.Equal(data, []byte("[DONE]")) {
			s.done = true
			continue
		}
		var event struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
			Usage *struct {
				Tokens int `json:"completion_tokens"`
			} `json:"usage"`
		}
		if err := json.Unmarshal(data, &event); err != nil {
			return err
		}
		if event.Usage != nil {
			s.tokens = event.Usage.Tokens
		}
		if len(event.Choices) > 0 && event.Choices[0].Delta.Content != "" && s.first.IsZero() {
			s.first = time.Now()
		}
	}
	if len(s.pending) > 64<<10 {
		return errors.New("SSE line exceeds 64 KiB")
	}
	return nil
}
~~~

<!-- file: gateway/internal/inference/observe_test.go -->
~~~go
package inference

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestContentTimingAndIncompleteStreams(t *testing.T) {
	for _, complete := range []bool{false, true} {
		t.Run(map[bool]string{false: "truncated", true: "complete"}[complete], func(t *testing.T) {
			backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				w.Write([]byte("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n"))
				http.NewResponseController(w).Flush()
				time.Sleep(80 * time.Millisecond)
				w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"river\"}}]}\n\n"))
				if complete {
					w.Write([]byte("data: {\"choices\":[],\"usage\":{\"completion_tokens\":1}}\n\ndata: [DONE]\n\n"))
				}
			}))
			defer backend.Close()
			g := New(backend.URL, identity, tokens, 1, 1, 100)
			var outcome string
			var first time.Duration
			var usage int
			g.UseHooks(Hooks{Finish: func(_ context.Context, o string, f, q time.Duration, n int) { outcome = o; first = f; usage = n }})
			if got := call(g, true).Code; got != 200 {
				t.Fatal(got)
			}
			if first < 70*time.Millisecond {
				t.Fatalf("role event incorrectly counted as first content: %v", first)
			}
			if complete && (outcome != "complete" || usage != 1) {
				t.Fatalf("%s tokens=%d", outcome, usage)
			}
			if !complete && outcome != "incomplete" {
				t.Fatalf("truncated stream counted as %s", outcome)
			}
		})
	}
}
~~~

<!-- run: cd gateway && gofmt -w internal && go vet ./... && go test -race -timeout=30s -count=1 ./... -->

Mount the package on the Phase 6 API's mux where its verifier `v` and logger already exist. This integration fragment belongs in your existing startup function (it is not a second standalone program):

~~~go
modelURL := "http://llm:8080"
g := inference.New(modelURL, func(r *http.Request) (string, bool) {
    c, ok := auth.FromContext(r.Context())
    return c.Tenant, ok
}, inference.LlamaTokenizer(modelURL), 1, 8, 8192)
mux.Handle("/v1/chat/completions", auth.Require(v, logger, g))
mux.HandleFunc("/internal/inference/metrics", g.Metrics)
~~~

Import `runway/internal/inference` and `runway/internal/auth`. Put metrics on the existing internal listener or protect them with the existing network policy. The model URL is operator configuration, never request data. TLS, JWT verification and tenant resolution stay in Switchyard. Confirm `/apply-template` and `/tokenize` against the pinned server before enabling the route; a changed template is a new deployment artifact. Backend context rejection is safe but does not prove your accounting is exact.

## Shared reservations in the existing Switchyard module

The phase-6 request bucket charges one request at a time; calling it once does not reserve an arbitrary number of model tokens. Keep its atomic Redis approach, but use a weighted reservation that charges prompt plus maximum output in one operation. The server clock defines the minute, tenant keys are isolated, and Redis failure returns 503 rather than silently multiplying capacity through local fallback.

These next two files are integration material. Copy them into `internal/inference` in your existing `runway` checkout, alongside the gateway package. The standalone `gateway` module deliberately has no Redis or JWT dependency. The live test reuses Phase 6's actual EdDSA JWT verifier and the real model server, not a replacement authentication scheme.

<!-- file: runway-integration/shared.go -->
~~~go
package inference

import (
	"context"
	"crypto/sha256"
	"fmt"
	"github.com/redis/go-redis/v9"
	"time"
)

// The Redis clock and the weighted reservation are evaluated in one operation.
// An unavailable shared ledger fails closed; conservative reservations are not refunded.
var reservationScript = redis.NewScript(`
local minute = math.floor(tonumber(redis.call('TIME')[1]) / 60)
local row = redis.call('HMGET', KEYS[1], 'minute', 'used')
local used = 0
if tonumber(row[1]) == minute then used = tonumber(row[2]) or 0 end
local cost, budget = tonumber(ARGV[1]), tonumber(ARGV[2])
if cost < 1 or cost > budget or used + cost > budget then return 0 end
redis.call('HSET', KEYS[1], 'minute', minute, 'used', used + cost)
redis.call('PEXPIRE', KEYS[1], 120000)
return 1
`)

// SharedReservation belongs in the existing runway module, which already has
// the Redis driver. It is deliberately not part of the stdlib-only lab module.
func SharedReservation(client redis.UniversalClient, prefix string, budget int) Reservation {
	if budget < 1 {
		panic("invalid shared budget")
	}
	return func(ctx context.Context, tenant string, cost int) (bool, error) {
		ctx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
		defer cancel()
		key := fmt.Sprintf("%s:%x", prefix, sha256.Sum256([]byte(tenant)))
		result, err := reservationScript.Run(ctx, client, []string{key}, cost, budget).Int()
		return result == 1, err
	}
}
~~~

<!-- file: runway-integration/live_test.go -->
~~~go
package inference_test

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/redis/go-redis/v9"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"runway/internal/auth"
	"runway/internal/inference"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestLiveRunwayJWTTokenizerAndSharedBudget(t *testing.T) {
	upstream, addr := os.Getenv("PHASE8_MODEL_URL"), os.Getenv("PHASE8_REDIS_ADDR")
	if upstream == "" || addr == "" {
		t.Skip("live model and Redis required")
	}
	client := redis.NewClient(&redis.Options{Addr: addr})
	defer client.Close()
	ctx := context.Background()
	if err := client.Ping(ctx).Err(); err != nil {
		t.Fatal(err)
	}
	messages := json.RawMessage(`[{"role":"user","content":"Reply with the word river only."}]`)
	tokenize := inference.LlamaTokenizer(upstream)
	count, err := tokenize(ctx, messages)
	if err != nil {
		t.Fatal(err)
	}
	if count < 1 {
		t.Fatal("missing prompt tokens")
	}
	key, err := auth.NewSigningKey(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	verifier := auth.Verifier{Issuer: "phase8-lab", Audience: "runway", Keys: auth.StaticKeys(auth.JWKS{Keys: []auth.JWK{key.Public()}})}
	issue := func(tenant string) string {
		token, err := auth.Sign(auth.Claims{Issuer: "phase8-lab", Audience: auth.Audience{"runway"}, Expiry: time.Now().Add(time.Hour).Unix(), Tenant: tenant}, key)
		if err != nil {
			t.Fatal(err)
		}
		return token
	}
	prefix := fmt.Sprintf("phase8:test:%d", time.Now().UnixNano())
	var servers []*httptest.Server
	for range 2 {
		g := inference.New(upstream, func(r *http.Request) (string, bool) { c, ok := auth.FromContext(r.Context()); return c.Tenant, ok }, tokenize, 1, 4, count+8)
		g.UseReservation(inference.SharedReservation(client, prefix, count+8))
		servers = append(servers, httptest.NewServer(auth.Require(verifier, slog.New(slog.NewTextHandler(io.Discard, nil)), g)))
	}
	defer func() {
		for _, server := range servers {
			server.Close()
		}
	}()
	call := func(server int, token string) (int, string) {
		req, err := http.NewRequest("POST", servers[server].URL, strings.NewReader(`{"messages":`+string(messages)+`,"max_tokens":8,"stream":true}`))
		if err != nil {
			t.Fatal(err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		req.Header.Set("X-Tenant", "another-tenant")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, err := io.ReadAll(res.Body)
		if err != nil {
			t.Fatal(err)
		}
		return res.StatusCode, string(body)
	}
	if code, _ := call(0, ""); code != 401 {
		t.Fatalf("unauthenticated: %d", code)
	}
	token := issue("acme")
	code, body := call(0, token)
	if code != 200 || !strings.Contains(body, "[DONE]") {
		t.Fatalf("completion: %d %s", code, body)
	}
	promptUsage := -1
	for _, line := range strings.Split(body, "\n") {
		var event struct {
			Usage *struct {
				PromptTokens int `json:"prompt_tokens"`
			} `json:"usage"`
		}
		if strings.HasPrefix(line, "data: ") && json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event) == nil && event.Usage != nil {
			promptUsage = event.Usage.PromptTokens
		}
	}
	if promptUsage != count {
		t.Fatalf("template/tokenizer mismatch: reserved %d, backend used %d", count, promptUsage)
	}
	if code, _ := call(1, token); code != 429 {
		t.Fatalf("replica bypass: %d", code)
	}
	if code, _ := call(1, issue("hooli")); code != 200 {
		t.Fatalf("tenant budget leaked: %d", code)
	}
	reserve := inference.SharedReservation(client, prefix+":concurrent", 8)
	var wg sync.WaitGroup
	var allowed atomic.Int64
	for range 20 {
		wg.Go(func() {
			ok, err := reserve(ctx, "acme", 1)
			if err != nil {
				t.Error(err)
			}
			if ok {
				allowed.Add(1)
			}
		})
	}
	wg.Wait()
	if allowed.Load() != 8 {
		t.Fatalf("atomic budget: %d", allowed.Load())
	}
	t.Logf("verified JWT auth, real prompt tokenization (%d tokens), streamed completion, two gateways sharing one tenant budget, separate tenant budgets and 20 concurrent reservations", count)
}
~~~

Mount the route as above, then configure it before serving:

~~~go
g.UseReservation(inference.SharedReservation(redisClient, "runway:inference", 8192))
~~~

Here `redisClient` is the existing Redis client from Switchyard's startup. All replicas must share its authoritative service and budget configuration. This is conservative fixed-minute accounting, not durable billing; a minute boundary permits a burst. Neither shared accounting nor a semaphore establishes tenant scheduling fairness.

~~~bash
# In the existing Runway checkout, with a local model and Redis running:
PHASE8_MODEL_URL=http://127.0.0.1:18080 PHASE8_REDIS_ADDR=127.0.0.1:16379 \
  go test -race -timeout=60s -run TestLiveRunwayJWTTokenizerAndSharedBudget -v ./internal/inference
~~~

The test checks that the real tokenizer/template reservation exactly matches backend prompt usage, completion, unauthenticated rejection, two gateways sharing one tenant budget, separate budgets for another tenant, and twenty concurrent weighted reservations. Ephemeral signing keys/tokens remain in test memory. It does not establish cluster deployment, GPU cancellation or complete API startup integration.

**Run it:** export Phase 6's acme bearer token as `RUNWAY_TOKEN`, point the load client at Switchyard's local tunnel instead of the raw server, and stream a request, then remove the bearer token (401), exceed the reservation budget (429), exceed admission capacity (503 with Retry-After), and disconnect while generating. The upstream slot must return to idle, not merely the Go channel. The unit test proves HTTP cancellation propagation; the real server experiment proves whether the backend honours it. Keep that distinction in the report.

**Break it:** replace the request context with `context.Background()`. The disconnect test must fail. Restore it. Predict what happens if a tenant opens all admitted requests: this semaphore is bounded but does not provide tenant fairness. Apply Phase 6's per-tenant admission limits before exposing it to mutually untrusted tenants.
