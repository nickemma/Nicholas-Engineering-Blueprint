# Module 1 — Build a health endpoint

**Time:** 45–60 minutes  
**Goal:** turn the greeting server into a small, testable HTTP health endpoint that accepts only `GET /health` and returns JSON.

Do this module from top to bottom at your own pace. Do not wait for a reply after each command. Stop only if an error differs from the guide or when you reach the final checkpoint.

## What you will understand by the end

- the difference between a program, a process, a server, a port, a request, and a response;
- how an HTTP path and method choose what server code runs;
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

## Part 1 — Set up this small Go project

In the `lesson-01` folder, run:

```bash
go mod init lesson-01
```

This creates `go.mod`. A Go module is simply a small file that says, “these source files belong to one project.” We need it so `go test` knows what project it is testing.

You already completed the greeting-server baseline. If it is still running, stop it with `Ctrl+C` before continuing.

## Part 2 — Replace the greeting server with a health endpoint

Replace the entire contents of `main.go` with this code. Type it if you can; typing code is useful practice. Pasting it is fine if syntax slows you down—the explanation below is the important part.

```go
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
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

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", health)

	fmt.Println("Listening on http://localhost:8080")
	if err := http.ListenAndServe(":8080", mux); err != nil {
		log.Println("server stopped:", err)
	}
}
```

### Read the code by purpose, not by punctuation

| Code | Job |
|---|---|
| `healthResponse` | Describes the shape of our reply: an object with a `status` field. |
| ``json:"status"`` | Tells Go to spell that JSON field `status`, not `Status`. |
| `health(...)` | The handler: it receives a request and writes a response. |
| `r.Method` | Tells us whether the visitor used GET, POST, or another HTTP method. |
| `http.MethodGet` | Go's safe name for the text `GET`. |
| `http.Error(...)` | Writes an error response. `405` means “this path exists, but that method is not allowed.” |
| `return` | Stops this handler immediately after the error. Without it, the handler would wrongly continue and try to write success too. |
| `w.Header().Set(...)` | Labels our response as JSON before we send its body. |
| `json.NewEncoder(w).Encode(...)` | Writes `{"status":"ok"}` to the response, not to your terminal. |
| `mux.HandleFunc("/health", health)` | Maps the `/health` path to the `health` handler. |
| `ListenAndServe(":8080", mux)` | Opens port 8080 and sends arriving requests through that directory. |

## Part 3 — Run the real server and inspect its behavior

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

### 2. A path the server does not know

```bash
curl -i http://localhost:8080/unknown
```

Expected: `404 Not Found`.

The mux did not find a handler for that path. This is different from a program crash: the server is still healthy; it simply does not offer that route.

### 3. A method the handler rejects

```bash
curl -i -X POST http://localhost:8080/health
```

Expected: `405 Method Not Allowed` and a `method not allowed` message.

This is the bug you discovered with the greeting server. Its handler answered every kind of request because it never checked `r.Method`. The new handler has an explicit contract: **only GET is allowed.**

Stop the server in terminal A with `Ctrl+C` after these checks.

## Part 4 — Prove the handler with an automated test

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
```

Run:

```bash
go test ./...
```

Expected:

```text
ok      lesson-01      ...
```

These tests do **not** open port 8080. `httptest` makes a pretend request and a pretend response recorder, then calls `health` directly. This makes tests fast and focused: they prove the handler's decision-making, while the `curl` checks proved the real network server works.

## Part 5 — Deliberately break the proof, then repair it

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

## Final checkpoint

Complete this without looking at the table above:

1. Why is `main` not run every time `curl` sends a request?
2. What decides that `/health` calls `health`?
3. Why do we return immediately after `http.Error`?
4. What is the difference between the `404` and `405` results you saw?
5. Why do we use both `curl` and `go test`?

When you finish, send me:

- the output of `go test ./...`;
- your short answers to the five questions;
- any part that felt like magic or did not make sense.

The next module will add one small input to the service and show why servers must validate what they receive.
