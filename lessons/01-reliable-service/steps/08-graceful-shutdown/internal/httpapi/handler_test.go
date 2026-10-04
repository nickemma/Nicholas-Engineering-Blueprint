package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"kestrel/internal/jobs"
	"kestrel/internal/memstore"
)

func newTestHandler(opts ...Option) http.Handler {
	return NewHandler(jobs.NewService(memstore.New()), opts...)
}

func do(t *testing.T, h http.Handler, method, target, body string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, target, strings.NewReader(body))
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	response := httptest.NewRecorder()
	h.ServeHTTP(response, request)
	return response
}

func decode(t *testing.T, r *httptest.ResponseRecorder) jobResponse {
	t.Helper()
	var job jobResponse
	if err := json.Unmarshal(r.Body.Bytes(), &job); err != nil {
		t.Fatalf("decode %q: %v", r.Body.String(), err)
	}
	return job
}

func TestHealth(t *testing.T) {
	response := do(t, newTestHandler(), http.MethodGet, "/health", "")
	if response.Code != http.StatusOK || response.Body.String() != "{\"status\":\"ok\"}\n" {
		t.Fatalf("got %d %q", response.Code, response.Body.String())
	}
}

func TestCreateThenGet(t *testing.T) {
	h := newTestHandler()

	created := do(t, h, http.MethodPost, "/jobs", `{"description":"resize","duration_ms":50}`)
	if created.Code != http.StatusCreated {
		t.Fatalf("POST status = %d, body %s", created.Code, created.Body)
	}
	job := decode(t, created)
	if job.ID != 1 || job.State != "queued" || job.DurationMS != 50 {
		t.Fatalf("created = %+v", job)
	}
	if got := created.Header().Get("Location"); got != "/jobs/1" {
		t.Fatalf("Location = %q, want /jobs/1", got)
	}

	fetched := do(t, h, http.MethodGet, "/jobs/1", "")
	if fetched.Code != http.StatusOK || decode(t, fetched).Description != "resize" {
		t.Fatalf("GET = %d %s", fetched.Code, fetched.Body)
	}
}

func TestCreateRejectsBadRequests(t *testing.T) {
	tests := []struct {
		name        string
		contentType string
		body        string
		wantStatus  int
		wantError   string
	}{
		{"wrong content type", "text/plain", `{"description":"x"}`, http.StatusUnsupportedMediaType, "Content-Type must be application/json"},
		{"empty body", "application/json", ``, http.StatusBadRequest, "request body is empty"},
		{"malformed JSON", "application/json", `{"description":`, http.StatusBadRequest, "request body is not valid JSON"},
		{"wrong type", "application/json", `{"description":42}`, http.StatusBadRequest, `field "description" has the wrong type`},
		{"unknown field", "application/json", `{"description":"x","priority":1}`, http.StatusBadRequest, `unknown field "priority"`},
		{"two objects", "application/json", `{"description":"x"}{"description":"y"}`, http.StatusBadRequest, "request body must contain a single JSON object"},
		{"missing description", "application/json", `{}`, http.StatusBadRequest, jobs.ErrInvalidDescription.Error()},
		{"duration too long", "application/json", `{"description":"x","duration_ms":60000}`, http.StatusBadRequest, jobs.ErrInvalidDuration.Error()},
		{"oversized body", "application/json", `{"description":"` + strings.Repeat("a", 2000) + `"}`, http.StatusRequestEntityTooLarge, "request body must not exceed 1024 bytes"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/jobs", strings.NewReader(tt.body))
			request.Header.Set("Content-Type", tt.contentType)
			response := httptest.NewRecorder()
			newTestHandler().ServeHTTP(response, request)

			if response.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d (body %s)", response.Code, tt.wantStatus, response.Body)
			}
			var got errorResponse
			_ = json.Unmarshal(response.Body.Bytes(), &got)
			if got.Error != tt.wantError {
				t.Fatalf("error = %q, want %q", got.Error, tt.wantError)
			}
		})
	}
}

func TestGetErrors(t *testing.T) {
	h := newTestHandler()
	tests := []struct {
		target string
		want   int
	}{
		{"/jobs/99", http.StatusNotFound},
		{"/jobs/abc", http.StatusBadRequest},
		{"/jobs/0", http.StatusBadRequest},
		{"/jobs/-3", http.StatusBadRequest},
	}
	for _, tt := range tests {
		if got := do(t, h, http.MethodGet, tt.target, "").Code; got != tt.want {
			t.Errorf("GET %s = %d, want %d", tt.target, got, tt.want)
		}
	}
}

func TestRouterRejectsWrongMethod(t *testing.T) {
	response := do(t, newTestHandler(), http.MethodDelete, "/jobs/1", "")
	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", response.Code)
	}
	if allow := response.Header().Get("Allow"); !strings.Contains(allow, "GET") {
		t.Fatalf("Allow = %q, want it to list GET", allow)
	}
}

func TestRunCompletesThenConflicts(t *testing.T) {
	h := newTestHandler()
	do(t, h, http.MethodPost, "/jobs", `{"description":"resize","duration_ms":10}`)

	first := do(t, h, http.MethodPost, "/jobs/1/run", "")
	if first.Code != http.StatusOK || decode(t, first).State != "completed" {
		t.Fatalf("first run = %d %s", first.Code, first.Body)
	}
	second := do(t, h, http.MethodPost, "/jobs/1/run", "")
	if second.Code != http.StatusConflict {
		t.Fatalf("second run = %d, want 409", second.Code)
	}
}

func TestRunPastDeadlineReturns504AndFailsJob(t *testing.T) {
	h := newTestHandler(WithRequestTimeout(50 * time.Millisecond))
	do(t, h, http.MethodPost, "/jobs", `{"description":"slow","duration_ms":2000}`)

	start := time.Now()
	response := do(t, h, http.MethodPost, "/jobs/1/run", "")
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("run took %v; the deadline should have stopped it near 50ms", elapsed)
	}
	if response.Code != http.StatusGatewayTimeout {
		t.Fatalf("status = %d, want 504", response.Code)
	}
	if job := decode(t, response); job.State != "failed" || job.FailureReason != "deadline exceeded" {
		t.Fatalf("job = %+v", job)
	}
	if job := decode(t, do(t, h, http.MethodGet, "/jobs/1", "")); job.State != "failed" {
		t.Fatalf("stored state = %s, want failed", job.State)
	}
}

func TestRequestLogUsesRoutePattern(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&logs, nil))
	h := newTestHandler(WithLogger(logger))

	do(t, h, http.MethodGet, "/jobs/42", "")

	var record map[string]any
	if err := json.Unmarshal(logs.Bytes(), &record); err != nil {
		t.Fatalf("log line %q: %v", logs.String(), err)
	}
	if record["route"] != "GET /jobs/{id}" || record["status"] != float64(404) {
		t.Fatalf("log record = %v", record)
	}
}

func TestMetricsCountRequests(t *testing.T) {
	h := newTestHandler(WithMetrics(NewMetrics()))
	do(t, h, http.MethodGet, "/health", "")
	do(t, h, http.MethodGet, "/health", "")

	body := do(t, h, http.MethodGet, "/metrics", "").Body.String()
	want := `http_requests_total{code="200",method="GET",route="GET /health"} 2`
	if !strings.Contains(body, want) {
		t.Fatalf("metrics missing %q:\n%s", want, body)
	}
}

type panickingService struct{ JobService }

func (panickingService) Get(context.Context, jobs.ID) (jobs.Job, error) { panic("boom") }

func TestPanicBecomes500(t *testing.T) {
	h := NewHandler(panickingService{}, WithLogger(slog.New(slog.NewTextHandler(io.Discard, nil))))
	response := do(t, h, http.MethodGet, "/jobs/1", "")
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", response.Code)
	}
}
