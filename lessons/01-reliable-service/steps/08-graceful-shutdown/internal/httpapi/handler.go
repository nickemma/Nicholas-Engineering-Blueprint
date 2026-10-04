// Package httpapi translates HTTP to and from the jobs use cases. It owns
// status codes, JSON shapes and request limits, and holds no business rules.
package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"kestrel/internal/jobs"
)

// JobService is what the handlers need. It is defined here, where it is
// used, so tests could pass any implementation.
type JobService interface {
	Create(ctx context.Context, description string, duration time.Duration) (jobs.Job, error)
	Get(ctx context.Context, id jobs.ID) (jobs.Job, error)
	Run(ctx context.Context, id jobs.ID) (jobs.Job, error)
}

type handlers struct {
	jobs   JobService
	logger *slog.Logger
}

type config struct {
	logger         *slog.Logger
	metrics        *Metrics
	requestTimeout time.Duration
}

// Option configures the handler built by NewHandler.
type Option func(*config)

func WithLogger(logger *slog.Logger) Option {
	return func(c *config) { c.logger = logger }
}

func WithMetrics(metrics *Metrics) Option {
	return func(c *config) { c.metrics = metrics }
}

// WithRequestTimeout bounds how long any one request may run.
func WithRequestTimeout(d time.Duration) Option {
	return func(c *config) { c.requestTimeout = d }
}

// NewHandler builds the routes and wraps them in middleware. The outermost
// middleware runs first on the way in and last on the way out.
func NewHandler(service JobService, opts ...Option) http.Handler {
	cfg := config{
		logger:         slog.New(slog.DiscardHandler),
		requestTimeout: 2 * time.Second,
	}
	for _, opt := range opts {
		opt(&cfg)
	}

	h := &handlers{jobs: service, logger: cfg.logger}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", h.health)
	mux.HandleFunc("POST /jobs", h.createJob)
	mux.HandleFunc("GET /jobs/{id}", h.getJob)
	mux.HandleFunc("POST /jobs/{id}/run", h.runJob)
	if cfg.metrics != nil {
		mux.Handle("GET /metrics", cfg.metrics.Handler())
	}

	// Logging and metrics must receive the same *http.Request the router
	// does, so they can read the route it matched (r.Pattern). withTimeout
	// makes a copy of the request with r.WithContext, so it goes outside them.
	var handler http.Handler = mux
	if cfg.metrics != nil {
		handler = cfg.metrics.instrument(handler)
	}
	handler = withRequestLog(cfg.logger, handler)
	handler = withTimeout(cfg.requestTimeout, handler)
	handler = withRecover(cfg.logger, handler)
	return handler
}

type healthResponse struct {
	Status string `json:"status"`
}

func (h *handlers) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, healthResponse{Status: "ok"})
}

type createJobRequest struct {
	Description string `json:"description"`
	DurationMS  int64  `json:"duration_ms"`
}

type jobResponse struct {
	ID            jobs.ID   `json:"id"`
	State         string    `json:"state"`
	Description   string    `json:"description"`
	DurationMS    int64     `json:"duration_ms"`
	FailureReason string    `json:"failure_reason,omitempty"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

func toResponse(job jobs.Job) jobResponse {
	return jobResponse{
		ID:            job.ID,
		State:         string(job.State),
		Description:   string(job.Description),
		DurationMS:    job.Duration.Milliseconds(),
		FailureReason: job.FailureReason,
		CreatedAt:     job.CreatedAt,
		UpdatedAt:     job.UpdatedAt,
	}
}

func (h *handlers) createJob(w http.ResponseWriter, r *http.Request) {
	var req createJobRequest
	if err := decodeJSON(w, r, &req); err != nil {
		h.writeRequestError(w, err)
		return
	}

	job, err := h.jobs.Create(r.Context(), req.Description, time.Duration(req.DurationMS)*time.Millisecond)
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
	w.Header().Set("Location", "/jobs/"+strconv.FormatInt(int64(job.ID), 10))
	writeJSON(w, http.StatusCreated, toResponse(job))
}

func (h *handlers) getJob(w http.ResponseWriter, r *http.Request) {
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	job, err := h.jobs.Get(r.Context(), id)
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toResponse(job))
}

func (h *handlers) runJob(w http.ResponseWriter, r *http.Request) {
	id, ok := parseID(w, r)
	if !ok {
		return
	}
	job, err := h.jobs.Run(r.Context(), id)
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, toResponse(job))
	case errors.Is(err, context.DeadlineExceeded):
		writeJSON(w, http.StatusGatewayTimeout, toResponse(job))
	case errors.Is(err, context.Canceled):
		h.logger.Info("client went away during run", "job_id", id)
	default:
		h.writeDomainError(w, r, err)
	}
}

func parseID(w http.ResponseWriter, r *http.Request) (jobs.ID, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		writeError(w, http.StatusBadRequest, "job id must be a positive integer")
		return 0, false
	}
	return jobs.ID(id), true
}

func (h *handlers) writeRequestError(w http.ResponseWriter, err error) {
	var reqErr *requestError
	if errors.As(err, &reqErr) {
		writeError(w, reqErr.status, reqErr.message)
		return
	}
	writeError(w, http.StatusBadRequest, "bad request")
}

// writeDomainError maps domain errors to HTTP statuses. Unknown errors become
// a 500 with a generic message: internal details are logged, never sent.
func (h *handlers) writeDomainError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, jobs.ErrInvalidDescription), errors.Is(err, jobs.ErrInvalidDuration):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, jobs.ErrNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, jobs.ErrInvalidTransition), errors.Is(err, jobs.ErrConflict):
		writeError(w, http.StatusConflict, err.Error())
	default:
		h.logger.Error("unexpected error", "method", r.Method, "path", r.URL.Path, "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
	}
}
