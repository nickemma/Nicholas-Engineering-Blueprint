# Module 1 — From greeting server to health endpoint

**Goal:** build a tiny greeting server from a blank lesson folder, then grow it into a testable HTTP service with `GET /health`, JSON, and clear HTTP errors.

Read and follow this guide from top to bottom. Build each step in this `lesson-01` folder; the parent folder contains the finished reference. Run the commands, compare your output with the expected result, and write down questions or surprises for `../learned.md`. When the build is complete, fill in that file and ask for a review before moving to the next phase.

## What you will understand by the end

- how a small Go program becomes a running HTTP server;
- how the method and path choose what server code runs;
- why a server should reject a request it does not support;
- how to prove handler behavior with a Go test, without starting a real server.

## The model to keep in your head

Imagine a receptionist.

```text
curl (visitor)
  → port 8080 (numbered door)
  → mux (the receptionist's directory)
  → health handler (the person who answers)
  → HTTP response (the reply)
```

`main` opens the office once. The handler is called once for every matching request. The server keeps running because it is waiting for the next visitor.

## Part 1 — Set up the lesson module

Open a terminal in this `lesson-01` folder and run:

```bash
go mod init lesson-01
```

This creates `go.mod` for the practice copy. The parent `00-request-service` module is the finished reference; this nested module is where you build the lesson without changing that reference.

## Part 2 — Build and run a greeting server

Create `main.go` in this folder with the greeting server:

```go
package main

import (
	"fmt"
	"log"
	"net/http"
)

func greet(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "Hello from the request service!")
}

func main() {
	http.HandleFunc("/", greet)

	log.Println("server listening on http://localhost:8080")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatal(err)
	}
}
```

Format and run it:

```bash
gofmt -w main.go
go run .
```

While it stays running, use a second terminal:

```bash
curl -i http://localhost:8080/
```

Expect HTTP `200 OK` and the greeting as the response body. Also request `/health` at this point. The greeting handler is registered at `/`, so the server answers that path with the same greeting for now. Stop the server with `Ctrl+C` before changing the code.

## Part 3 — Add the health endpoint

Now replace the contents of `main.go` with the next version. This keeps the greeting route and adds a dedicated health route that accepts only GET:

```go
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"unicode/utf8"
)

type healthResponse struct {
	Status string `json:"status"`
}

func health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(healthResponse{Status: "ok"}); err != nil {
		log.Printf("write health response: %v", err)
	}
}

func greet(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	fmt.Fprintln(w, "Hello from the request service!")
}

func greetName(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	name := strings.TrimSpace(r.URL.Query().Get("name"))
	if name == "" || utf8.RuneCountInString(name) > 40 {
		http.Error(w, "name must be between 1 and 40 characters", http.StatusBadRequest)
		return
	}
	fmt.Fprintf(w, "Hello, %s!\n", name)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", health)
	mux.HandleFunc("/greet", greetName)
	mux.HandleFunc("/", greet)

	log.Println("server listening on http://localhost:8080")
	if err := http.ListenAndServe(":8080", mux); err != nil {
		log.Fatal(err)
	}
}
```

### Read the code by purpose, not by punctuation

| Code | Job |
|---|---|
| `healthResponse` | Describes the shape of our reply: an object with a `status` field. |
| ``json:"status"`` | Tells Go to spell that JSON field `status`, not `Status`. |
| `health(...)` | The handler: it receives a request and writes a response. |
| `greet(...)` | Handles the exact root path `/`; it returns 404 for other paths and 405 for unsupported methods. |
| `greetName(...)` | Reads the `name` query value, trims whitespace, and rejects a missing or overlong value with 400. |
| `r.Method` | Tells us whether the visitor used GET, POST, or another HTTP method. |
| `http.MethodGet` | Go's safe name for the text `GET`. |
| `http.Error(...)` | Writes an error response. `405` means “this path exists, but that method is not allowed.” |
| `return` | Stops this handler immediately after the error. Without it, the handler would wrongly continue and try to write success too. |
| `w.Header().Set(...)` | Labels our response as JSON before we send its body. |
| `json.NewEncoder(w).Encode(...)` | Writes `{"status":"ok"}` to the response, not to your terminal. |
| `mux.HandleFunc("/health", health)` | Maps the `/health` path to the `health` handler. |
| `mux.HandleFunc("/greet", greetName)` | Maps `/greet` to the handler that validates the caller's name. |
| `mux.HandleFunc("/", greet)` | Uses `/` as the fallback route; `greet` checks that the path is exactly `/`. |
| `ListenAndServe(":8080", mux)` | Opens port 8080 and sends arriving requests through that directory. |

## Part 4 — Run the real server and inspect its behavior

In terminal A, run:

```bash
go run main.go
```

It should print the listening address and remain running. That is normal; it is waiting for requests.

In terminal B, run each command separately.

### 1. The supported request

```bash
curl -i http://localhost:8080/health
```

Expected important parts:

```text
HTTP/1.1 200 OK
Content-Type: application/json

{"status":"ok"}
```

`200` means the request succeeded. The JSON is the response body.

### 2. Valid and invalid greeting input

```bash
curl -i 'http://localhost:8080/greet?name=Ada'
curl -i http://localhost:8080/greet
```

The first returns `200 OK` with `Hello, Ada!`. The second returns `400 Bad Request` because the required name is missing. Try a name with surrounding spaces; the server trims them before replying.

### 3. A path the server does not know

```bash
curl -i http://localhost:8080/unknown
```

Expected: `404 Not Found`.

The fallback route reaches `greet`, which sees that the path is unsupported and writes the 404 response. This is different from a program crash: the server is still healthy; it simply does not offer that route.

### 4. A method the handler rejects

```bash
curl -i -X POST http://localhost:8080/health
```

Expected: `405 Method Not Allowed` and a `method not allowed` message.

The first greeting handler accepted every method. The updated handlers have an explicit contract: **only GET is allowed.**

Stop the server in terminal A with `Ctrl+C` after these checks.

## Part 5 — Prove the handler with an automated test

Create `main_test.go` in the same folder with this code:

```go
package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthReturnsOK(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	response := httptest.NewRecorder()

	health(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}

	if body := response.Body.String(); body != "{\"status\":\"ok\"}\n" {
		t.Fatalf("body = %q, want health JSON", body)
	}
}

func TestHealthRejectsPOST(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "/health", nil)
	response := httptest.NewRecorder()

	health(response, request)

	if response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusMethodNotAllowed)
	}
}

func TestGreetingAtRoot(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	response := httptest.NewRecorder()

	greet(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if body := response.Body.String(); body != "Hello from the request service!\n" {
		t.Fatalf("body = %q, want greeting", body)
	}
}

func TestGreetingRejectsUnknownPath(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/unknown", nil)
	response := httptest.NewRecorder()

	greet(response, request)

	if response.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusNotFound)
	}
}

func TestGreetNameReturnsGreeting(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/greet?name=Ada", nil)
	response := httptest.NewRecorder()

	greetName(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if body := response.Body.String(); body != "Hello, Ada!\n" {
		t.Fatalf("body = %q, want greeting", body)
	}
}

func TestGreetNameRejectsMissingName(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/greet", nil)
	response := httptest.NewRecorder()

	greetName(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusBadRequest)
	}
}

func TestGreetNameRejectsOverlongName(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/greet?name=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRST", nil)
	response := httptest.NewRecorder()

	greetName(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusBadRequest)
	}
}
```

Run:

```bash
go test ./...
```

Expected:

```text
ok      lesson-01      ...
```

These tests do **not** open port 8080. `httptest` makes a pretend request and a pretend response recorder, then calls a handler directly. This makes tests fast and focused: they prove each handler's decision-making, while the `curl` checks prove the real network server works.

## Part 6 — Deliberately break the proof, then repair it

In `main.go`, temporarily change:

```go
healthResponse{Status: "ok"}
```

to:

```go
healthResponse{Status: "ready"}
```

Run `go test ./...` again. It should fail because the behavior changed but the test still claims the correct response is `{"status":"ok"}`.

Do not update the test yet. First read the failure and answer: **what did the program actually return, and what did the test expect?** Then change `ready` back to `ok` and confirm the test passes.

This is the engineering habit: a failure message is evidence, not an accusation. Read what happened, compare it with what should happen, then decide whether the program or the test is wrong.

## Part 7 — Keep a record of the work

From the Blueprint repository root, inspect what changed:

```bash
git status --short
git diff --check
```

`git status` shows changed and new files; `git diff --check` catches whitespace mistakes. After your lesson and notes are complete, save them in a commit:

```bash
git add projects/00-request-service/lesson-01 projects/00-request-service/learned.md
git commit -m "Complete Phase 0 request service lesson"
```

Before Phase 0 is signed off, add `.github/workflows/request-service.yml` at the Blueprint repository root:

```yaml
name: Request service

on:
  push:
    paths:
      - 'projects/00-request-service/**'
      - '.github/workflows/request-service.yml'
  pull_request:
    paths:
      - 'projects/00-request-service/**'
      - '.github/workflows/request-service.yml'

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-go@v7
        with:
          go-version-file: projects/00-request-service/go.mod
      - name: Test finished reference
        run: go test ./...
        working-directory: projects/00-request-service
      - name: Test lesson build
        run: go test ./...
        working-directory: projects/00-request-service/lesson-01
```

Commit and push the workflow with the project files, then check that the **Request service** workflow is green in GitHub Actions. The commit is the saved checkpoint; CI is the repeatable check that runs when the code changes.

## Final checkpoint

Complete this without looking at the table above:

1. Why is `main` not run every time `curl` sends a request?
2. What decides that `/health` calls `health`?
3. Why do we return immediately after `http.Error`?
4. What is the difference between the `404` and `405` results you saw?
5. Why does `/greet` reject a missing name instead of using it anyway?
6. Why do we use both `curl` and `go test`?

When you finish, complete [`../learned.md`](../learned.md) from memory with your explanations, evidence, checklist, and open questions. Ask for a review before moving to the next phase.

The next phase will make the service reliable under concurrent requests and graceful shutdown.
