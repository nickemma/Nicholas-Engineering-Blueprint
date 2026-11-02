# Phase 0 exercise: tempconv, a temperature-conversion service

Build this **on your own**, in a new repository, after the [checkpoint](TEACHING.md#checkpoint-are-you-ready-for-phase-1). It uses every idea from Phase 0 (a Go HTTP server, routing, method checks, JSON, input validation, three levels of tests, CI), but on a problem the guide never showed you. There's no solution anywhere in this repository, on purpose. This page describes exactly what the finished service does, so you always know what you're aiming at.

## What you're building

`tempconv` is a small web service that converts temperatures between Celsius (`C`), Fahrenheit (`F`) and Kelvin (`K`). A caller sends a value and two units, and gets the converted value back as JSON. It rejects anything it can't convert, with a clear reason.

## The finished result

### Contract

| Request | Response |
|---|---|
| `GET /health` | `200`, `Content-Type: application/json`, body `{"status":"ok"}` |
| `GET /convert?value=V&from=U1&to=U2` | `200`, `Content-Type: application/json`, body `{"value":V,"from":"U1","to":"U2","result":R}` |
| `/convert` with `value` missing or not a number | `400`, body `value must be a number` |
| `/convert` with `from` or `to` missing, or not one of `C`, `F`, `K` | `400`, body `unit must be one of C, F, K` |
| `/convert` where the input is below absolute zero (below 0 K) | `400`, body `temperature is below absolute zero` |
| Any method other than GET on `/health` or `/convert` | `405`, with header `Allow: GET` |
| Any other path, including `/` | `404` |

### Rules

- Conversions use the standard formulas: F = C × 9/5 + 32, and K = C + 273.15.
- `result` is **rounded to 2 decimal places**. Floating-point arithmetic isn't exact: 98.6 °F converts to 36.99999999999999 °C before rounding, and must be reported as `37`.
- Converting a unit to itself is allowed and returns the same value.
- Units are case-sensitive: `c` is rejected.
- The service listens on `127.0.0.1:8080` and uses its own `ServeMux`, built by a function your tests can call.

### Structure

- `main.go`, with one handler per route, a `newMux()` function, and conversion logic in plain functions that know nothing about HTTP (for example, `toCelsius(value, unit)` and `fromCelsius(value, unit)`).
- `main_test.go`, with tests at all three levels: the conversion functions, the router (a table test), and one real connection (`httptest.NewServer`).
- `.github/workflows/test.yml`, running `gofmt`, `go vet` and `go test -race` on every push.

## Sample session

With the finished service running:

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
Allow: GET

method not allowed

$ curl -i http://127.0.0.1:8080/
HTTP/1.1 404 Not Found

404 page not found
~~~

Other headers, such as `Date` and `Content-Length`, are left out above; yours will have them.

## Acceptance checks

You're done when all of these are true:

1. Every row of the contract table has at least one test.
2. The conversion functions have table tests covering all six unit pairs, plus same-unit conversions.
3. The router test includes the boundaries: exactly 0 K is accepted, and anything below it is rejected.
4. The rounding case `98.6 F → C = 37` has a test.
5. One test starts a real server with `httptest.NewServer` and calls `/convert` over a real connection.
6. Every command in the sample session produces the output shown.
7. `gofmt -l .` prints nothing, and `go vet ./...` and `go test -race ./...` pass.
8. Your repository's CI run is green, and its history shows one red run that you fixed.

## Stretch goals

- Accept lowercase units too (`c`, `f`, `k`), and decide whether the response echoes the input or the canonical uppercase form. Write the rule down, then test it.
- Add `GET /units`, returning `[{"symbol":"C","name":"Celsius"}, ...]`.
- Return errors as JSON (`{"error":"..."}`) with `Content-Type: application/json`, and make every error test check the content type.

## Hints

These point back to the guide; they aren't code.

- Reading the query, validating, and returning early: step 5 (`greetName`).
- The `Allow` header and 405: step 4.
- Why `/` matches everything, and how to return 404 for it: step 5 (routing rules).
- Rounding: look up `math.Round` and think about how to round to 2 places, not 0.
- `strconv.ParseFloat` turns text into a number and returns an error if it can't.
