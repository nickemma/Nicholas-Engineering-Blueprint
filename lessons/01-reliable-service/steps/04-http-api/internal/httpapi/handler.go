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
	jobs JobService
}

// NewHandler builds the routes. Each pattern names a method and a path, so
// the router itself answers 405 for a known path with the wrong method.
func NewHandler(service JobService) http.Handler {
	h := &handlers{jobs: service}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", h.health)
	mux.HandleFunc("POST /jobs", h.createJob)
	mux.HandleFunc("GET /jobs/{id}", h.getJob)
	mux.HandleFunc("POST /jobs/{id}/run", h.runJob)
	return mux
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
	if err != nil {
		h.writeDomainError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, toResponse(job))
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
		slog.Error("unexpected error", "method", r.Method, "path", r.URL.Path, "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
	}
}
