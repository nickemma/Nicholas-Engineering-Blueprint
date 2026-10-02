# Phase 0 learning record — request service

Complete this after building the lesson in `lesson-01/`. Write from memory in your own words; do not copy the walkthrough. Attach command output or a short note showing where each claim was verified.

## What I built

- What the greeting server does:
- What `/health` does:
- How `/greet` handles a valid name, and what it rejects:
- What the server returns for a wrong path or method:
- How I ran the service and tested it:

## How a request travels

Explain the path from the `curl` command through the listening server, route/mux, handler, response, and back to `curl`. Name which part runs once at startup and which part runs for each request.

My explanation:

## What I think I learned

- A program versus a running process:
- What the listener and port do:
- How the method and path select behavior:
- Why request input is checked before being used:
- What the handler writes and how status codes are chosen:
- What `httptest` proves, and what `curl` proves:
- Why the handler returns immediately after writing an error:

## Evidence

| Claim | Evidence or command | Result |
|---|---|---|
| Greeting route works | | |
| Valid greeting input works; missing or overlong input is rejected | | |
| Health route returns JSON and `200` | | |
| Unknown path returns `404`; unsupported method returns `405` | | |
| Tests pass | | |
| Changing the expected health response makes a test fail, and restoring it makes the test pass | | |
| The test workflow runs in CI | | |

## Phase 0 task checklist

- [ ] I can run the project from its lesson folder after a clean checkout.
- [ ] I can exercise the routes with `curl` and describe the responses.
- [ ] I can change the response, update or observe a failing test, and repair it.
- [ ] I can explain the request flow without reading the walkthrough.
- [ ] Formatting, tests, and the CI check pass.
- [ ] I recorded one design choice or behavior I would improve next.

## Next-day transfer to Kestrel

Complete this only after Phase 0 is reviewed. Rebuild the same behavior in Kestrel from memory, without copying the lesson files. Then record:

- What I recreated without help:
- What I had to look up:
- Test and `curl` evidence:
- What differed from the learning build and why:
- What I want reviewed:

## Still unclear / next question

- What still feels uncertain:
- What I want reviewed:
- What I will try to reproduce from memory tomorrow:
