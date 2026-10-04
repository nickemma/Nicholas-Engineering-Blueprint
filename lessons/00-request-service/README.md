# Phase 0: make one request work

**Question:** what actually happens between typing a command and getting an answer from a web service?

**You build:** a Go HTTP service with `GET /`, `GET /greet?name=...` and `GET /health`. It validates its input, has tests at three levels, and runs CI in your own GitHub repository.

**Time:** about 2 weeks at 12–15 hours a week. **Prerequisites:** none.

| File | Use it for |
|---|---|
| [TEACHING.md](TEACHING.md) | The lesson. Start here and follow it in order |
| [steps/](steps) | A runnable snapshot after each step. Compare your work with these; don't copy them |
| [exercises.md](exercises.md) | Test-driven exercises for after the checkpoint |
| [learned.md](learned.md) | The answer sheet you fill in from your own observations |

## What you'll be able to do

- Use a terminal to move around, run programs and inspect a running process and its port.
- Read and write a small Go program: packages, functions, structs, errors and constants.
- Explain an HTTP request and response: method, path, query, status, headers and body.
- Explain how Go's router picks a handler, and where the method is checked.
- Validate untrusted input, and say what validation does and doesn't protect against.
- Write handler tests, table-driven router tests and a real-connection test, and say what each proves.
- Use Git and GitHub Actions to keep your work reproducible.

## Gaps this phase closes

These rows link back to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where in the lesson | Evidence you'll have |
|---|---|---|
| Shell basics: paths, commands, pipes | Steps 0 and 3 | Commands in your notes; `ss` output showing your process |
| Program vs process | Steps 1 and 3 | `go build` + `./hello`; `ss -ltnp` |
| HTTP fundamentals | Steps 2–5 | curl transcripts for 200, 400, 404 and 405 |
| Go basics | Steps 1–6 | Your working service |
| Testing and TDD | Step 6 and exercises | A red-then-green test run |
| Git, GitHub and CI | Step 7 | A red-then-green CI history in your own repository |
| First input-validation habit | Step 5 | Boundary tests at 40 and 41 characters |

## Patterns introduced

These link to the [patterns ledger](../../JOURNEY.md#6-patterns-ledger).

- **Table-driven tests:** many cases, one loop.
- **Test-driven development:** red, green, refactor.
- **Guard clauses:** check, reject and `return` early, so the main logic below never sees bad input.

## Run the finished service

~~~bash
cd lessons/00-request-service/steps/05-tests
go test -v ./...
go run .
~~~

In a second terminal, run `curl -i http://127.0.0.1:8080/health`.

## Next

Phase 1 turns this into a jobs service that many clients use at once. Overlapping requests, slow work, bad input and shutting down all start to matter. Continue with [Phase 1](../01-reliable-service/README.md).
