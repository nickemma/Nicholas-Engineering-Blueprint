# Phase 1 exercises

Do these in your own `kestrel` repository after the checkpoint. Use TDD for every one: a failing test first. Each exercise says what "done" looks like. There are no solutions on purpose.

## 1. Cancel a queued job

Add `POST /jobs/{id}/cancel`. Only a `queued` job may be cancelled, and it moves to a new state, `cancelled`.

- Start in the domain: add the state and the transition to `allowed`, plus a `Cancel` method, with table tests for every legal and illegal transition.
- Add `Service.Cancel` using compare-and-swap, then the handler.

**Done when:** cancelling a running or completed job returns 409; two concurrent cancels produce exactly one success (adapt `slowGetRepository`); `Run` on a cancelled job returns 409.

## 2. JSON for the router's own errors

The router's 404 and 405 responses are plain text. Make every response JSON.

- Hint: you can't change the router's messages, but you can catch them. One way is a catch-all route, `mux.HandleFunc("/", ...)`, for 404s. 405s are harder: think about what middleware could see.

**Done when:** a table test checks that every error status this API can return has `Content-Type: application/json`.

## 3. List jobs with pagination

Add `GET /jobs?state=queued&limit=20&after=40`.

- Add a `List(ctx, filter)` method to `Repository`. Every implementation must now provide it, which is the cost of a wide interface. Is there a smaller design?
- Validate the query parameters: an unknown state returns 400; `limit` must be between 1 and 100.
- Return the results in ID order, plus the `next` cursor.

**Done when:** 250 jobs come back in exactly 13 pages with no duplicates and none missing, and the test proves it.

## 4. Limit concurrent runs (a first look at saturation)

Allow at most `MAX_CONCURRENT_RUNS` (default 4) runs at once. Further run requests get `503 Service Unavailable` with a `Retry-After: 1` header, not a queue.

- Hint: a buffered channel of size N works as a semaphore. Use a non-blocking `select` with `default`.
- Add a gauge metric, `jobs_running`.

**Done when:** a test starts N+1 slow runs and sees exactly one 503, and `jobs_running` goes back to 0 afterwards. Explain why rejecting is better than queueing here. (Phase 2 comes back to this as **backpressure**.)

## 5. A request ID through logs

Give each request an ID: take it from an incoming `X-Request-ID` header if present (validated), or generate one. Return it in the response header and include it in every log line for that request.

- Hint: store it in the context with a private key type, and use `slog`'s `With` to build a logger per request.

**Done when:** a test sends two concurrent requests and checks that each one's log lines carry only its own ID.

## 6. Stretch: an idle-timeout experiment

Write a tiny client that opens a TCP connection to the server and sends one header byte every 2 seconds.

**Done when:** you can show, with timestamps, the server closing the connection after `ReadHeaderTimeout`, and explain what would happen without it.
