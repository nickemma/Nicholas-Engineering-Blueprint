# 02 Reach a service by name

## The problem

A replacement Pod gets a new address. Clients need stable service discovery, and a candidate waiting on readiness should stay out of regular traffic.

## The mental model

~~~text
entry Service -> entry HTTP router -> stable frontend Service -> jobs Service
                                  \-> canary frontend Service -> same jobs Service
worker Deployment ------------------------------------------------> jobs gRPC
~~~

The two frontends share one durable coordinator. That keeps release traffic separate while avoiding two Core 03 coordinator processes recovering the same running jobs. The route prefix `/candidate/` selects the canary. The fixed upstreams come from configuration.

## Build it

### Step 1. Route external and internal hops

Build a small layer-7 proxy with distinct health endpoints. The tracer and metrics hooks are included now so request routing can stay the same when the collector arrives.

<details>
<summary>Hint</summary>

Strip the canary prefix. Give each proxied request a deadline and tag outcomes by the chosen track.

</details>

<details>
<summary>Type-along files</summary>

Create `delivery/go.mod`.

<!-- file: delivery/go.mod -->
~~~text
module switchyard/delivery

go 1.26
~~~

Create `delivery/internal/telemetry/trace.go`.

<!-- file: delivery/internal/telemetry/trace.go -->
~~~go
// Package telemetry exports a bounded stream of lab spans over OTLP/HTTP.
package telemetry

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"
)

type Span struct {
	TraceID      string `json:"traceId"`
	SpanID       string `json:"spanId"`
	ParentSpanID string `json:"parentSpanId,omitempty"`
	Name         string `json:"name"`
	Begin        int64  `json:"startTimeUnixNano,string"`
	End          int64  `json:"endTimeUnixNano,string"`
}

func validID(id string, width int) bool {
	data, err := hex.DecodeString(id)
	return err == nil && len(data) == width && id == strings.ToLower(id) &&
		strings.Trim(id, "0") != ""
}

func Begin(parent, name string, now time.Time) Span {
	s := Span{Name: name, Begin: now.UnixNano(), SpanID: hex.EncodeToString(randBytes(8))}
	parts := strings.Split(parent, "-")
	if len(parts) == 4 && parts[0] == "00" && validID(parts[1], 16) &&
		validID(parts[2], 8) && len(parts[3]) == 2 {
		s.TraceID, s.ParentSpanID = parts[1], parts[2]
	} else {
		s.TraceID = hex.EncodeToString(randBytes(16))
	}
	return s
}

func randBytes(count int) []byte {
	data := make([]byte, count)
	rand.Read(data)
	return data
}

func (s Span) Header() string { return "00-" + s.TraceID + "-" + s.SpanID + "-01" }

type Reporter struct {
	queue chan Span
}

func New(ctx context.Context, endpoint, service string) *Reporter {
	r := &Reporter{}
	if endpoint == "" {
		return r
	}
	r.queue = make(chan Span, 64)
	go r.report(ctx, endpoint, service)
	return r
}

func (r *Reporter) End(s Span) {
	s.End = time.Now().UnixNano()
	select {
	case r.queue <- s:
	default: // Telemetry backpressure cannot stall the jobs path.
	}
}

type scope struct {
	Spans []Span `json:"spans"`
}
type resource struct {
	Resource map[string]any `json:"resource"`
	Scopes   []scope        `json:"scopeSpans"`
}
type envelope struct {
	Resources []resource `json:"resourceSpans"`
}

func (r *Reporter) report(ctx context.Context, endpoint, name string) {
	client := &http.Client{Timeout: 350 * time.Millisecond}
	service := map[string]any{"attributes": []map[string]any{
		{"key": "service.name", "value": map[string]string{"stringValue": name}},
	}}
	for {
		select {
		case <-ctx.Done():
			return
		case s := <-r.queue:
			body, err := json.Marshal(envelope{[]resource{{service, []scope{{[]Span{s}}}}}})
			if err != nil {
				continue
			}
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
			if err != nil {
				continue
			}
			req.Header.Set("Content-Type", "application/json")
			res, err := client.Do(req)
			if err == nil {
				io.Copy(io.Discard, io.LimitReader(res.Body, 4096))
				res.Body.Close()
			}
		}
	}
}
~~~

Create `delivery/cmd/frontend/main.go`.

<!-- file: delivery/cmd/frontend/main.go -->
~~~go
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"switchyard/delivery/internal/telemetry"
)

type sample struct{ good, bad atomic.Uint64 }

type recorder struct {
	http.ResponseWriter
	status int
}

func (r *recorder) WriteHeader(code int) {
	if r.status == 0 {
		r.status = code
	}
	r.ResponseWriter.WriteHeader(code)
}
func (r *recorder) Write(p []byte) (int, error) {
	if r.status == 0 {
		r.status = http.StatusOK
	}
	return r.ResponseWriter.Write(p)
}
func (r *recorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

func proxy(target *url.URL, transport http.RoundTripper) http.Handler {
	return &httputil.ReverseProxy{
		Rewrite:   func(r *httputil.ProxyRequest) { r.SetURL(target); r.SetXForwarded() },
		Transport: transport,
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
			http.Error(w, "upstream unavailable", http.StatusServiceUnavailable)
		},
	}
}

func tracked(h http.Handler, name string, stats *sample, spans *telemetry.Reporter) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		span := telemetry.Begin(r.Header.Get("traceparent"), name, time.Now())
		r = r.Clone(ctx)
		r.Header.Set("traceparent", span.Header())
		w.Header().Set("X-Lab-Trace", span.TraceID)
		re := &recorder{ResponseWriter: w}
		h.ServeHTTP(re, r)
		if re.status >= 200 && re.status < 400 {
			stats.good.Add(1)
		} else {
			stats.bad.Add(1)
		}
		spans.End(span)
	})
}

func handler(upstream *url.URL, candidate *url.URL, fail bool, delay time.Duration,
	name string, spans *telemetry.Reporter, transport http.RoundTripper) http.Handler {
	mux := http.NewServeMux()
	stableStats, candidateStats := &sample{}, &sample{}
	readyAt := time.Now().Add(delay)
	mux.HandleFunc("GET /live", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("GET /ready", func(w http.ResponseWriter, _ *http.Request) {
		if fail || time.Now().Before(readyAt) {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		fmt.Fprintln(w, "# TYPE delivery_attempts_total counter")
		for _, row := range []struct {
			track string
			count *sample
		}{
			{"stable", stableStats}, {"canary", candidateStats},
		} {
			fmt.Fprintf(w, "delivery_attempts_total{track=%q,result=\"good\"} %d\n", row.track, row.count.good.Load())
			fmt.Fprintf(w, "delivery_attempts_total{track=%q,result=\"bad\"} %d\n", row.track, row.count.bad.Load())
		}
	})
	mux.Handle("/", tracked(proxy(upstream, transport), name, stableStats, spans))
	if candidate != nil {
		mux.Handle("/candidate/", http.StripPrefix("/candidate",
			tracked(proxy(candidate, transport), name, candidateStats, spans)))
	}
	return mux
}

func upstream(raw string) *url.URL {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" || u.Hostname() == "" || u.User != nil {
		log.Fatal("upstream must be a configured HTTP service")
	}
	return u
}

func main() {
	listen := flag.String("listen", ":8080", "listener")
	target := flag.String("upstream", "", "stable service URL")
	candidate := flag.String("candidate", "", "candidate service URL")
	otlp := flag.String("otlp", "", "collector HTTP traces endpoint")
	delay := flag.Duration("startup-delay", 0, "delay before readiness")
	fail := flag.Bool("fail-ready", false, "lab fixture: readiness never succeeds")
	name := flag.String("name", "jobs-frontend", "span service name")
	flag.Parse()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var other *url.URL
	if *candidate != "" {
		other = upstream(*candidate)
	}
	server := &http.Server{Addr: *listen,
		Handler: handler(upstream(*target), other, *fail, *delay, *name, telemetry.New(ctx, *otlp, *name),
			&http.Transport{ResponseHeaderTimeout: 2 * time.Second, IdleConnTimeout: 30 * time.Second}),
		ReadTimeout: 4 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 15 * time.Second,
	}
	go func() {
		<-ctx.Done()
		drain, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		server.Shutdown(drain)
	}()
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
~~~

Create `delivery/cmd/frontend/main_test.go`.

<!-- file: delivery/cmd/frontend/main_test.go -->
~~~go
package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"switchyard/delivery/internal/telemetry"
)

type fakeTransport func(*http.Request) (*http.Response, error)

func (f fakeTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestLabReadinessAndReleaseCounters(t *testing.T) {
	transport := fakeTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/jobs/1" || r.Header.Get("traceparent") == "" {
			t.Error(r.URL, r.Header)
		}
		code := 200
		if r.URL.Host == "canary" {
			code = 503
		}
		return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader("")), Header: http.Header{}}, nil
	})
	a, _ := url.Parse("http://stable")
	b, _ := url.Parse("http://canary")
	h := handler(a, b, true, 0, "entry", telemetry.New(context.Background(), "", "entry"), transport)
	for path, expected := range map[string]int{"/live": 200, "/ready": 503, "/jobs/1": 200, "/candidate/jobs/1": 503} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		if w.Code != expected {
			t.Fatalf("%s = %d", path, w.Code)
		}
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/metrics", nil))
	for _, label := range []string{`track="stable",result="good"} 1`, `track="canary",result="bad"} 1`} {
		if !strings.Contains(w.Body.String(), label) {
			t.Fatal(w.Body.String())
		}
	}
	t.Log("failed readiness stayed live; stable and canary request outcomes were counted separately")
}
~~~

</details>
### Step 2. Bind stable, candidate, and entry Services

Each Service should select only its own frontend Deployment. Make the canary replace its former Pod before evaluating the new one. Keep the stable frontend rolling strategy.

<details>
<summary>Hint</summary>

If the old canary remains serving, its successful responses hide an unready candidate.

</details>

<details>
<summary>Type-along files</summary>

Create `chart/templates/frontend.yaml`.

<!-- file: chart/templates/frontend.yaml -->
~~~yaml
{{- range $name := list "stable" "canary" "entry" }}
{{- $label := printf "frontend-%s" $name }}
{{- $image := $.Values.image }}
{{- if eq $name "stable" }}{{ $image = default $image $.Values.stableImage }}{{ end }}
{{- if eq $name "canary" }}{{ $image = default $image $.Values.canaryImage }}{{ end }}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: {{ $label }}}
spec:
  replicas: {{ if eq $name "stable" }}2{{ else }}1{{ end }}
  minReadySeconds: 1
  {{- if eq $name "canary" }}
  strategy: {type: Recreate}
  {{- end }}
  selector: {matchLabels: {app: {{ $label }}}}
  template:
    metadata: {labels: {app: {{ $label }}}}
    spec:
      automountServiceAccountToken: false
      securityContext: {{- include "delivery.podSecurity" $ | nindent 8 }}
      containers:
      - name: frontend
        image: {{ $image | quote }}
        imagePullPolicy: IfNotPresent
        securityContext: {{- include "delivery.security" $ | nindent 10 }}
        command: [/app/frontend]
        args:
        - {{ printf "-name=%s" $label | quote }}
        {{- if eq $name "entry" }}
        - "-upstream=http://frontend-stable:8080"
        - "-candidate=http://frontend-canary:8080"
        {{- else }}
        - "-upstream=http://jobs:8080"
        - {{ printf "-startup-delay=%s" $.Values.frontendStartupDelay | quote }}
        {{- end }}
        {{- if and (eq $name "canary") $.Values.canaryFault }}
        - "-fail-ready"
        {{- end }}
        {{- if $.Values.observability.enabled }}
        - "-otlp=http://collector:4318/v1/traces"
        {{- end }}
        ports: [{name: http, containerPort: 8080}]
        startupProbe:
          httpGet: {path: /live, port: http}
          failureThreshold: 15
          periodSeconds: 2
        readinessProbe:
          httpGet: {path: /ready, port: http}
          periodSeconds: 2
        livenessProbe:
          httpGet: {path: /live, port: http}
          periodSeconds: 5
        resources:
          requests: {cpu: 10m, memory: 16Mi}
          limits: {memory: 96Mi}
---
apiVersion: v1
kind: Service
metadata: {name: {{ $label }}}
spec:
  selector: {app: {{ $label }}}
  ports: [{name: http, port: 8080, targetPort: http}]
{{- end }}
~~~

</details>

## Check it

~~~bash
(cd delivery && go test -race -count=1 -v ./cmd/frontend)
~~~

<!-- run: (cd delivery && go test -race -count=1 -v ./cmd/frontend) -->

The fake transport check observes stable success, candidate refusal, and separate counters. [Captured Go checks](../evidence/unit-tests.txt)

## Run locally

Build the frontend stage with `bash ops/build-image.sh switchyard-delivery:frontend frontend` and load it into kind. Apply the chart with `--set image=switchyard-delivery:frontend` and `--set frontendStartupDelay=10s` to the step namespace. Watch `kubectl -n delivery-steps get pods -w` and inspect EndpointSlices with `kubectl -n delivery-steps get endpointslice -l kubernetes.io/service-name=frontend-stable`. A started process may report live while waiting to become ready. Use `kubectl -n delivery-steps port-forward svc/frontend-entry 18080:8080` and test `/health` and `/candidate/health` after startup. Service DNS keeps the upstream names stable across replacements.
