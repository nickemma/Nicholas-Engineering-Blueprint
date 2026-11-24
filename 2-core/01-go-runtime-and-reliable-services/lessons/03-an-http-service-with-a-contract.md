# 03 An HTTP service with a contract

> Module: Go runtime and reliable services · Time: ~5 h · Builds on: 02

## The problem

A service is only useful if its callers can rely on it: which paths exist, which methods each accepts, what a success looks like, what an error looks like, which input is refused. That set of promises is the service's **contract**. A service that answers some errors as plain text, some as JSON and some as an HTML page, that accepts `DELETE` on a read-only path, or that takes a 10,000-character name forces every caller to guess, and guesses break in production. This lesson starts Switchyard's control plane with a small contract, kept exactly.

## The mental model

~~~text
 curl / another service
        │  GET /greet?name=Ada
        ▼
 http.Server ── reads the request, one goroutine per connection (lesson 02)
        │
        ▼
 ServeMux (the router) ── matches "GET /greet": method and path
        │                  no match for the path → 404; path but not method → 405 + Allow
        ▼
 handler ── validates input, writes JSON:
              200 {"greeting":"Hello, Ada!"}
              400 {"error":"name must be 1 to 40 characters"}
~~~

## The pattern

**One package owns the contract.** `internal/httpapi` holds every route, status code and JSON shape; nothing else in Switchyard knows HTTP exists. Two helpers, `writeJSON` and `writeError`, are the only way a response is written, so every response has the same shape. Later, the job rules (lesson 05) live in a package that knows nothing about HTTP, and this package translates between the two.

| Request | Response |
|---|---|
| `GET /health` | `200` `{"status":"ok"}` |
| `GET /greet?name=NAME` | `200` `{"greeting":"Hello, NAME!"}`, with `NAME` trimmed of spaces |
| `GET /greet` with no name, a blank one, or more than 40 characters | `400` `{"error":"name must be 1 to 40 characters"}` |
| Another method on a known path | `405`, with an `Allow` header listing the methods that work |
| An unknown path | `404` |

Every response the handlers write is JSON with `Content-Type: application/json`. The `404` and `405` come from Go's router, as short plain-text bodies; a client should rely on their status codes.

## Build it

### Step 1: The JSON helpers

`internal/` is a special folder name in Go: packages under it can be imported only by code inside this module. Create `internal/httpapi/json.go`:

<!-- file: internal/httpapi/json.go -->
~~~go
package httpapi

import (
	"encoding/json"
	"log"
	"net/http"
)

// writeJSON sends value as a JSON body with the given status.
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("write response: %v", err)
	}
}

type errorResponse struct {
	Error string `json:"error"`
}

// writeError sends the contract's error shape: {"error": "..."}.
func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, errorResponse{Error: message})
}
~~~

- `writeJSON` sets the header **before** `WriteHeader`: once the status is written, headers can't change.
- `json.NewEncoder(w).Encode` turns a Go value into JSON and writes it straight to the response, followed by a newline.
- `errorResponse` has one field, and the **struct tag** `json:"error"` gives its JSON name (Foundations 03 lesson 08).
- If writing fails, the client has usually gone away; there's nobody left to tell, so it's logged.

### Step 2: The routes

Create `internal/httpapi/handler.go`:

<!-- file: internal/httpapi/handler.go -->
~~~go
// Package httpapi is Switchyard's HTTP layer: routes, status codes and JSON
// shapes. Every response it sends is JSON, errors included.
package httpapi

import (
	"net/http"
	"strings"
	"unicode/utf8"
)

const maxNameLength = 40

type handlers struct{}

// NewHandler returns Switchyard's routes.
func NewHandler() http.Handler {
	h := &handlers{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", h.health)
	mux.HandleFunc("GET /greet", h.greet)
	return mux
}

type healthResponse struct {
	Status string `json:"status"`
}

func (h *handlers) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, healthResponse{Status: "ok"})
}

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
~~~

- `"GET /health"` is a **pattern** with a method. The router sends only `GET` (and `HEAD`, which is `GET` without the body) to this handler; any other method on `/health` gets `405 Method Not Allowed` with an `Allow` header. Without the method, `"/health"` would accept `DELETE` too.
- The handlers are methods on `handlers`, an empty struct for now. In lesson 08 it gets the job service it needs; methods are how a handler reaches its dependencies without globals.
- `r.URL.Query().Get("name")` reads one query parameter, already decoded from `%20` and friends. A missing parameter is `""`.
- `utf8.RuneCountInString` counts characters, not bytes: "40 characters" means forty `é`s are allowed, though they're 80 bytes (Foundations 02 lesson 03).

### Step 3: The program

Create `cmd/switchyard/main.go`:

<!-- file: cmd/switchyard/main.go -->
~~~go
// Command switchyard runs Switchyard's control plane.
package main

import (
	"log"
	"net/http"
	"time"

	"switchyard/internal/httpapi"
)

func main() {
	srv := &http.Server{
		Addr:              "127.0.0.1:8080",
		Handler:           httpapi.NewHandler(),
		ReadHeaderTimeout: 5 * time.Second, // lesson 02: never leave it unset
	}
	log.Printf("listening on http://%s", srv.Addr)
	log.Fatal(srv.ListenAndServe())
}
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... && go build -o /dev/null ./cmd/switchyard -->

`cmd/switchyard` is where the program lives; `go build ./cmd/switchyard` names the binary `switchyard`. Packages in `internal/` hold everything else, so they can be tested without starting the program. `ReadHeaderTimeout` is set from the start, after lesson 02; lesson 09 sets the rest.

Run it, and try the contract, one request per line (`-w` prints the status after each body):

~~~bash
go build -o /tmp/switchyard ./cmd/switchyard && /tmp/switchyard &
sleep 0.5
for u in /health "/greet?name=Ada" "/greet?name=%20" "/greet?name=$(printf 'a%.0s' {1..41})" /nope; do
  curl -s -w "  [%{http_code}]\n" "http://127.0.0.1:8080$u"
done
curl -si -X POST http://127.0.0.1:8080/health | head -4
kill %1
~~~

~~~text
2026/11/20 02:30:40 listening on http://127.0.0.1:8080
{"status":"ok"}
  [200]
{"greeting":"Hello, Ada!"}
  [200]
{"error":"name must be 1 to 40 characters"}
  [400]
{"error":"name must be 1 to 40 characters"}
  [400]
404 page not found
  [404]
HTTP/1.1 405 Method Not Allowed
Allow: GET, HEAD
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
~~~

`printf 'a%.0s' {1..41}` prints `a` 41 times. Every handler response is JSON; the router's `404` and `405` are its own short text, and the `405` lists `GET, HEAD` in `Allow`.

## Break it

**Drop the method from a pattern.** Change `"GET /health"` to `"/health"`, rebuild and run, and `curl -si -X DELETE http://127.0.0.1:8080/health`: `200 OK`. The contract said only `GET`; the code now accepts anything. The table test in the next lesson catches it. Put `GET` back.

**Count bytes instead of characters.** Change `utf8.RuneCountInString(name)` to `len(name)`, delete the now-unused `"unicode/utf8"` import (or Go won't compile it), and greet `é` repeated 25 times (`curl -s "http://127.0.0.1:8080/greet?name=$(printf '%%C3%%A9%.0s' {1..25})"`): 25 characters, refused, because they're 50 bytes. Put both back.

## Check it

~~~bash
gofmt -l . && go vet ./... && go build ./cmd/switchyard && rm switchyard
~~~

Then, from memory: add `GET /time`, returning `{"time":"..."}` with the current time in RFC 3339 form (`time.Now().UTC().Format(time.RFC3339)`), and try it with `curl`. Remove it afterwards.

That proves the service keeps its contract when you try it by hand. It doesn't prove it keeps it after the next change: the next lesson writes the tests that do.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `use of internal package switchyard/internal/httpapi not allowed` | Importing it from outside the module | Only code in `switchyard` may import `internal/` |
| `panic: pattern "GET /health" ... conflicts with pattern` | The same route registered twice | Register each pattern once |
| Every path returns the health response | A pattern of `"/"` catches everything | Use exact patterns; `"/"` means "anything not matched" |
| `bind: address already in use` | An earlier `/tmp/switchyard` is still running | `pkill -x switchyard` |
| The response has `Content-Type: text/plain` | `Header().Set` after `WriteHeader` | Set headers first |
