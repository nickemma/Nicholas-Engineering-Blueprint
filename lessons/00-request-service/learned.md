# Phase 0: what I learned

Fill this in as you finish each step of [TEACHING.md](TEACHING.md), then again from memory after the rebuild in step 7. Write in your own words. Every claim needs evidence: a command and what it printed, a test name, or a link to a CI run. Keep your copy in your own `runway` repository; this file in the Blueprint is the blank template.

## Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | What is the difference between a program and a process? What did `go run .` do that `go build` didn't? | | |
| 3 | Walk the request path from curl to `health` and back. Which line registers the route, which starts the server, and when does `health` actually run? | | |
| 3 | Why did `fmt.Println` send an empty body? | | |
| 3 | Why did the step 3 server answer `POST /health` with 200? | | |
| 4 | Why is the status code part of the contract? | | |
| 4 | What exactly happened when you deleted `return` after `http.Error`? | | |
| 4 | Why must headers be set before the body? | | |
| 5 | For `GET /greet?name=Ada`, which patterns match, which handler runs, and why? | | |
| 5 | Why does `greet` check `r.URL.Path` itself? | | |
| 5 | Why count characters (runes) rather than bytes? Give an input where it matters. | | |
| 6 | What does each test level prove, and what does it not prove? | | |
| 6 | Why test both 40 and 41 characters? | | |
| 7 | What does CI prove that your local `go test` doesn't? | | |

## Evidence checklist

| Claim | Command or link | Result |
|---|---|---|
| `GET /` returns the greeting | | |
| `GET /greet?name=Ada` returns `Hello, Ada!`; missing, blank and 41-character names return 400 | | |
| `GET /health` returns 200 and JSON | | |
| An unknown path returns 404; `POST /health` returns 405 with `Allow: GET` | | |
| `gofmt -l .`, `go vet ./...` and `go test -race ./...` are clean | | |
| A deliberate change made a test fail; restoring it made the test pass | | |
| CI on my own repository went red, then green | | |

## Rebuild from memory (step 7)

- What I rebuilt without help:
- What I had to look up, and where:
- How my rebuild differs from the guide, and why:
- What is still unclear:
