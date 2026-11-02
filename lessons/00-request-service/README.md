# Phase 0: make one request work

**Question:** what actually happens between typing a command and getting an answer from a web service?

**Time:** about 2 weeks at 12–15 hours a week. **Prerequisites:** none. This is the start.

## Syllabus

| Step | Topic | You'll learn |
|---|---|---|
| 0 | The terminal | Commands, flags and arguments, paths, `pwd`/`ls`/`cd`/`mkdir`, Go modules |
| 1 | A program and a process | Packages, functions, compiling, `go run` vs `go build`, compiler errors |
| 2 | Requests and responses | Client and server, methods, paths, headers, bodies, status codes, URLs, ports, loopback |
| 3 | Your first server | Handlers, routes, `ListenAndServe`, the request path, `ss`, pipes, Ctrl+C |
| 4 | A response contract | Structs, JSON, exported fields, method checks, 405 and `Allow`, why `return` matters |
| 5 | A router and validation | `ServeMux` matching rules, the catch-all `/`, query strings, validation, characters vs bytes |
| 6 | Tests at three levels | Handler tests, table-driven router tests, real-connection tests, TDD, `gofmt`/`vet`/`-race` |
| 7 | Your own repo and CI | Git, GitHub, a GitHub Actions workflow, a red-then-green history |

## What you'll be able to do

- Use a terminal to move around, run programs, and inspect a running process and its port.
- Read and write a small Go program: packages, functions, structs, errors, constants.
- Explain an HTTP request and response: method, path, query, status, headers, body.
- Explain how Go's router picks a handler, and where the method is checked.
- Validate untrusted input, and say what validation does and doesn't protect against.
- Write handler tests, table-driven router tests and a real-connection test, and say what each proves.
- Keep your work reproducible with Git and GitHub Actions.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md) in order, typing every piece of code yourself in `practice/`.
2. Answer [learned.md](learned.md) from your own observations as you go.
3. Rebuild the service from memory in your own `runway` repository (step 7).
4. Build the exercise project, **[tempconv](exercises.md)**, a temperature-conversion service, on your own. The exercise page describes exactly what the finished service does.
5. Take the [self-test](../../notes/learned/00-request-service.md) without notes.

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where in the lesson | Evidence you'll have |
|---|---|---|
| Shell basics: paths, commands, pipes | Steps 0 and 3 | Commands in your notes; `ss` output showing your process |
| Program vs process | Steps 1 and 3 | `go build` + `./hello`; `ss -ltnp` |
| HTTP fundamentals | Steps 2–5 | curl transcripts for 200, 400, 404 and 405 |
| Go basics | Steps 1–6 | Your working service, and tempconv |
| Testing and TDD | Step 6 and the exercise | A red-then-green test run |
| Git, GitHub and CI | Step 7 | A red-then-green CI history in your own repository |
| First input-validation habit | Step 5 and the exercise | Boundary tests (40/41 characters, 0 K) |

## Patterns introduced

These link to the [patterns ledger](../../JOURNEY.md#6-patterns-ledger):

- **Guard clauses:** check, reject and `return` early.
- **Table-driven tests:** many cases, one loop.
- **Test-driven development:** red, green, refactor.

## Next

[Phase 1](../01-reliable-service/README.md) turns this into a jobs service that many clients use at once. Overlapping requests, slow work, bad input and shutting down all start to matter.
