# 05 Observe the user contract

The gateway exports active and admitted gauges, attempts, transport failures and first-byte diagnostics. A role-only SSE event may arrive before any text, so **first byte is not TTFT**. The synthetic client measures first nonempty content; use its raw rows for the user-facing objective. An EOF that lacks `[DONE]` is a failure in that objective even when HTTP is 200.

Write the objective before measuring: for this lab, at least 99% of offered valid requests should complete and receive their first content within 1 second, measured over a fixed workload and window. This is a chosen target, not a measured achievement. Rejections, timeouts and incomplete streams consume that budget. Keep success-only latency plots as diagnostics, alongside this all-arrivals denominator.

Scrape `/internal/inference/metrics` on the internal listener. Plot admitted minus active as waiting, active versus slots, rejection responses from Switchyard's existing HTTP metrics, backend token throughput and process RSS. A useful symptom is sustained waiting plus a falling share of good requests. CPU utilisation alone misses a memory-bandwidth-bound decoder.

For traces, keep Switchyard's existing instrumentation (Core 06 and Kubernetes and delivery): start at the authenticated API, add queue wait, template/tokenizer calls and upstream streaming spans; end the stream span only on the terminal event, EOF, cancellation or failure. Propagate the existing trace context via the instrumented HTTP transport. Never record prompts, bearer tokens, model answers or tenant IDs as unbounded metric labels. Compare the client TTFT with queue wait plus backend prefill plus network delay.

**Break it:** introduce a 2-second delay before the fake server's first content, while sending its role event immediately. Show that first-byte diagnostics can pass while the TTFT objective fails. Disable buffering at every proxy and verify with a timestamped client; a fast backend behind a buffering proxy still feels slow.

## Mount the real API and record first-content evidence

The earlier route fragment explains the boundary; this adapter connects it to the real Switchyard `cmd/api` process. Copy the following file to `cmd/api/inference.go` in your Switchyard checkout, alongside the gateway and shared-reservation files already copied into `internal/inference`. It reuses Switchyard's JWT middleware, metric registry, trace provider and identity claims. The separate `generator` role (or `admin`) authorises generation; a job reader does not gain inference access merely by having a valid JWT.

The streaming route stays outside the jobs request-deadline middleware. Jobs retain their original write deadline; inference has a thirty-second admission/stream deadline and a per-write slow-consumer deadline. The server's outer write allowance accommodates that contract. Redis reservations fail closed across API instances; the adapter refuses to enable inference with authentication disabled.

<!-- file: switchyard-integration/api_inference.go -->
~~~go
package main

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"switchyard/internal/auth"
	"switchyard/internal/authz"
	"switchyard/internal/envconfig"
	"switchyard/internal/httpapi"
	"switchyard/internal/inference"
)

// mountInference extends the actual API composition root. Jobs retain their
// middleware/deadline; streaming has its own thirty-second admission deadline.
func mountInference(getenv envconfig.Getenv, metrics *httpapi.Metrics, authenticate func(http.Handler) http.Handler, jobs http.Handler, jobWriteTimeout time.Duration) (http.Handler, func(), error) {
	url := getenv("INFERENCE_UPSTREAM")
	if url == "" {
		return jobs, func() {}, nil
	}
	if getenv("AUTH_MODE") == "off" {
		return nil, nil, errors.New("inference requires JWT authentication")
	}
	addr := getenv("INFERENCE_REDIS_ADDR")
	if addr == "" {
		return nil, nil, errors.New("INFERENCE_REDIS_ADDR is required; shared accounting fails closed")
	}
	slots, err := envconfig.PositiveInt(getenv, "INFERENCE_SLOTS", 1)
	if err != nil {
		return nil, nil, err
	}
	queue, err := envconfig.PositiveInt(getenv, "INFERENCE_QUEUE", 8)
	if err != nil {
		return nil, nil, err
	}
	budget, err := envconfig.PositiveInt(getenv, "INFERENCE_TOKEN_BUDGET", 8192)
	if err != nil {
		return nil, nil, err
	}
	client := redis.NewClient(&redis.Options{Addr: addr})
	transport := otelhttp.NewTransport(http.DefaultTransport)
	g := inference.New(url, func(r *http.Request) (string, bool) { c, ok := auth.FromContext(r.Context()); return c.Tenant, ok }, inference.LlamaTokenizerWithClient(url, &http.Client{Transport: transport}), slots, queue, budget)
	g.UseReservation(inference.SharedReservation(client, "switchyard:inference:v1", budget))
	g.UseTransport(transport)
	outcomes := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "inference_outcomes_total", Help: "Authenticated generation outcomes, including rejections and incomplete streams."}, []string{"outcome"})
	good := prometheus.NewCounter(prometheus.CounterOpts{Name: "inference_good_total", Help: "Completed requests with first content observed at the gateway within one second."})
	ttft := prometheus.NewHistogram(prometheus.HistogramOpts{Name: "inference_first_content_seconds", Help: "First content at the gateway, not transport first byte; missing content excluded.", Buckets: []float64{.05, .1, .25, .5, 1, 2, 5, 10, 30}})
	waiting := prometheus.NewHistogram(prometheus.HistogramOpts{Name: "inference_queue_seconds", Help: "Time spent waiting for generation capacity.", Buckets: []float64{.001, .01, .05, .1, .25, .5, 1, 2, 5, 10, 30}})
	tokens := prometheus.NewCounter(prometheus.CounterOpts{Name: "inference_output_tokens_total", Help: "Authoritative completed output-token usage, when supplied."})
	statuses := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "inference_http_total", Help: "Generation HTTP responses including authentication and authorization failures."}, []string{"code"})
	metrics.MustRegister(outcomes, good, ttft, waiting, tokens, statuses,
		prometheus.NewGaugeFunc(prometheus.GaugeOpts{Name: "inference_active", Help: "Active inference requests."}, func() float64 { a, _ := g.InFlight(); return float64(a) }),
		prometheus.NewGaugeFunc(prometheus.GaugeOpts{Name: "inference_waiting", Help: "Admitted requests waiting for active capacity."}, func() float64 { a, n := g.InFlight(); return float64(max(0, n-a)) }))
	tracer := otel.Tracer("switchyard.inference")
	g.UseHooks(inference.Hooks{
		Stage: func(ctx context.Context, name string) (context.Context, func()) {
			ctx, span := tracer.Start(ctx, name)
			return ctx, func() { span.End() }
		},
		Finish: func(ctx context.Context, outcome string, first, queue time.Duration, n int) {
			outcomes.WithLabelValues(outcome).Inc()
			waiting.Observe(queue.Seconds())
			if first >= 0 {
				ttft.Observe(first.Seconds())
			}
			if outcome == "complete" && first >= 0 && first <= time.Second {
				good.Inc()
			}
			if outcome == "complete" && n >= 0 {
				tokens.Add(float64(n))
			}
			span := trace.SpanFromContext(ctx)
			span.SetAttributes(attribute.String("inference.outcome", outcome), attribute.Int64("inference.queue_ms", queue.Milliseconds()))
			if first >= 0 {
				span.SetAttributes(attribute.Int64("inference.first_content_ms", first.Milliseconds()))
			}
		},
	})
	action := authz.Action("inference.generate")
	policy := authz.Policy{"generator": {action}, "admin": {action}}
	allowed := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !policy.Decide(r.Context(), action).Allow {
			http.Error(w, "permission denied", 403)
			return
		}
		g.ServeHTTP(w, r)
	})
	protected := authenticate(allowed)
	mux := http.NewServeMux()
	mux.Handle("POST /v1/chat/completions", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		recorder := &inferenceStatus{ResponseWriter: w}
		protected.ServeHTTP(recorder, r)
		code := recorder.code
		if code == 0 {
			code = 200
		}
		statuses.WithLabelValues(strconv.Itoa(code)).Inc()
	}))
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(jobWriteTimeout))
		jobs.ServeHTTP(w, r)
	}))
	return mux, func() { _ = client.Close() }, nil
}

type inferenceStatus struct {
	http.ResponseWriter
	code int
}

func (w *inferenceStatus) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *inferenceStatus) WriteHeader(code int) {
	if w.code == 0 {
		w.code = code
	}
	w.ResponseWriter.WriteHeader(code)
}
func (w *inferenceStatus) Write(b []byte) (int, error) {
	if w.code == 0 {
		w.code = 200
	}
	return w.ResponseWriter.Write(b)
}
~~~

In your existing `cmd/api/main.go`, replace the block beginning at `handler := httpapi.NewHandler(service, options...)` through the following `server := &http.Server{` with:

~~~go
handler := httpapi.NewHandler(service, options...)
handler, closeInference, err := mountInference(getenv, metrics, authenticate, handler, cfg.RequestTimeout+5*time.Second)
if err != nil { return err }
defer closeInference()
writeTimeout := cfg.RequestTimeout + 5*time.Second
if getenv("INFERENCE_UPSTREAM") != "" { writeTimeout = 35*time.Second }
server := &http.Server{
~~~

Set that server's existing `WriteTimeout` field to `writeTimeout`. All other startup/shutdown, TLS, workers, persistence and gRPC wiring stays in the existing composition root. This integration source depends on your Switchyard module; the stdlib-only gateway replay does not pretend to compile the entire API or deploy telemetry.

Configure `INFERENCE_UPSTREAM`, `INFERENCE_REDIS_ADDR`, `INFERENCE_SLOTS`, `INFERENCE_QUEUE` and `INFERENCE_TOKEN_BUDGET` on the API process. Keep the raw model and Redis endpoints private. Register a synthetic issuer client with `generator+submitter+reader`, and another with only `reader` for the denial test. Never put their secrets or bearer tokens in committed commands/evidence.

Scrape Switchyard's existing `/metrics`: `inference_outcomes_total` retains overload, limited, backend, cancellation and incomplete outcomes; `inference_good_total` counts only completed requests whose first content is observed at the gateway within one second. `inference_first_content_seconds` is a latency diagnostic, not a success-only SLO denominator. `inference_waiting` and `inference_active` expose approximate admission state; waiting is clamped at zero because channel lengths are sampled separately; output tokens come from usage. Use the client measurements for user-visible transport latency.

Send the existing API OTLP exporter to a real collector and inspect `inference.queue`, `inference.tokenize`, `inference.reserve` and `inference.backend_stream` plus the enclosing HTTP span. The instrumented tokenizer/upstream HTTP clients propagate trace context. None of these hooks records prompts, answers, tenant identifiers or credentials as span attributes/metric labels.

The [platform validation report](../evidence/platform-validation/report.md) records the running environment, observed outcomes and retained live checks. A local in-memory jobs mode can verify real API startup/routing without asserting that database/broker production operation was revalidated.
