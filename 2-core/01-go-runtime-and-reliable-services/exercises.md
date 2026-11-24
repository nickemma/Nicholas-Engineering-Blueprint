# Exercises: Go runtime and reliable services

Each exercise is a different project that uses this module's ideas, so you can't just retrace the lessons. There's no solution code: each page describes exactly what the finished project does, so you always know what you're aiming at. Lessons 13–16 have no exercise of their own; the module's gate is their test.

## Exercise 1: `tempconv`, a temperature-conversion service (after lesson 04)

1. **What you're building:** a small web service, in a new repository, that converts temperatures between Celsius (`C`), Fahrenheit (`F`) and Kelvin (`K`). A caller sends a value and two units, and gets the converted value back as JSON. It rejects anything it can't convert, with a clear reason. It uses lessons 03 and 04 (routing, method checks, JSON, input validation, three levels of tests, CI) on a problem they never showed you.
2. **The finished result:**

   | Request | Response |
   |---|---|
   | `GET /health` | `200`, `Content-Type: application/json`, body `{"status":"ok"}` |
   | `GET /convert?value=V&from=U1&to=U2` | `200`, `Content-Type: application/json`, body `{"value":V,"from":"U1","to":"U2","result":R}` |
   | `/convert` with `value` missing or not a number | `400`, body `value must be a number` |
   | `/convert` with `from` or `to` missing, or not one of `C`, `F`, `K` | `400`, body `unit must be one of C, F, K` |
   | `/convert` where the input is below absolute zero (below 0 K) | `400`, body `temperature is below absolute zero` |
   | Any method other than GET or HEAD on `/health` or `/convert` | `405`, with header `Allow: GET, HEAD` (what lesson 03's method-aware routes give you) |
   | Any other path, including `/` | `404` |

   - Conversions use the standard formulas: F = C × 9/5 + 32, and K = C + 273.15.
   - `result` is **rounded to 2 decimal places**. Floating-point arithmetic isn't exact: 98.6 °F converts to 36.99999999999999 °C before rounding, and must be reported as `37`.
   - Converting a unit to itself is allowed and returns the same value.
   - Units are case-sensitive: `c` is rejected.
   - The service listens on `127.0.0.1:8080` and uses its own `ServeMux`, built by a function your tests can call.

   Files:

   - `main.go`, with one handler per route, a `newMux()` function, and conversion logic in plain functions that know nothing about HTTP (for example, `toCelsius(value, unit)` and `fromCelsius(value, unit)`).
   - `main_test.go`, with tests at all three levels: the conversion functions, the router (a table test), and one real connection (`httptest.NewServer`).
   - `.github/workflows/test.yml`, running `gofmt`, `go vet` and `go test -race` on every push.
3. **A sample session,** with the finished service running:

   ~~~text
   $ curl -i 'http://127.0.0.1:8080/convert?value=100&from=C&to=F'
   HTTP/1.1 200 OK
   Content-Type: application/json

   {"value":100,"from":"C","to":"F","result":212}

   $ curl -s 'http://127.0.0.1:8080/convert?value=98.6&from=F&to=C'
   {"value":98.6,"from":"F","to":"C","result":37}

   $ curl -s 'http://127.0.0.1:8080/convert?value=0&from=K&to=C'
   {"value":0,"from":"K","to":"C","result":-273.15}

   $ curl -s 'http://127.0.0.1:8080/convert?value=300&from=K&to=F'
   {"value":300,"from":"K","to":"F","result":80.33}

   $ curl -i 'http://127.0.0.1:8080/convert?value=-300&from=C&to=K'
   HTTP/1.1 400 Bad Request

   temperature is below absolute zero

   $ curl -i 'http://127.0.0.1:8080/convert?value=hot&from=C&to=F'
   HTTP/1.1 400 Bad Request

   value must be a number

   $ curl -i 'http://127.0.0.1:8080/convert?value=10&from=C&to=X'
   HTTP/1.1 400 Bad Request

   unit must be one of C, F, K

   $ curl -i -X POST 'http://127.0.0.1:8080/convert?value=10&from=C&to=F'
   HTTP/1.1 405 Method Not Allowed
   Allow: GET, HEAD

   Method Not Allowed

   $ curl -i http://127.0.0.1:8080/
   HTTP/1.1 404 Not Found

   404 page not found
   ~~~

   Other headers, such as `Date` and `Content-Length`, are left out above; yours will have them.
4. **Done when:**

   1. Every row of the contract table has at least one test.
   2. The conversion functions have table tests covering all six unit pairs, plus same-unit conversions.
   3. The router test includes the boundaries: exactly 0 K is accepted, and anything below it is rejected.
   4. The rounding case `98.6 F → C = 37` has a test.
   5. One test starts a real server with `httptest.NewServer` and calls `/convert` over a real connection.
   6. Every command in the sample session produces the output shown.
   7. `gofmt -l .` prints nothing, and `go vet ./...` and `go test -race ./...` pass.
   8. Your repository's CI run is green, and its history shows one red run that you fixed.
5. **Stretch goals:**

   - Accept lowercase units too (`c`, `f`, `k`), and decide whether the response echoes the input or the canonical uppercase form. Write the rule down, then test it.
   - Add `GET /units`, returning `[{"symbol":"C","name":"Celsius"}, ...]`.
   - Return errors as JSON (`{"error":"..."}`) with `Content-Type: application/json`, and make every error test check the content type.
6. **Hints:** reading the query, validating and returning early is lesson 03's `greet`; the `Allow` header and `405` come from the router (lesson 03); `strconv.ParseFloat` turns text into a number and returns an error if it can't; for rounding, look up `math.Round` and think about how to round to 2 places, not 0. Lesson 04 has the three test levels and the CI workflow.

## Exercise 2: `shortlinks`, a URL shortener (after lesson 12)

1. **What you're building:** a service that turns long URLs into short aliases. `POST /links` stores a URL under an alias, either one you choose or a generated one. Visiting `/r/{alias}` redirects to the URL and counts the visit. Many users create links and follow them at once, and the service must stay exact: an alias is never given out twice, and no visit is lost. It uses lessons 05–12: layers and ports, a domain with rules, a race a mutex can't fix, strict JSON, deadlines, logs and metrics, graceful shutdown.
2. **The finished result:**

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

   Structure:

   ~~~text
   cmd/shortlinks/main.go          composition root: config, wiring, server, graceful shutdown
   internal/links/link.go          domain: Link, Alias and URL value objects, validation
   internal/links/repository.go    the Repository port the domain needs
   internal/links/service.go       use cases: Create, Get, Visit, Delete
   internal/memstore/store.go      an in-memory adapter: map plus mutex
   internal/httpapi/               handlers, strict JSON, middleware, metrics
   ~~~

   The domain imports nothing from `httpapi` or `memstore`. The service receives its repository, clock and alias generator through its constructor, so tests can inject fixed ones.
3. **A sample session:**

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
4. **Done when:**

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
5. **Stretch goals:**

   - Add `expires_at` to `POST /links`. Expired links return `410 Gone`. Inject the clock so the test doesn't wait.
   - Rate-limit `POST /links` to 10 per second per client IP, returning `429` with `Retry-After` (look up the token-bucket algorithm).
   - Add `GET /links?limit=20&after=go-docs` with stable cursor pagination.
6. **Hints:** "claim an alias exactly once" is a check-then-act problem: revisit lesson 07, where what made the job safe wasn't the mutex. "No lost visits" is a read-modify-write problem: where should the `+1` happen so that it's under one lock? `net/url.Parse` parses URLs, and its result has `Scheme` and `Host` fields. `crypto/rand` generates random aliases; think about what happens on a collision. `http.Redirect(w, r, url, http.StatusFound)` writes a redirect.
