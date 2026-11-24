// Command switchyard runs Switchyard's control plane: an HTTP API and a gRPC
// API for jobs, and a gRPC API through which worker processes take jobs on
// leases and report back. It does no work itself.
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
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"

	"switchyard/internal/coord"
	"switchyard/internal/grpcapi"
	"switchyard/internal/grpcapi/jobsv1"
	"switchyard/internal/grpcapi/workersv1"
	"switchyard/internal/httpapi"
	"switchyard/internal/idempotency"
	"switchyard/internal/jobs"
	"switchyard/internal/ledger"
	"switchyard/internal/memstore"
	"switchyard/internal/queue"
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
	GRPCAddr       string
	RequestTimeout time.Duration
	ShutdownGrace  time.Duration
	QueueCapacity  int
	IdempotencyTTL time.Duration
	LeaseTTL       time.Duration
}

func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{
		ListenAddr:     "127.0.0.1:8080",
		GRPCAddr:       "127.0.0.1:9090",
		RequestTimeout: 2 * time.Second,
		ShutdownGrace:  10 * time.Second,
		QueueCapacity:  100,
		IdempotencyTTL: 24 * time.Hour,
		LeaseTTL:       3 * time.Second,
	}
	var err error
	if cfg.ListenAddr, err = hostPortFromEnv(getenv, "LISTEN_ADDR", cfg.ListenAddr); err != nil {
		return config{}, err
	}
	if cfg.GRPCAddr, err = hostPortFromEnv(getenv, "GRPC_ADDR", cfg.GRPCAddr); err != nil {
		return config{}, err
	}
	if cfg.RequestTimeout, err = durationFromEnv(getenv, "REQUEST_TIMEOUT", cfg.RequestTimeout); err != nil {
		return config{}, err
	}
	if cfg.ShutdownGrace, err = durationFromEnv(getenv, "SHUTDOWN_GRACE", cfg.ShutdownGrace); err != nil {
		return config{}, err
	}
	if cfg.QueueCapacity, err = positiveIntFromEnv(getenv, "QUEUE_CAPACITY", cfg.QueueCapacity); err != nil {
		return config{}, err
	}
	if cfg.IdempotencyTTL, err = durationFromEnv(getenv, "IDEMPOTENCY_TTL", cfg.IdempotencyTTL); err != nil {
		return config{}, err
	}
	if cfg.LeaseTTL, err = durationFromEnv(getenv, "LEASE_TTL", cfg.LeaseTTL); err != nil {
		return config{}, err
	}
	return cfg, nil
}

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

// run starts the APIs and the reconcile loop, blocks until ctx is
// cancelled, then shuts everything down gracefully.
func run(ctx context.Context, getenv func(string) string, stdout io.Writer, ready func(addr string)) error {
	cfg, err := loadConfig(getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	effects := ledger.New()
	pending := queue.New(cfg.QueueCapacity)
	service := jobs.NewService(memstore.New(), jobs.WithDispatcher(pending), jobs.WithEffects(effects))
	coordinator := coord.New(service, pending.Next(), cfg.LeaseTTL, time.Now, logger)
	keys := idempotency.NewStore(cfg.IdempotencyTTL, time.Now)

	metrics := httpapi.NewMetrics()
	gauge := func(name, help string, value func() float64) prometheus.Collector {
		return prometheus.NewGaugeFunc(prometheus.GaugeOpts{Name: name, Help: help}, value)
	}
	metrics.MustRegister(
		collectors.NewGoCollector(), // go_goroutines, go_memstats_*, ...
		gauge("jobs_queue_depth", "Jobs waiting for a worker.", func() float64 { return float64(pending.Len()) }),
		gauge("idempotency_keys", "Idempotency keys currently remembered.", func() float64 { return float64(keys.Len()) }),
		gauge("workers", "Workers that have called in within the lease TTL.", func() float64 { return float64(coordinator.Stats().Workers) }),
		gauge("leases", "Jobs held by a worker right now.", func() float64 { return float64(coordinator.Stats().Leases) }),
		prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "jobs_handed_back_total",
			Help: "Jobs whose lease expired and were handed back to be run again.",
		}, func() float64 { return float64(coordinator.Stats().HandedBack) }),
		prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "effects_applied_total",
			Help: "Job effects recorded in the ledger.",
		}, func() float64 { applied, _ := effects.Counts(); return float64(applied) }),
	)

	handler := httpapi.NewHandler(service,
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
		httpapi.WithIdempotency(keys),
		httpapi.WithEffects(effects),
	)
	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      cfg.RequestTimeout + 5*time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Background loops run until shutdown, and run waits for them, so the
	// process never exits with one half-way through.
	loops, stopLoops := context.WithCancel(context.Background())
	defer stopLoops()
	var background sync.WaitGroup
	background.Add(2)
	go func() {
		defer background.Done()
		<-loops.Done() // the reconcile loop never runs
	}()
	go func() {
		defer background.Done()
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-loops.Done():
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
	grpcListener, err := net.Listen("tcp", cfg.GRPCAddr)
	if err != nil {
		listener.Close()
		return err
	}
	logger.Info("listening", "addr", listener.Addr().String(), "grpc_addr", grpcListener.Addr().String(), "lease_ttl", cfg.LeaseTTL.String())
	if ready != nil {
		ready(listener.Addr().String())
	}

	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(listener) }()

	grpcServer := grpc.NewServer()
	jobsv1.RegisterJobsServer(grpcServer, grpcapi.New(service))
	workersv1.RegisterWorkersServer(grpcServer, grpcapi.NewWorkers(coordinator))
	reflection.Register(grpcServer)
	go func() { _ = grpcServer.Serve(grpcListener) }()

	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}

	logger.Info("shutting down", "grace", cfg.ShutdownGrace.String())
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()

	// 1. Stop accepting HTTP requests, so no new jobs arrive.
	if err := server.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
		return err
	}

	// 2. Release workers waiting for a job, then stop gRPC, waiting for
	// calls in progress until the grace period ends. Workers holding jobs
	// keep running them; their reports will fail, and they'll retry.
	coordinator.Close()
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

	// 3. Stop the background loops, and wait for them.
	stopLoops()
	background.Wait()
	logger.Info("stopped", "jobs_left_in_queue", pending.Len(), "leases_held", coordinator.Stats().Leases)
	return nil
}
