# Phase 1: Make one service reliable

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: full code in `steps/`, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This is a self-study lesson. Work through it in order. Every new idea is explained before you use it, and every build step has a check that tells you what its result means. Keep this lesson open while you work in a separate practice folder.

## The goal

Turn the Phase 0 HTTP server into a small jobs service. A client can submit a job, receive its ID, and ask for its current state. The service must behave predictably when requests overlap, input is wrong, a request takes too long, or the process is stopped.

At the end, you will be able to explain why the service is reliable within one running process and why its jobs disappear when that process exits. Phase 3 will make them durable.

## Before you start

Finish Phase 0 and be able to run a Go program, start the server, use a second terminal, call it with curl, and explain a handler. You need Go, Git, Bash, and curl. Check them:

~~~bash
go version
git --version
curl --version
pwd
~~~

Each command prints a version or the current directory. If a command is missing, stop and install that tool before continuing. The shell is the program that reads these commands; a command name runs a program, and text after it supplies options or input.

Create a practice copy without changing the Phase 0 reference:

~~~bash
cd lessons/01-reliable-service
mkdir -p practice
cd practice
go mod init kestrel-phase1
~~~

The first command selects the Phase 1 folder. The second makes a child folder; the third enters it; the fourth gives Go's package tools a module to build. If your checkout is in another place, use that checkout's path. Create the source files below in this practice folder.

## 1. Agree on what a job means

A job is a piece of work with an identity and a state. For this lesson use these states:

~~~text
queued → running → completed
                 ↘ failed
~~~

The arrow means a permitted state change. A client does not choose the final state; the service owns that transition. The API contract is:

| Request | Success | Common error |
|---|---|---|
| GET /health | 200 and `{"status":"ok"}` while the process can serve requests | none in the healthy local exercise |
| POST /jobs with a JSON object | 201 and a job with a new ID and queued state | 400 for malformed or missing input; 413 for an oversized body |
| GET /jobs/{id} | 200 and the matching job | 404 when no such job exists |
| POST /jobs/{id}/complete | 200 and completed state | 404 for an unknown ID; 409 if the job is already in a state that cannot complete |

An HTTP status is part of the contract, not decoration. The JSON body carries the structured result. Write these examples into your notes before coding. This prevents implementation choices from silently changing what a caller can rely on.

Add a Job type with an integer ID, a state string, a short description, and creation/update timestamps. Add a Store type with a map from ID to Job, a next-ID counter, and a mutex. A map stores key/value pairs. A mutex is a lock that lets only one goroutine at a time change shared data.

Use this exact small layout in the practice folder:

~~~text
go.mod
main.go                 server creation and route registration
store.go                Job, Store, Create, Get, Complete
main_test.go            store and HTTP tests
~~~

Keep the first version in these four files so the request path stays visible. In store.go, implement these contracts:

- Create(description) allocates a new unique ID, stores a queued job, and returns that job.
- Get(id) returns the job and true if present, otherwise the zero value and false.
- Complete(id) returns not-found for an unknown ID, conflict for a job outside queued/running, and the updated job when it succeeds.
- Every access to the map and next-ID counter uses the same Store mutex.

Use JSON field names id, state, description, created_at, and updated_at. Keep the time values in UTC. The API contract and the Store contract now describe the same behavior.

## 2. Implement the API before concurrency

Create the API with Go's standard net/http package. Start with one goroutine and the routes above. For POST, decode exactly one JSON object, reject unknown fields, require a non-empty description, and cap the request body at 1 KiB. Return the created job as JSON. For GET, parse the path ID as an integer and return 404 if it is absent. For complete, update only a queued or running job.

Keep Phase 0's GET /health route and response so the service and later deployment have a health check. Register the routes on an http.ServeMux using the method-aware patterns GET /health, POST /jobs, GET /jobs/{id}, and POST /jobs/{id}/complete. In each handler, follow the same order: validate method/path inputs, decode or parse, call one Store method, translate its result to an HTTP status, set Content-Type to application/json, encode one response, and return. Do not let HTTP handlers write directly to the job map.

For POST, wrap the body with http.MaxBytesReader before decoding. Call Decoder.DisallowUnknownFields. After decoding the first JSON value, attempt to decode a second value and require end-of-file; otherwise a caller could append a second object that the handler silently ignores. Return 400 for malformed, empty, unknown-field, or invalid-description input and 413 when the body exceeds 1 KiB.

Create these tests before adding simulated work:

| Test name | Action | Expected result |
|---|---|---|
| TestHealth | GET /health | 200 and `{"status":"ok"}` |
| TestCreateThenGet | POST a valid description, then GET the returned ID | 201, then 200 with the same description |
| TestCreateRejectsInvalidBody | Send malformed JSON, empty description, unknown field, and oversized body | 400/413 as specified |
| TestGetUnknownJob | GET a valid-looking ID that is absent | 404 |
| TestCompleteJob | Create, then complete | 200 and state completed |
| TestCompleteTwice | Complete the same job twice | first 200, second 409 |
| TestConcurrentCreateIDsAreUnique | Start many goroutines that call Create | all IDs differ and all jobs can be fetched |

Use httptest.NewRequest and httptest.NewRecorder for handler tests. These call the handler in the test process; they do not open a TCP socket or prove the running server is reachable. curl tests that distinction later.

Go's standard library router in the current Go release can match an HTTP method and a path pattern such as POST /jobs and GET /jobs/{id}. The request method answers “what action is being asked for?” The path answers “which resource or operation?” Together they select the handler.

In the handler, use the request's context when calling the Store. A context carries cancellation and an optional deadline. If the client disconnects or the deadline expires, downstream work can stop instead of running forever. Set a server read-header timeout and request-body limit; a reliable service limits how long and how much it is willing to accept.

Make the listen address configurable so later container and isolated-network exercises can reach the same API without changing the default local behavior. Add `os` and `time` to the imports, then replace the final `http.ListenAndServe` call with:

~~~go
listenAddress := os.Getenv("LISTEN_ADDR")
if listenAddress == "" {
    listenAddress = "127.0.0.1:8080"
}
server := &http.Server{
    Addr:              listenAddress,
    Handler:           mux,
    ReadHeaderTimeout: 5 * time.Second,
    IdleTimeout:       60 * time.Second,
}
if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
    log.Fatal(err)
}
~~~

The loopback default keeps this beginner exercise on this computer; Phase 5 will deliberately set a different address for a disposable interface. Phase 1's graceful-shutdown step will replace the final error handling with the signal-and-shutdown sequence.

Start the server:

~~~bash
go run .
~~~

It should print its listening address and keep running. In a second terminal in the same practice folder, send a job:

~~~bash
curl -i -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"hello"}'
~~~

Expect status 201 and JSON containing an ID and state queued. Copy the returned ID and request it:

~~~bash
curl -i http://127.0.0.1:8080/jobs/1
~~~

If your ID differs, use the one returned by POST. Expect status 200 and the same description and state. Restart the process and ask for that ID again. Expect 404. The map belonged to the old process's memory; restarting discarded it. This is intentional for Phase 1.

Try an empty body, malformed JSON, a missing description, an unknown ID, an unsupported method, and a body larger than the limit. Before each curl call, predict the status. The expected outcomes are 400, 400, 400, 404, 405, and 413. If yours differ, inspect which condition runs first and correct the contract.

For a successful POST, expect a response shaped like this (the numeric ID and times vary):

~~~json
{"id":1,"state":"queued","description":"hello","created_at":"...","updated_at":"..."}
~~~

For a second completion attempt, expect 409 Conflict because the request is understandable but the current job state does not permit it. This differs from 404, where the identified resource does not exist.

## 3. See the race before fixing it

The Go HTTP server can call handlers for separate requests at the same time. Each call may run in its own goroutine, which is a unit of work scheduled by Go's runtime. Goroutines share the process's memory. If two handlers update the map at once without coordination, their reads and writes can overlap; that is a data race.

Add a test that submits many jobs concurrently and checks that every ID is unique and every stored job can be fetched. Run:

~~~bash
go test ./...
go test -race ./...
~~~

The first command runs package tests. The second also asks Go's race detector to report conflicting concurrent memory access. Temporarily remove the mutex from one map operation and run the second command again. A race report is evidence of an unsafe overlap; it does not prove the rest of the program race-free. Restore the lock before continuing.

Protect every map read and write with the same mutex. Use a write lock for changes and a read lock for fetches. Do not hold the lock while encoding a response, waiting on a timer, or doing unrelated work; a lock held too long blocks other requests.

Use defer immediately after acquiring a lock so an early return still releases it. The critical section should contain only the map/counter operation. Re-run TestConcurrentCreateIDsAreUnique and go test -race ./... after every change to the Store.

## 4. Add timeouts and cancellation

Add a small simulated job operation that waits for a configured duration. Use a timer and select on both the timer and the request context's Done channel. The timer path returns a result; the cancellation path stops work and returns a timeout/cancellation result.

Set the client's timeout:

~~~bash
curl --max-time 1 -i -X POST http://127.0.0.1:8080/jobs -H 'Content-Type: application/json' -d '{"description":"slow"}'
~~~

Make the simulated operation take longer than one second. curl should report that its deadline expired. Then send a normal request and confirm the server still handles it. A client timeout does not prove the server stopped; the context check and a test that observes cancellation provide that evidence.

Read the matching OSTEP and CSAPP selections in “Read beside the build” after you have seen overlapping requests and process memory. Use them to answer: what state is shared, what a lock protects, and why a goroutine is not a separate process?

## 5. Stop without corrupting service state

Replace the minimal listener with an http.Server. Configure read-header and idle timeouts. Start it in the foreground. On Ctrl+C, catch SIGINT/SIGTERM, call Server.Shutdown with a deadline, and wait for active handlers to finish.

Run these in another terminal while the service is active:

~~~bash
ps -ef | rg kestrel-phase1
ss -ltn
~~~

ps lists processes; rg filters the displayed lines; ss shows listening TCP sockets; -l asks for listeners and -t asks for TCP. You should see one service process and port 8080 listening. Stop it with Ctrl+C. The listener should disappear, and the program should exit without leaving a child process.

Send several requests while stopping the server. A graceful shutdown stops accepting new connections and gives active handlers a short period to finish. If the deadline expires, remaining work is cancelled. Record which request completed and which did not; do not describe graceful shutdown as “the server never loses work.”

## 6. Add operational evidence and a basic security check

Log one structured record for each request with method, route, status, and duration. Do not log request bodies, names, tokens, or other unnecessary user data. Track at least total requests and rejected requests as counters. A metric is a number collected over time; it is useful only when its name and labels explain what is counted.

Threat-check the API:

- Send a JSON object larger than 1 KiB and confirm it is rejected before unbounded allocation.
- Send an unknown field and confirm it is rejected.
- Send a path with an invalid ID and confirm a clear 400 or 404 according to your written contract.
- Confirm logs contain no submitted description or credentials.

For routing breadth, compare the same GET /health route in the standard library, chi, and Gin in separate tiny files after the main service works. chi is a router that uses standard net/http handlers. Gin is a framework with its own context and binding helpers. The lesson service stays on net/http so the request, handler, and response remain visible. This is a short comparison, not three versions of KESTREL.

## Evidence gate

Do not advance because the code runs once. Save:

1. A test showing POST creates a job and GET returns it.
2. Tests for invalid input, unknown IDs, and an invalid state transition.
3. A passing go test -race ./... after the unsafe version has been detected and repaired.
4. A curl timeout/cancellation result and a graceful shutdown observation.
5. A short note explaining which facts are in memory and what disappears at restart.

Answer the Phase 1 questions in learned.md from your own observations. Then close the guide and code for the transfer exercise: in your Kestrel checkout, implement the API from the contract table and your notes. Do not copy the lesson files. You may look up Go language or library documentation, because the goal is to reconstruct the design and explain it, not memorize syntax. Compare behavior only after you have recorded your implementation and curl/test evidence.

## Read beside the build

Read one selection after the matching behavior appears. You do not need to finish a book before continuing.

| When | Read | Carry this question into the reading |
|---|---|---|
| Before shared-state work | OSTEP, Chapters 26–28 | What is shared, and which operation must be protected as one unit? |
| After inducing and repairing a race | OSTEP, Chapters 29–30 and 32; CSAPP, 3rd ed., Chapter 12 §§12.1 and 12.3–12.7 | What interleaving made the result wrong, and how does the lock change it? |
| Before graceful shutdown | CSAPP, Chapter 8 §§8.1–8.2 and 8.4–8.5; OSTEP, Chapter 5 | What does the process receive when you press Ctrl+C, and which work must finish before exit? |
| After adding metrics | *Site Reliability Engineering*, Chapter 6; *Understanding Distributed Systems*, Part IV section on downstream resiliency/timeouts | Which signal reflects a caller-visible problem, and what deadline bounds the work? |
| After the service works | DDIA, Chapter 1; *The Web Application Hacker's Handbook*, Chapter 2; Anderson's *Security Engineering*, Chapter 1 | How do reliability, security assumptions, and hostile input change what “works” means? |

Official references: [Go context](https://pkg.go.dev/context), [Go HTTP server](https://pkg.go.dev/net/http), [chi project documentation](https://github.com/go-chi/chi), and [Gin quickstart](https://gin-gonic.com/en/docs/quickstart/).
