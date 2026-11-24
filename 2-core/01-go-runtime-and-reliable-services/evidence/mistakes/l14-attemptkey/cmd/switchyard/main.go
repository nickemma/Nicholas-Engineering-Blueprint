// Command switchyard runs Switchyard's control plane: an HTTP API plus a
// pool of workers that run jobs from an in-process queue.
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
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"switchyard/internal/chaos"
	"switchyard/internal/httpapi"
	"switchyard/internal/idempotency"
	"switchyard/internal/jobs"
	"switchyard/internal/ledger"
	"switchyard/internal/memstore"
	"switchyard/internal/queue"
	"switchyard/internal/retry"
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
	Workers        int
	QueueCapacity  int
	JobTimeout     time.Duration
	IdempotencyTTL time.Duration
	RetryAttempts  int
	FailRate       float64
}

func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{
		ListenAddr:     "127.0.0.1:8080",
		RequestTimeout: 2 * time.Second,
		ShutdownGrace:  10 * time.Second,
		Workers:        4,
		QueueCapacity:  100,
		JobTimeout:     10 * time.Second,
		IdempotencyTTL: 24 * time.Hour,
		RetryAttempts:  3,
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
	if cfg.JobTimeout, err = durationFromEnv(getenv, "JOB_TIMEOUT", cfg.JobTimeout); err != nil {
		return config{}, err
	}
	if cfg.Workers, err = positiveIntFromEnv(getenv, "WORKERS", cfg.Workers); err != nil {
		return config{}, err
	}
	if cfg.QueueCapacity, err = positiveIntFromEnv(getenv, "QUEUE_CAPACITY", cfg.QueueCapacity); err != nil {
		return config{}, err
	}
	if cfg.IdempotencyTTL, err = durationFromEnv(getenv, "IDEMPOTENCY_TTL", cfg.IdempotencyTTL); err != nil {
		return config{}, err
	}
	if cfg.RetryAttempts, err = positiveIntFromEnv(getenv, "RETRY_ATTEMPTS", cfg.RetryAttempts); err != nil {
		return config{}, err
	}
	if v := getenv("FAIL_RATE"); v != "" {
		rate, err := strconv.ParseFloat(v, 64)
		if err != nil || rate < 0 || rate >= 1 {
			return config{}, fmt.Errorf("FAIL_RATE must be a fraction from 0 up to (not including) 1, got %q", v)
		}
		cfg.FailRate = rate
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

func positiveIntFromEnv(getenv func(string) string, name string, fallback int) (int, error) {
	v := getenv(name)
	if v == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return 0, fmt.Errorf("%s must be a positive whole number, got %q", name, v)
	}
	return n, nil
}

// run starts the API and the workers, blocks until ctx is cancelled, then
// shuts both down gracefully.
func run(ctx context.Context, getenv func(string) string, stdout io.Writer, ready func(addr string)) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	metrics := httpapi.NewMetrics()

	// A job's work: wait for its duration, then record its effect in the
	// ledger, under a key that every attempt at this job shares.
	effects := ledger.New()
	attempts := prometheus.NewCounter(prometheus.CounterOpts{
		Name: "job_attempts_total",
		Help: "Attempts at a job's work, retries included.",
	})
	var jobWork jobs.WorkFunc = func(ctx context.Context, job jobs.Job) error {
		attempts.Inc()
		if err := jobs.Simulate(ctx, job); err != nil {
			return err
		}
		effects.Apply(fmt.Sprintf("job-%d-%d", job.ID, time.Now().UnixNano()), job.ID, time.Now().UTC())
		return nil
	}
	if cfg.FailRate > 0 {
		jobWork = chaos.LoseResults(jobWork, cfg.FailRate, rand.Float64)
	}
	metrics.MustRegister(attempts,
		prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "effects_applied_total",
			Help: "Job effects recorded in the ledger.",
		}, func() float64 { applied, _ := effects.Counts(); return float64(applied) }),
		prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "effects_duplicate_total",
			Help: "Repeated effects the ledger recognised and ignored.",
		}, func() float64 { _, duplicates := effects.Counts(); return float64(duplicates) }),
	)

	work := queue.New(cfg.QueueCapacity)
	service := jobs.NewService(memstore.New(),
		jobs.WithDispatcher(work),
		jobs.WithWork(jobWork),
		jobs.WithRetry(retry.Policy{Attempts: cfg.RetryAttempts, Base: 100 * time.Millisecond, Max: 2 * time.Second}),
	)
	metrics.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "jobs_queue_depth",
		Help: "Jobs waiting for a worker.",
	}, func() float64 { return float64(work.Len()) }))

	keys := idempotency.NewStore(cfg.IdempotencyTTL, time.Now)
	metrics.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "idempotency_keys",
		Help: "Idempotency keys currently remembered.",
	}, func() float64 { return float64(keys.Len()) }))

	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
		httpapi.WithIdempotency(keys),
	)
	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      cfg.RequestTimeout + 5*time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Two contexts control the workers. Cancelling stopTaking makes them
	// stop picking up new jobs. Cancelling stopRunning interrupts the jobs
	// they are running; that only happens if the grace period runs out.
	stopTaking, cancelTaking := context.WithCancel(context.Background())
	defer cancelTaking()
	stopRunning, cancelRunning := context.WithCancel(context.Background())
	defer cancelRunning()

	runJob := func(id jobs.ID) {
		jobCtx, cancel := context.WithTimeout(stopRunning, cfg.JobTimeout)
		defer cancel()
		job, err := service.Run(jobCtx, id)
		logger.Info("job finished", "job_id", id, "state", job.State, "error", errText(err))
	}
	workersDone := make(chan struct{})
	go func() {
		work.Serve(stopTaking, cfg.Workers, runJob)
		close(workersDone)
	}()

	// A background job: forget expired idempotency keys once a minute,
	// until the service starts shutting down.
	go func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if removed := keys.Sweep(); removed > 0 {
					logger.Info("swept idempotency keys", "removed", removed)
				}
			}
		}
	}()

	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}
	logger.Info("listening", "addr", listener.Addr().String(), "workers", cfg.Workers)
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

	logger.Info("shutting down", "grace", cfg.ShutdownGrace.String())
	deadline := time.Now().Add(cfg.ShutdownGrace)
	shutdownCtx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()

	// 1. Stop accepting requests, so no new jobs arrive.
	if err := server.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return err
	}

	// 2. Let workers finish the jobs they hold, until the grace period ends.
	cancelTaking()
	select {
	case <-workersDone:
	case <-shutdownCtx.Done():
		// 3. Out of time: interrupt the running jobs. They are recorded
		// as failed with reason "cancelled", never left "running".
		logger.Warn("grace period over; cancelling running jobs")
		cancelRunning()
		<-workersDone
	}
	logger.Info("stopped", "jobs_left_in_queue", work.Len())
	return nil
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
