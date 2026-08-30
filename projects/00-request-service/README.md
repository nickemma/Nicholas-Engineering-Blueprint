# Request service

The first building block of the platform: a Go program that listens on a network port and reports whether it is healthy.

## Run it

Open a terminal in this folder and run:

```bash
go run .
```

Leave that terminal running. In a second terminal, run:

```bash
curl -i http://localhost:8080/health
```

You should receive `HTTP/1.1 200 OK` and this body:

```json
{"status":"ok"}
```

Stop the server with `Ctrl+C`. Run the automated checks with:

```bash
go test ./...
```

## What you just made

Think of the server as a receptionist.

1. `main` starts the receptionist at port `8080`.
2. The `mux` is its directory: `/health` points to the `health` function.
3. `curl` sends an HTTP request to that address.
4. Go gives the request to `health`.
5. `health` writes JSON back, and `curl` prints the response.

The full request path is:

```text
curl → your computer's network stack → Go server → mux → health handler → JSON response → curl
```

You do not need to understand every part of that path yet. Today, the important ideas are:

- A **program** is instructions saved in `main.go`.
- A **process** is that program while `go run .` is executing it.
- A **server** is a process waiting for requests.
- A **port** is a numbered door on a computer; this server uses door `8080`.
- An **HTTP request** asks for a path such as `/health`.
- A **handler** is the function chosen to answer that request.

## Your first change

In `main.go`, add a `Service` field to `healthResponse` and return the value `"request-service"`. Then update `TestHealth` so `go test ./...` passes again.

Before changing the code, predict the result: **the service will still run, but the test will fail because it expects the old JSON.** That is the learning loop: predict, change, observe, explain.
