# Phase 0 exercises

Do these after the checkpoint in [TEACHING.md](TEACHING.md). Use test-driven development (TDD) for every exercise: write the failing test first (red), make it pass (green), then tidy up (refactor). Do them in your own `kestrel` repository and push each one so CI checks it.

There are no solutions here on purpose. Each exercise says what "done" looks like.

## 1. Name the service in the health response (TDD warm-up)

Change the health contract to `{"status":"ok","service":"kestrel"}`.

1. **Red:** update the expected body in your health tests first. Run `go test` and read the failure.
2. **Green:** add a `Service` field with the right JSON tag.
3. **Refactor:** is the expected JSON now repeated in several tests? Put it in one constant.

**Done when:** the tests pass, `curl` shows the new body, and you can explain why the test failed before the code changed.

## 2. Support HEAD on /health (TDD)

`HEAD` is `GET` without a body. Load balancers often use it to check health cheaply.

- Write a table case expecting `HEAD /health` to return 200. Watch it fail with 405.
- Allow `HEAD` in `health`, and make the `Allow` header on a 405 say `GET, HEAD`.

**Done when:** `curl -I http://127.0.0.1:8080/health` (capital `-I` sends HEAD) shows `200 OK`, and the 405 test checks the new `Allow` value.

## 3. Return JSON errors

Plain-text errors are hard for programs to read. Change every error response to JSON, for example `{"error":"name must be between 1 and 40 characters"}`, with `Content-Type: application/json`.

- Write a helper `writeError(w, status, message)` and replace every `http.Error` call with it.
- Update the table test to check the content type of error responses.

**Done when:** every 400, 404 and 405 response is JSON, including the 404 from the catch-all route.

**Think about:** the router's own 404 for `/unknown` is written by `greet`, so you control it. Which responses would you *not* control if you used a pattern without a catch-all?

## 4. Make the port configurable

Read the listen address from an environment variable named `LISTEN_ADDR`, falling back to `127.0.0.1:8080` when it isn't set.

- Use `os.Getenv`. Keep the logic in a small function, `listenAddressFromEnv()`, so you can test it with `t.Setenv`.
- Try `LISTEN_ADDR=127.0.0.1:9090 go run .` and curl port 9090.

**Done when:** a test covers both the default and the override, and you can explain what an *environment variable* is. Phase 1 builds on this.

## 5. Stretch: reject names with control characters

Decide on a rule, write it down as part of the contract, then implement it test-first. For example, only allow letters, spaces, hyphens and apostrophes. Look at the `unicode` package.

**Done when:** your contract table, your tests and your code all agree, and you can explain one name your rule wrongly rejects. Every validation rule has trade-offs.

## 6. Stretch: compare a router library

Rebuild only `/health` and `/greet` in two tiny throwaway programs, one with [chi](https://github.com/go-chi/chi) and one with [Gin](https://gin-gonic.com/en/docs/quickstart/). Don't change your main service.

**Write down:** what each library does for you that you wrote by hand (method checks, 404/405, reading the query), and what it hides. Which one still uses standard `http.Handler` functions?
