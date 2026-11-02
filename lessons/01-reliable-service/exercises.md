# Phase 1 exercise: shortlinks, a URL shortener

Build this **on your own**, in a new repository (or a new folder of your `runway` repository), after the [checkpoint](TEACHING.md#checkpoint). It uses every Phase 1 idea on a new problem:
- layers, ports and adapters, and dependency injection;
- a domain with rules;
- a race the mutex can't fix;
- strict JSON, deadlines, logs and metrics;
- graceful shutdown.

There's no solution in this repository. This page describes exactly what the finished service does.

## What you're building

`shortlinks` turns long URLs into short aliases. `POST /links` stores a URL under an alias, either one you choose or a generated one. Visiting `/r/{alias}` redirects to the URL and counts the visit. Many users can create links and follow them at once, and the service must stay exact: an alias is never given out twice, and no visit is lost.

## The finished result

### Contract

| Request | Success | Errors |
|---|---|---|
| `GET /health` | `200` `{"status":"ok"}` | — |
| `POST /links` with `{"url": "...", "alias": "..."}` (alias optional) | `201`, the link as JSON, and `Location: /links/{alias}` | `400` invalid URL or alias; `409` alias already taken; `413` body over 4 KiB; `415` not `application/json` |
| `GET /links/{alias}` | `200`, the link as JSON | `404` no such alias |
| `GET /r/{alias}` | `302 Found`, `Location: <the url>`, and the link's `visits` goes up by exactly 1 | `404` no such alias |
| `DELETE /links/{alias}` | `204 No Content` | `404` no such alias |
| Wrong method on a known path | — | `405` with `Allow` |

All error bodies are JSON: `{"error":"..."}`.

The link's JSON shape:

~~~json
{"alias":"go-docs","url":"https://go.dev/doc/","visits":0,"created_at":"2026-10-04T12:00:00Z"}
~~~

### Rules

- `url` must be an absolute `http` or `https` URL with a host, at most 2,048 characters. Anything else is a 400 with `{"error":"url must be an absolute http or https URL"}`.
- `alias`, if given, must be 3–32 characters from `a-z`, `0-9` and `-`. Anything else is a 400 with `{"error":"alias must be 3-32 characters of a-z, 0-9 and -"}`.
- A generated alias is 7 random characters from `a-z` and `0-9`. If it collides with an existing one, try again; it must never overwrite.
- **An alias is claimed exactly once.** If 100 requests try to create the same alias at the same moment, exactly one gets `201` and the other 99 get `409`.
- **No visit is lost.** After 1,000 concurrent requests to `/r/{alias}`, `visits` is exactly 1,000.
- Every request has a deadline (`REQUEST_TIMEOUT`, default `2s`). The server has read-header, read, write and idle timeouts.
- The service logs one JSON line per request (method, route pattern, status, duration), and **never logs URLs**: they can contain private tokens.
- `/metrics` exposes `http_requests_total{route,method,code}`, `http_request_duration_seconds`, and `links_created_total`.
- SIGTERM and SIGINT trigger a graceful shutdown, bounded by `SHUTDOWN_GRACE` (default `10s`).
- Configuration comes from the environment: `LISTEN_ADDR` (default `127.0.0.1:8080`), `REQUEST_TIMEOUT` and `SHUTDOWN_GRACE`. Bad values stop the service at startup with a clear message.

### Structure

~~~text
cmd/shortlinks/main.go          composition root: config, wiring, server, graceful shutdown
internal/links/link.go          domain: Link, Alias and URL value objects, validation
internal/links/repository.go    the Repository port the domain needs
internal/links/service.go       use cases: Create, Get, Visit, Delete
internal/memstore/store.go      an in-memory adapter: map plus mutex
internal/httpapi/               handlers, strict JSON, middleware, metrics
~~~

The domain imports nothing from `httpapi` or `memstore`. The service receives its repository, clock and alias generator through its constructor, so tests can inject fixed ones.

## Sample session

~~~text
$ curl -i -X POST http://127.0.0.1:8080/links -H 'Content-Type: application/json' \
    -d '{"url":"https://go.dev/doc/","alias":"go-docs"}'
HTTP/1.1 201 Created
Content-Type: application/json
Location: /links/go-docs

{"alias":"go-docs","url":"https://go.dev/doc/","visits":0,"created_at":"2026-10-04T12:00:00Z"}

$ curl -i -X POST http://127.0.0.1:8080/links -H 'Content-Type: application/json' \
    -d '{"url":"https://example.com/","alias":"go-docs"}'
HTTP/1.1 409 Conflict

{"error":"alias already taken"}

$ curl -s -X POST http://127.0.0.1:8080/links -H 'Content-Type: application/json' -d '{"url":"https://example.com/"}'
{"alias":"k3x9q2a","url":"https://example.com/","visits":0,"created_at":"2026-10-04T12:00:01Z"}

$ curl -i http://127.0.0.1:8080/r/go-docs
HTTP/1.1 302 Found
Location: https://go.dev/doc/

$ curl -s http://127.0.0.1:8080/links/go-docs
{"alias":"go-docs","url":"https://go.dev/doc/","visits":1,"created_at":"2026-10-04T12:00:00Z"}

$ curl -i -X POST http://127.0.0.1:8080/links -H 'Content-Type: application/json' -d '{"url":"ftp://x"}'
HTTP/1.1 400 Bad Request

{"error":"url must be an absolute http or https URL"}

$ curl -i -X POST http://127.0.0.1:8080/links -H 'Content-Type: application/json' -d '{"url":"https://x.org","alias":"No Spaces!"}'
HTTP/1.1 400 Bad Request

{"error":"alias must be 3-32 characters of a-z, 0-9 and -"}

$ curl -i -X DELETE http://127.0.0.1:8080/links/go-docs
HTTP/1.1 204 No Content

$ curl -i http://127.0.0.1:8080/r/go-docs
HTTP/1.1 404 Not Found

{"error":"link not found"}
~~~

The generated alias (`k3x9q2a`) and the timestamps will differ. Every other part of each response must match.

## Acceptance checks

You're done when all of these are true:

1. Every row of the contract table has a test.
2. The domain has table tests for URL and alias validation, including both sides of every length limit.
3. **Alias race:** a test runs 100 goroutines that create the same alias, and asserts exactly one 201 and 99 409s. It fails if you remove your concurrency protection, even when run without `-race`. (Hint: you may need to widen the race window the way `slowGetRepository` did.)
4. **Visit counter:** a test makes 1,000 concurrent visits, then asserts `visits == 1000`, under `go test -race`.
5. A deadline test: with a repository that stalls longer than `REQUEST_TIMEOUT`, the request returns promptly with an error status, not after the stall.
6. A log test proves URLs never appear in log output.
7. A metrics test reads `/metrics` and finds `links_created_total`.
8. A graceful-shutdown test proves an in-flight request finishes after shutdown begins.
9. Every command in the sample session behaves as shown.
10. `gofmt`, `go vet` and `go test -race ./...` pass, and CI is green.

## Stretch goals

- Add `expires_at` to `POST /links`. Expired links return `410 Gone`. Inject the clock so the test doesn't wait.
- Rate-limit `POST /links` to 10 per second per client IP, returning `429` with `Retry-After` (look up the token-bucket algorithm).
- Add `GET /links?limit=20&after=go-docs` with stable cursor pagination.

## Hints

- "Claim an alias exactly once" is a check-then-act problem. Revisit step 3: what made `Run` safe wasn't the mutex.
- "No lost visits" is a read-modify-write problem. Where should the `+1` happen so that it's under one lock?
- `net/url.Parse` parses URLs, and its result has `Scheme` and `Host` fields.
- `crypto/rand` generates random aliases; think about what happens on a collision.
- `http.Redirect(w, r, url, http.StatusFound)` writes a redirect.
