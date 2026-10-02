# Request service

The Phase 0 learning project: start with a small Go greeting server, then add a health endpoint, basic request validation, and tests. The finished service in this folder is the reference result; build the lesson in [`lesson-01/`](lesson-01/WORKTHROUGH.md) and record your understanding in [`learned.md`](learned.md).

## Phase 0 build checklist

Build and understand these behaviors in the lesson workspace:

- `GET /` returns a greeting.
- `GET /greet?name=Ada` returns a personalized greeting; missing or overlong names are rejected with HTTP `400`.
- `GET /health` returns HTTP `200` and `{"status":"ok"}` as JSON.
- unsupported methods are rejected with HTTP `405`; an unknown path returns HTTP `404`.
- tests use Go's `httptest` package to check success and rejected requests.
- `curl` confirms the running server behaves as expected; a deliberately changed response makes a test fail, then you repair it.
- the project is formatted, runs from a clean checkout, and its tests pass in CI.

Phase 0 is complete when you can run the service and tests, explain the request path from `curl` to handler and back, show the failure-and-repair exercise, and record your own explanation and evidence in `learned.md`. The phase gate is also listed in [the roadmap](../../plan/structure.md#phases).

## Lesson flow

Read [`lesson-01/WORKTHROUGH.md`](lesson-01/WORKTHROUGH.md) from top to bottom and build each step in the `lesson-01` directory. The `main.go` and `main_test.go` beside this README are the finished reference; do not use them as a substitute for building the lesson.

## Run it

Open a terminal in this folder and run:

```bash
go run .
```

Leave that terminal running. In a second terminal, run:

```bash
curl -i http://localhost:8080/
curl -i http://localhost:8080/health
```

The root request returns `Hello from the request service!`. The health request should return `HTTP/1.1 200 OK` and this body:

```json
{"status":"ok"}
```

Stop the server with `Ctrl+C`. Run the automated checks with:

```bash
go test ./...
```

## What you just made

Think of the server as a receptionist.

1. `main` starts the receptionist at port `8080`.
2. The `mux` is its directory: `/`, `/greet`, and `/health` point to their handlers.
3. `curl` sends an HTTP request to that address.
4. Go gives the request to the handler selected by the path and method.
5. The handler writes a greeting, an error, or health JSON back, and `curl` prints the response.

The full request path is:

```text
curl → your computer's network stack → Go server → mux → selected handler → HTTP response → curl
```

You do not need to understand every part of that path yet. Today, the important ideas are:

- A **program** is instructions saved in `main.go`.
- A **process** is that program while `go run .` is executing it.
- A **server** is a process waiting for requests.
- A **port** is a numbered door on a computer; this server uses door `8080`.
- An **HTTP request** asks for a path such as `/health` or `/greet?name=Ada`.
- A **handler** is the function chosen to answer that request.

## Your first change

In `main.go`, add a `Service` field to `healthResponse` and return the value `"request-service"`. Then update `TestHealth` so `go test ./...` passes again.

Before changing the code, predict the result: **the service will still run, but the test will fail because it expects the old JSON.** That is the learning loop: predict, change, observe, explain.
