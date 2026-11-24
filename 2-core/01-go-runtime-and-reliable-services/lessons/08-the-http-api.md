# 08 The HTTP API

> Module: Go runtime and reliable services · Time: ~5 h · Builds on: 03, 07

## The problem

The job service works from Go code. Callers speak HTTP and JSON. The HTTP layer must turn requests into service calls and results into precise status codes, refuse malformed input *before* it reaches the service, and contain no business rules of its own. Every request body is written by someone you don't control, so every request body is treated as hostile.

## The mental model

~~~text
 POST /jobs  {"description":"resize","duration_ms":300}
      │
      ▼ httpapi (translates; no rules)
 decodeJSON ── Content-Type? ≤ 1 KiB? one object? no unknown fields? ── no ──▶ 400 / 413 / 415
      │ yes
      ▼
 h.jobs.Create(ctx, "resize", 300ms) ── jobs.Service (the rules, lessons 05–07)
      │                   └── error ──▶ writeDomainError: ErrInvalid… → 400, ErrNotFound → 404,
      ▼                                 ErrInvalidTransition / ErrConflict → 409, anything else → 500
 201 Created, Location: /jobs/1, {"id":1,"state":"queued",...}
~~~

## The pattern

**Accept interfaces, translate at the edge.** The HTTP package defines the interface it *consumes*, `JobService`, with only the three methods it calls; the service doesn't know it exists. The JSON shapes are separate types from the domain's, so the domain can change without breaking callers. And the status codes say whose fault it was: `400` you sent something wrong, `409` you sent something valid that the current state doesn't allow, `500` we broke. Internal details go to the log, never to the caller.

| Request | Success | Errors |
|---|---|---|
| `POST /jobs` with `{"description": "...", "duration_ms": 300}` | `201`, the job `queued`, and `Location: /jobs/{id}` | `400` bad JSON, missing, invalid or unknown fields; `413` body over 1 KiB; `415` not `application/json` |
| `GET /jobs/{id}` | `200` and the job | `400` id not a positive integer; `404` no such job |
| `POST /jobs/{id}/run` | `200` and the job `completed` | `404` no such job; `409` not queued; `504` the work passed the deadline (lesson 10) |

`duration_ms` (0 to 5,000) is how long the job's simulated work takes: it's how you'll make slow requests on purpose.

## Build it

### Step 1: Strict JSON

Replace `internal/httpapi/json.go`:

<!-- file: internal/httpapi/json.go -->
~~~go
package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strings"
)

const maxBodyBytes = 1 << 10 // 1 KiB

// requestError is a client mistake: it carries the status and a message
// that is safe to show the caller.
type requestError struct {
	status  int
	message string
}

func (e *requestError) Error() string { return e.message }

// decodeJSON reads exactly one JSON object into dst, refusing anything else:
// the wrong content type, an oversized body, unknown fields, or trailing data.
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	mediaType, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if mediaType != "application/json" {
		return &requestError{http.StatusUnsupportedMediaType, "Content-Type must be application/json"}
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(dst); err != nil {
		return describeDecodeError(err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return &requestError{http.StatusBadRequest, "request body must contain a single JSON object"}
	}
	return nil
}

func describeDecodeError(err error) error {
	var syntaxErr *json.SyntaxError
	var typeErr *json.UnmarshalTypeError
	var tooLarge *http.MaxBytesError

	switch {
	case errors.Is(err, io.EOF):
		return &requestError{http.StatusBadRequest, "request body is empty"}
	case errors.As(err, &syntaxErr), errors.Is(err, io.ErrUnexpectedEOF):
		return &requestError{http.StatusBadRequest, "request body is not valid JSON"}
	case errors.As(err, &typeErr):
		return &requestError{http.StatusBadRequest, fmt.Sprintf("field %q has the wrong type", typeErr.Field)}
	case strings.HasPrefix(err.Error(), "json: unknown field "):
		field := strings.TrimPrefix(err.Error(), "json: unknown field ")
		return &requestError{http.StatusBadRequest, "unknown field " + field}
	case errors.As(err, &tooLarge):
		return &requestError{http.StatusRequestEntityTooLarge, fmt.Sprintf("request body must not exceed %d bytes", maxBodyBytes)}
	default:
		return &requestError{http.StatusBadRequest, "request body could not be read"}
	}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Warn("write response", "error", err)
	}
}

type errorResponse struct {
	Error string `json:"error"`
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, errorResponse{Error: message})
}
~~~

- `http.MaxBytesReader` stops reading after 1 KiB (lesson 02: every input gets a limit).
- `DisallowUnknownFields` refuses fields the contract doesn't have. Otherwise a typo such as `"descripton"` is silently ignored, and the caller thinks it worked.
- Decoding a **second** value and requiring `io.EOF` refuses `{"a":1}{"b":2}`.
- `requestError` has an `Error() string` method, so it's an `error`, carrying a status that a plain string error can't. `errors.As` (Go from zero lesson 03 used `errors.Is`) checks whether an error, or anything it wraps, has a given **type**, and hands you that value, such as `typeErr.Field`.
- `log/slog` is Go's structured logger; lesson 11 is about it. `any` means a value of any type.

### Step 2: The routes

Replace `internal/httpapi/handler.go`. It keeps `/health` and `/greet` from lesson 03 and adds the jobs:

<!-- file: internal/httpapi/handler.go -->
~~~go
// Package httpapi is Switchyard's HTTP layer. It translates HTTP to and from
// the jobs use cases, owns status codes, JSON shapes and request limits, and
// holds no business rules.
package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"switchyard/internal/jobs"
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
	mux.HandleFunc("GET /greet", h.greet)
	mux.HandleFunc("POST /jobs", h.createJob)
	mux.HandleFunc("GET /jobs/{id}", h.getJob)
	mux.HandleFunc("POST /jobs/{id}/run", h.runJob)
	return mux
}

type healthResponse struct {
	Status  string `json:"status"`
	Service string `json:"service"`
}

func (h *handlers) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, healthResponse{Status: "ok", Service: "switchyard"})
}

const maxNameLength = 40

type greetResponse struct {
	Greeting string `json:"greeting"`
}

func (h *handlers) greet(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimSpace(r.URL.Query().Get("name"))
	if name == "" || utf8.RuneCountInString(name) > maxNameLength {
		writeError(w, http.StatusBadRequest, "name must be 1 to 40 characters")
		return
	}
	writeJSON(w, http.StatusOK, greetResponse{Greeting: "Hello, " + name + "!"})
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
~~~

- `GET /jobs/{id}` has a **wildcard**; `r.PathValue("id")` reads it.
- `jobResponse` is the JSON shape, separate from `jobs.Job`; `toResponse` translates. `omitempty` leaves `failure_reason` out when it's empty.
- `201 Created` and a `Location` header are HTTP's way of saying "I made something, and here it is".
- Every handler has the same shape: parse, call one service method, map the result, write once, return.

### Step 3: Wire it up

Replace `cmd/switchyard/main.go`:

<!-- file: cmd/switchyard/main.go -->
~~~go
// Command switchyard runs Switchyard's control plane.
package main

import (
	"log"
	"net/http"
	"time"

	"switchyard/internal/httpapi"
	"switchyard/internal/jobs"
	"switchyard/internal/memstore"
)

func main() {
	store := memstore.New()
	service := jobs.NewService(store)
	srv := &http.Server{
		Addr:              "127.0.0.1:8080",
		Handler:           httpapi.NewHandler(service),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("listening on http://%s", srv.Addr)
	log.Fatal(srv.ListenAndServe())
}
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go build -o /dev/null ./cmd/switchyard -->

The program builds; `go test` doesn't yet, because the tests still call `NewHandler()` with no service.

### Step 4: Tests

`NewHandler` now needs a service, so lesson 04's tests need one too. In `internal/httpapi/handler_test.go`, import the two packages that build one:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	"strings"
	"testing"
)
~~~

~~~go
	"strings"
	"testing"

	"switchyard/internal/jobs"
	"switchyard/internal/memstore"
)
~~~

use a real service in the router table:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	handler := NewHandler()
~~~

~~~go
	handler := newTestHandler()
~~~

and in the real-connection test:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	srv := httptest.NewServer(NewHandler())
~~~

~~~go
	srv := httptest.NewServer(newTestHandler())
~~~

Then add the jobs tests at the end. `TestCreateRejectsBadRequests` matters most: each row is one line of the contract.

<!-- append: internal/httpapi/handler_test.go -->
~~~go
func newTestHandler() http.Handler {
	return NewHandler(jobs.NewService(memstore.New()))
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
~~~

~~~bash
go test -race ./...
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... && go test -race -count=1 ./... -->

~~~text
?   	switchyard/cmd/switchyard	[no test files]
ok  	switchyard/drills/byhand	1.030s
ok  	switchyard/drills/escape	1.025s [no tests to run]
?   	switchyard/drills/gc	[no test files]
?   	switchyard/drills/sched	[no test files]
?   	switchyard/drills/spin	[no test files]
?   	switchyard/drills/stacks	[no test files]
?   	switchyard/drills/stdhttp	[no test files]
ok  	switchyard/internal/httpapi	1.043s
ok  	switchyard/internal/jobs	1.058s
ok  	switchyard/internal/memstore	1.021s
~~~

### Step 5: Try the contract

Start it, create a job, run it twice:

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && /tmp/switchyard &
sleep 0.5
curl -si -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"resize images","duration_ms":300}'
echo; time curl -s -X POST http://127.0.0.1:8080/jobs/1/run
curl -s -w "  [%{http_code}]\n" -X POST http://127.0.0.1:8080/jobs/1/run
~~~

~~~text
2026/11/20 02:43:21 listening on http://127.0.0.1:8080
HTTP/1.1 201 Created
Content-Type: application/json
Location: /jobs/1
Date: Fri, 20 Nov 2026 02:43:21 GMT
Content-Length: 166

{"id":1,"state":"queued","description":"resize images","duration_ms":300,"created_at":"2026-11-20T02:43:21.506866148Z","updated_at":"2026-11-20T02:43:21.506866148Z"}

{"id":1,"state":"completed","description":"resize images","duration_ms":300,"created_at":"2026-11-20T02:43:21.506866148Z","updated_at":"2026-11-20T02:43:21.81498033Z"}

real	0m0.309s
user	0m0.006s
sys	0m0.000s
{"error":"invalid state transition: completed to running"}
  [409]
~~~

`time` shows the run took a little over the job's 300 ms. The second run is a `409`: the domain refused `completed → running`. Now every error path; predict each status first:

~~~bash
J='Content-Type: application/json'; U=http://127.0.0.1:8080
curl -s -w "  [%{http_code}]\n" -X POST $U/jobs -H "$J" -d '{}'
curl -s -w "  [%{http_code}]\n" -X POST $U/jobs -H "$J" -d '{"description":"x","priority":1}'
curl -s -w "  [%{http_code}]\n" -X POST $U/jobs -d '{"description":"x"}'
curl -s -w "  [%{http_code}]\n" -X POST $U/jobs -H "$J" -d "{\"description\":\"$(printf 'a%.0s' {1..2000})\"}"
curl -s -w "  [%{http_code}]\n" $U/jobs/99
curl -s -w "  [%{http_code}]\n" $U/jobs/abc
curl -si -X DELETE $U/jobs/1 | head -2
~~~

~~~text
{"error":"description must be between 1 and 200 characters"}
  [400]
{"error":"unknown field \"priority\""}
  [400]
{"error":"Content-Type must be application/json"}
  [415]
{"error":"request body must not exceed 1024 bytes"}
  [413]
{"error":"job not found"}
  [404]
{"error":"job id must be a positive integer"}
  [400]
HTTP/1.1 405 Method Not Allowed
Allow: GET, HEAD
~~~

- The `415`: `curl -d` sends `Content-Type: application/x-www-form-urlencoded` unless told otherwise.
- The `413` for a 2,000-character description: the body limit, before JSON is even parsed.
- `DELETE` gets `405` from the router, which lists `GET, HEAD`.

Finally, stop the server, start it again, and ask for job 1:

~~~bash
kill %1; /tmp/switchyard & sleep 0.5; curl -s -w "  [%{http_code}]\n" http://127.0.0.1:8080/jobs/1; kill %1
~~~

~~~text
{"error":"job not found"}
  [404]
~~~

Gone. The job lived in the old process's memory. Core 03 moves jobs into PostgreSQL, behind the same `Repository` interface, without touching a handler.

## Break it

**Let unknown fields through.** Delete `decoder.DisallowUnknownFields()` and run the tests:

~~~text
--- FAIL: TestCreateRejectsBadRequests (0.00s)
    --- FAIL: TestCreateRejectsBadRequests/unknown_field (0.00s)
        handler_test.go:156: status = 201, want 400 (body {"id":1,"state":"queued","description":"x","duration_ms":0,"created_at":"2026-11-20T02:43:26.181919016Z","updated_at":"2026-11-20T02:43:26.181919016Z"}
            )
FAIL
FAIL	switchyard/internal/httpapi	0.024s
FAIL
~~~

Without the check, `{"description":"x","priority":1}` is `201 Created`: the caller believes they set a priority, and the service silently threw it away. The table row catches it. Put it back.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race ./...
~~~

Then answer: why does `httpapi` define `JobService` instead of using `*jobs.Service`? What's the difference between `400`, `409` and `500` here? And add, test-first, a row to `TestCreateRejectsBadRequests` for `{"description":"x","duration_ms":-1}`.

That proves every promise in the contract, one request at a time. It doesn't yet configure the server properly or set its timeouts: the next lesson wires everything in one place.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `415` from `curl` | No `-H 'Content-Type: application/json'` | Add it |
| `{"error":"unknown field \"descripton\""}` | A typo in the request: the check working | Fix the field name |
| `404` for a job you just made | The server restarted; jobs live in memory | Expected until core 03 |
| `500 internal error` | An error the mapping doesn't know | Read the server log; add the error to `writeDomainError` if it's a client mistake |
| `not enough arguments in call to NewHandler` in a test | A test still calls `NewHandler()` | Use `newTestHandler()` |
