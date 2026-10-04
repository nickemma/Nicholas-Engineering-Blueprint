# Phase 0 learning record — request service

Complete this after working through the guided teaching in `TEACHING.md`. Write from memory in your own words; use the explanations in the guide while learning, then explain the ideas in your own words. Attach command output or a short note showing where each claim was verified.

## What I built

- What the greeting server does: It return the value with the request service up
- What `/health` does: checks if the status is ok
- How `/greet` handles a valid name, and what it rejects: with argument passed for example name=ada, and it rejects if the name argument is not passed or is more than 40 characters long
- What the server returns for a wrong path or method: 404 not found
- How I ran the service and tested it: i ran go run . and on the second terminal tested it using curl -i http://localhost:8080/

## How a request travels

Explain the path from the `curl` command through the listening server, route/mux, handler, response, and back to `curl`. Name which part runs once at startup and which part runs for each request.

My explanation:

## What I think I learned

- A program versus a running process: A program is the list of instruction we gave to the code for example main.go and a process is how/when we run the program
- What the listener and port do: the listener listens to the numbered door the port points to from the server
- How the method and path select behavior: I don't understand this?
- Why request input is checked before being used: so it returns the actual thing we want rather than taking any form sent
- What the handler writes and how status codes are chosen: the handler write the functions we choose while the status code returns the value we want the user to see/understand
- What `httptest` proves, and what `curl` proves: httptest proves that what the program write is correct and curl is how we check it against the running process
- Why the handler returns immediately after writing an error: because of the return we want to close/stop immediately after an error so it doesn't try to retry till it produceses success which is then a lie

## Evidence

| Claim | Evidence or command | Result |
|---|---|---|
| Greeting route works |yes or curl -i http://localhost:8080/| HTTP/1.1 200 OK|
| Valid greeting input works; missing or overlong input is rejected |yes or curl -i 'http://localhost:8080/greet?name=Emma!' | HTTP/1.1 200 OK (Hello, Emma!)|
| Health route returns JSON and `200` |yes (HTTP/1.1 200 OK) |{"status":"ok"} |
| Unknown path returns `404`; unsupported method returns `405` |yes | 404 page not found |
| Tests pass |yes |yes |
| Changing the expected health response makes a test fail, and restoring it makes the test pass |yes | yes |
| The test workflow runs in CI | yes |pass |

## Phase 0 task checklist

- [x] I can run the project from its lesson folder after a clean checkout.
- [x] I can exercise the routes with `curl` and describe the responses.
- [x] I can change the response, update or observe a failing test, and repair it.
- [x] I can explain the request flow without reading the walkthrough.
- [x] Formatting, tests, and the CI check pass.
- [x] I recorded one design choice or behavior I would improve next.

## Next-day transfer to Kestrel

Complete this only after Phase 0 is reviewed. Rebuild the same behavior in Kestrel from memory, without copying the lesson files. Then record:

- What I recreated without help: The healthcheck
- What I had to look up: mux
- Test and `curl` evidence: curl -i http://localhost:8080/health
- What differed from the learning build and why: Nothing
- What I want reviewed: flow

## Still unclear / next question

- What still feels uncertain: nothing
- What I want reviewed: mux vs gin/chi
- What I will try to reproduce from memory tomorrow: I tried a post method and it works fine
