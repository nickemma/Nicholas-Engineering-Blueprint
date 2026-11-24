# 04 Tests at three levels, and CI

> Module: Go runtime and reliable services · Time: ~5 h · Builds on: 03

## The problem

You checked the contract by hand with `curl`. That proves it worked once, today. Every later lesson changes Switchyard, and each change can break a promise you've stopped looking at. Tests check every promise on every change, in seconds. But a test only proves what it exercises: one that calls a handler directly can't notice a broken route, and one that goes through the router can't notice a server that never starts. So you'll test at three levels and know what each proves, then have GitHub run them on every push.

## The mental model

~~~text
 level 1: handler test       h.health(recorder, request)          the handler's logic
 level 2: router table       NewHandler().ServeHTTP(recorder, ...) routes, methods, every rule
 level 3: real connection    httptest.NewServer + http.Get        bytes over a real TCP connection
 by hand:                    /tmp/switchyard + curl               the real program starts and listens
 CI:                         all of it, on a clean machine, on every push
~~~

## The pattern

**Red, green, refactor.** From the next lesson on, every rule is built test-first: write the test, watch it fail (**red**: the failure proves the test can catch the problem), write the least code that passes (**green**), then tidy up with the test as a safety net (**refactor**). This is test-driven development (TDD).

## Build it

### Step 1: A handler test

`net/http/httptest` provides a fake request (`httptest.NewRequest`) and a **recorder** (`httptest.NewRecorder`), a `ResponseWriter` that keeps whatever the handler writes so the test can inspect it. Create `internal/httpapi/handler_test.go` with the first level:

<!-- file: internal/httpapi/handler_test.go -->
~~~go
package httpapi

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Level 1: call one handler directly. No router, no network.
func TestHealth(t *testing.T) {
	h := &handlers{}
	rec := httptest.NewRecorder()
	h.health(rec, httptest.NewRequest(http.MethodGet, "/health", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got)
	}
	var body healthResponse
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Status != "ok" {
		t.Errorf("status field = %q, want ok", body.Status)
	}
}
~~~

A test in the same package (`package httpapi`) can call unexported things like `h.health` and `healthResponse`: this tests the handler alone, with no router in the way.

### Step 2: A router table

Add the second level, every row of the contract through the real router:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
// Level 2: every route and rule, through the real router, as a table.
func TestRoutes(t *testing.T) {
	long := strings.Repeat("a", maxNameLength+1)
	tests := []struct {
		name, method, target string
		wantStatus           int
		wantBody             string
	}{
		{"health", "GET", "/health", 200, `{"status":"ok"}`},
		{"greet", "GET", "/greet?name=Ada", 200, `{"greeting":"Hello, Ada!"}`},
		{"spaces trimmed", "GET", "/greet?name=%20Ada%20", 200, `{"greeting":"Hello, Ada!"}`},
		{"40 characters, not bytes", "GET", "/greet?name=" + strings.Repeat("%C3%A9", 40), 200, ""},
		{"no name", "GET", "/greet", 400, `{"error":"name must be 1 to 40 characters"}`},
		{"blank name", "GET", "/greet?name=%20%20", 400, `{"error":"name must be 1 to 40 characters"}`},
		{"name too long", "GET", "/greet?name=" + long, 400, `{"error":"name must be 1 to 40 characters"}`},
		{"wrong method", "POST", "/health", 405, ""},
		{"unknown path", "GET", "/nope", 404, ""},
	}
	handler := NewHandler()
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, httptest.NewRequest(tt.method, tt.target, nil))
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tt.wantStatus)
			}
			if got := strings.TrimSpace(rec.Body.String()); tt.wantBody != "" && got != tt.wantBody {
				t.Errorf("body = %s, want %s", got, tt.wantBody)
			}
		})
	}
}
~~~

- `handler.ServeHTTP(rec, req)` is exactly what the server calls for each request; here the test calls it, with no network.
- `%C3%A9` is `é` in a URL; forty of them must pass, though they're 80 bytes.
- Rows with an empty `wantBody` check only the status: the router's own `404` and `405` texts aren't part of the contract.

### Step 3: A real connection

And the third level:

<!-- append: internal/httpapi/handler_test.go -->
~~~go
// Level 3: a real server on a real port, and a real HTTP client.
func TestOverRealConnection(t *testing.T) {
	srv := httptest.NewServer(NewHandler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/greet?name=Ada")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || strings.TrimSpace(string(body)) != `{"greeting":"Hello, Ada!"}` {
		t.Fatalf("got %d %s", resp.StatusCode, body)
	}
}
~~~

`httptest.NewServer` starts a real `http.Server` on a free port of `127.0.0.1`, and `srv.URL` is its address. `http.Get` is Go's HTTP client: this request crosses a real TCP connection, through the same parsing you wrote by hand in lesson 02.

~~~bash
go test -v ./internal/httpapi 2>&1 | grep -E "^(=== RUN|--- |ok|FAIL)"
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... && go test -race -count=1 ./... -->

~~~text
=== RUN   TestHealth
--- PASS: TestHealth (0.00s)
=== RUN   TestRoutes
=== RUN   TestRoutes/health
=== RUN   TestRoutes/greet
=== RUN   TestRoutes/spaces_trimmed
=== RUN   TestRoutes/40_characters,_not_bytes
=== RUN   TestRoutes/no_name
=== RUN   TestRoutes/blank_name
=== RUN   TestRoutes/name_too_long
=== RUN   TestRoutes/wrong_method
=== RUN   TestRoutes/unknown_path
--- PASS: TestRoutes (0.00s)
=== RUN   TestOverRealConnection
--- PASS: TestOverRealConnection (0.01s)
ok  	switchyard/internal/httpapi	0.013s
~~~

Each `t.Run` row is its own subtest, named after the row, so a failure names exactly which promise broke.

### What each level proves

| Check | Proves | Doesn't prove |
|---|---|---|
| Handler test | The handler's logic: status, headers, body | That any route reaches it |
| Router table | Every route, method and rule of the contract | That bytes cross a real connection |
| Real connection | The service works over real HTTP | That `main` starts and listens on 8080 |
| `curl` against the program | The real program starts and answers | Any case you didn't try |

The everyday checks, before every commit:

~~~bash
gofmt -l . && go vet ./... && go test -race -cover ./...
~~~

~~~text
	switchyard/cmd/switchyard		coverage: 0.0% of statements
ok  	switchyard/drills/byhand	1.124s	coverage: 55.0% of statements
ok  	switchyard/drills/escape	1.088s	coverage: 0.0% of statements [no tests to run]
	switchyard/drills/gc		coverage: 0.0% of statements
	switchyard/drills/sched		coverage: 0.0% of statements
	switchyard/drills/spin		coverage: 0.0% of statements
	switchyard/drills/stacks		coverage: 0.0% of statements
	switchyard/drills/stdhttp		coverage: 0.0% of statements
ok  	switchyard/internal/httpapi	1.031s	coverage: 93.8% of statements
~~~

`-cover` reports how much of each package's code the tests ran. Your drills from lessons 01–02 are packages too, so they're listed. `cmd/switchyard` has no tests and shows 0%: `main` is checked by running it. Coverage shows what *wasn't* exercised; it isn't a score to maximise. `-race` turns on the race detector (Go from zero lesson 10), which matters from lesson 06 on.

### Step 4: A test that fails first

TDD in miniature. The contract gains a promise: `/health` also says which service answered, `{"status":"ok","service":"switchyard"}`. Write the test first, by changing the expected body in the `health` row of `TestRoutes`:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
		{"health", "GET", "/health", 200, `{"status":"ok"}`},
~~~

~~~go
		{"health", "GET", "/health", 200, `{"status":"ok","service":"switchyard"}`},
~~~

~~~bash
go test ./internal/httpapi
~~~

<!-- run: ! go test -count=1 ./internal/httpapi > /dev/null 2>&1 -->

~~~text
--- FAIL: TestRoutes (0.00s)
    --- FAIL: TestRoutes/health (0.00s)
        handler_test.go:60: body = {"status":"ok"}, want {"status":"ok","service":"switchyard"}
FAIL
FAIL	switchyard/internal/httpapi	0.010s
FAIL
~~~

Red, and the failure says exactly what's missing. Now the least code that passes. In `handler.go`:

<!-- edit: internal/httpapi/handler.go -->
~~~go
type healthResponse struct {
	Status string `json:"status"`
}
~~~

~~~go
type healthResponse struct {
	Status  string `json:"status"`
	Service string `json:"service"`
}
~~~

<!-- edit: internal/httpapi/handler.go -->
~~~go
	writeJSON(w, http.StatusOK, healthResponse{Status: "ok"})
~~~

~~~go
	writeJSON(w, http.StatusOK, healthResponse{Status: "ok", Service: "switchyard"})
~~~

~~~bash
go test ./internal/httpapi
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go test -count=1 ./internal/httpapi -->

~~~text
ok  	switchyard/internal/httpapi	0.012s
~~~

Green. Nothing to refactor this time. That's the loop you'll use for every rule from now on.

### Step 5: Your own repository and CI

Switchyard belongs in your own Git repository, and its tests should run on a clean machine every time you push: **continuous integration** (CI). You used Git in Foundations 02. Create `.github/workflows/test.yml`:

<!-- file: .github/workflows/test.yml -->
~~~yaml
name: Test

on:
  push:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-go@v7
        with:
          go-version-file: go.mod
      - run: test -z "$(gofmt -l .)"
      - run: go vet ./...
      - run: go test -race ./...
~~~

- `on` lists the events that start the workflow: every push and pull request.
- `runs-on` asks GitHub for a fresh Ubuntu machine. `actions/checkout` fetches your code, and `actions/setup-go` installs the Go version from your `go.mod`.
- Each `run` is a shell command; if one fails, the run fails. `test -z "$(gofmt -l .)"` fails if any file isn't formatted.

Commit it all:

~~~bash
cd ~/blueprint/switchyard
git init -q && git add . && git commit -q -m "Switchyard: an HTTP service with a contract, tests and CI" && git log --stat --oneline
~~~

~~~text
5acd580 Switchyard: an HTTP service with a contract, tests and CI
 .github/workflows/test.yml       |  17 +++++++
 cmd/switchyard/main.go           |  20 ++++++++
 drills/byhand/main.go            |  70 ++++++++++++++++++++++++++
 drills/byhand/request.go         | 104 +++++++++++++++++++++++++++++++++++++++
 drills/byhand/request_test.go    |  58 ++++++++++++++++++++++
 drills/escape/escape.go          |  30 +++++++++++
 drills/escape/escape_test.go     |  35 +++++++++++++
 drills/gc/main.go                |  28 +++++++++++
 drills/sched/main.go             |  25 ++++++++++
 drills/spin/main.go              |  21 ++++++++
 drills/stacks/main.go            |  49 ++++++++++++++++++
 drills/stdhttp/main.go           |  38 ++++++++++++++
 go.mod                           |   3 ++
 internal/httpapi/handler.go      |  44 +++++++++++++++++
 internal/httpapi/handler_test.go |  80 ++++++++++++++++++++++++++++++
 internal/httpapi/json.go         |  25 ++++++++++
 16 files changed, 647 insertions(+)
~~~

`git add .` is safe here because everything in the folder belongs in the repository. Then, on GitHub, create an empty repository named `switchyard` (no README, no licence), and push:

~~~bash
git branch -M main
git remote add origin git@github.com:YOUR-USERNAME/switchyard.git
git push -u origin main
~~~

> **Run this yourself.** It needs your GitHub account, so the lesson can't show a captured run. **Expected:** on GitHub, the **Actions** tab shows a run named "Test" that turns green within a minute or two. Open it to see each step.

If the push is refused, set up an SSH key with GitHub's guide, [Connecting to GitHub with SSH](https://docs.github.com/en/authentication/connecting-to-github-with-ssh).

## Break it

**Break the contract, and watch CI catch it.** Change `"ok"` to `"ready"` in `health`, commit and push. The run turns red; open the failing step and find the same message `go test` printed on your machine. Put it back, push, and see green. A red run followed by a green one is a record anyone can check.

**Delete the method from a pattern** (the first "Break it" of lesson 03). This time you don't need `curl`: `go test` fails on the `wrong method` row.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race ./...
~~~

From memory, test-first: add a row to `TestRoutes` for `GET /greet?name=Ada%20Lovelace`, predict the body, run the test, and make it pass if it doesn't.

That proves the contract on every push. It doesn't prove anything about requests that overlap: from lesson 06 on, the race detector and concurrent tests take care of that.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `no test files` | The file isn't named `*_test.go`, or it's in the wrong folder | `internal/httpapi/handler_test.go` |
| `undefined: handlers` in the test | The test file says `package httpapi_test` | Use `package httpapi` to reach unexported names |
| A table row passes when it shouldn't | `wantBody` left empty, so only the status is checked | Fill it in for every handler response |
| The CI run is red but tests pass locally | Formatting, a file not committed, or a different Go version | Read the failing step; `git status`; check `go.mod` |
| `Permission denied (publickey)` on push | No SSH key on GitHub | Follow GitHub's SSH guide |
