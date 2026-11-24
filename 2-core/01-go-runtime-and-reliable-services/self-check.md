# Self-check: Go runtime and reliable services

## Explain it

Answer in your own words. Where you can, point at something you ran.

### 01 How Go runs your code

1. How many threads did 10,000 sleeping goroutines need? Why so few?
2. What happens to a goroutine that loops without ever blocking, and what changed in Go 1.14?
3. Why did `newPoint` allocate and `newPointInlined` not?
4. `GOGC=400` collected less often than `GOGC=50`, yet spent twice the `sys` time. Where did that time go?
5. What do `GOGC` and `GOMEMLIMIT` each trade, and which would you set for a service in a 1 GiB container?

### 02 HTTP/1.1 by hand

1. How does a server know where one request ends and the next begins on a kept-alive connection?
2. Why must a server refuse a request it can't frame with certainty, instead of guessing?
3. What did the default `http.Server` do with a client that sent half a request, and which setting fixed it?

### 03 An HTTP service with a contract

1. What does the router answer for a known path with the wrong method, and which header does it add?
2. Why are `writeJSON` and `writeError` the only ways a handler writes a response?

### 04 Tests at three levels, and CI

1. What does each level prove that the one below it doesn't: a handler test, a router table test, a test over a real connection?
2. Why must a new test fail before you make it pass?
3. What does coverage tell you, and what doesn't it?

### 05 The domain, written test-first

1. Why do the domain's methods take `now` instead of calling `time.Now()`?
2. What does a `Description` type buy you over a plain `string`?
3. Why is the state machine a table (`allowed`) rather than `if` statements, and how did lesson 16 change it?

### 06 A repository, and your first data race

1. Why does `jobs` define `Repository`, instead of `memstore`?
2. Why store jobs by value?
3. A race report proves a bug. What does a clean run prove?

### 07 A race a mutex can't fix

1. Draw the check-then-act race. Why doesn't the mutex prevent it? Why doesn't `-race` detect it?
2. How does compare-and-swap fix it, and what does the losing caller get?
3. What does `context.WithoutCancel` protect against?

### 08 The HTTP API

1. Why does `httpapi` define `JobService` instead of using `*jobs.Service`?
2. What's the difference between `400`, `409` and `500` here?
3. What did `DisallowUnknownFields` stop, and why is a silent `201` dangerous?

### 09 Wiring and configuration

1. What is the composition root, and why does only `main` create concrete types?
2. Which server timeout defends against the half-sent request from lesson 02?
3. Why does a bad setting stop the service at startup instead of at the first request?

### 10 Deadlines and cancellation

1. Trace a client disconnect from the socket down to the work. What stops, and in what order?
2. What's the difference between the `504` case and the client-timeout case, from the server's point of view?
3. Why couldn't the deadline stop the work that used `time.Sleep`?

### 11 Logs, metrics and panic recovery

1. Why log the route pattern rather than the path?
2. Name the four golden signals and which metric gives each one.
3. Why does the order of middleware change behaviour, not just style?

### 12 Signals and graceful shutdown

1. What's the difference between SIGINT, SIGTERM and SIGKILL, and which can a program handle?
2. Why is the shutdown context built from `context.Background()`?
3. What does graceful shutdown not protect?

### 13 Worker pools and backpressure

1. State Little's law, and use it: with 4 workers and 1-second jobs, how long does the last job in a full 100-slot queue wait?
2. In your measurement, how did the queue depth sampled from `/metrics` compare with λ × W, and why are they independent measurements?
3. Why `503` and not `429`? What does a refused job look like in `GET /jobs/{id}`?
4. Why does a bounded queue protect callers that an unbounded one doesn't?

### 14 Timeouts, retries and idempotency

1. Why must claiming an idempotency key and checking it happen under one lock? Why are 5xx responses not remembered?
2. Why jitter, and not just backoff? Why do retries stop at the job's deadline?
3. A job says `failed`: did its effect happen?
4. Why must an effect's key be derived from the job, not from the attempt?

### 15 gRPC and Protocol Buffers

1. Why are protobuf field numbers permanent, but field names free to change?
2. Map each of `InvalidArgument`, `NotFound` and `Unavailable` to the HTTP status this API uses for the same situation.
3. How does a deadline set by `jobsctl` reach the server?
4. When would you choose gRPC over JSON, and when not?

### 16 The reconciliation loop

1. Why can't the control plane tell a dead worker from a slow one?
2. What does a fencing token protect against that a lease alone doesn't?
3. Why is the reconcile loop level-triggered, and what would an edge-triggered one ("when a worker dies, requeue its jobs") miss?
4. A job's work ran twice: why does it have one effect?
5. Why is a stopped job not reported by its worker?

## From memory

Close the lessons. Without notes:

1. Write an HTTP handler, with tests at all three levels, for `GET /square?n=7` that returns `{"n":7,"square":49}` and `400` for anything that isn't an integer.
2. Write a store with a compare-and-swap `Update(item, expectedVersion)`, and a test in which 20 goroutines race to change one item and exactly one wins. Run it with `-race`.
3. Write a function that runs an operation with a deadline and up to 5 attempts, with exponential backoff and full jitter, and a test that proves it stops at the deadline without sleeping for real.
4. Draw Switchyard's control plane and one worker, with every message between them (register, lease, heartbeat, complete), and mark where a fencing token is checked. Then explain, step by step, what happens when the worker is killed half-way through a job.

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
