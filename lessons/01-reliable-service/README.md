# Phase 1: make one service reliable

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: full code in `steps/`, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This page previews the concepts, tools, readings, and exit evidence. Follow the full [self-study teaching guide](TEACHING.md) and record your work in [learned.md](learned.md).

The complete read-at-the-right-time list is embedded at the end of [TEACHING.md](TEACHING.md). You can study the guide without looking up chapters in another document.

## Question and build

Can one Go service accept and track jobs safely when requests overlap, take too long, or the process is asked to stop?

Grow the Phase 0 server into an in-memory jobs API with POST /jobs and GET /jobs/{id}. State is volatile by design; Phase 3 will make it durable.

## Teach in this order

1. **Define the job contract.** Explain a job as data with an ID and state. Introduce Go structs, JSON request/response bodies, status codes, and error cases before implementing the routes.
2. **Make requests have a deadline.** Introduce context as a cancellation/deadline signal carried through a request. Add timeouts and explain what the caller sees when work takes too long.
3. **Allow requests to overlap.** Demonstrate two requests arriving at once. Explain goroutines and shared memory before protecting the map with a mutex. Use tests to expose and then repair a race.
4. **Bound resource use.** Read configuration from environment variables. Add structured logs and basic request/job metrics, defining each field before using it.
5. **Stop without abandoning work.** Run the server as a process; inspect it with ps/lsof. Explain Ctrl+C, SIGTERM, file descriptors, and graceful shutdown. Load it while stopping.
6. **Threat-check the API.** Try malformed or hostile inputs and confirm limits, timeouts, and error behavior.

At each step, show the expected output, name what the test proves, and include a diagnosis example before asking for an explanation.

## Foundations closed

- Processes, signals, file descriptors, limits, and Linux process inspection.
- Concurrency, goroutines, mutexes, and Go race detection.
- Context cancellation, timeouts, and first threat-modeling habits.
- Continued Bash, Git, HTTP, and Go practice.

Networking internals, durable storage, and multi-node behavior remain for later phases.

## Reading placement

- Before shared-state work: OSTEP Chapters 26–28.
- After inducing a race: OSTEP Chapters 29–30 and 32; CSAPP Chapter 12 §§12.1 and 12.3–12.7.
- Before shutdown: CSAPP Chapter 8 sections on processes and signals; OSTEP Chapter 5 process API as needed.
- After metrics: SRE Chapter 6; read timeout sections in *Understanding Distributed Systems* when adding deadlines.
- After the service works: DDIA Chapter 1. Read the API-security and Security Engineering selections after input/error handling.

## Exit evidence and career signal

Show a concurrent request, a rejected request, a race check, and graceful shutdown under load. Save a short operational note with the expected and observed result.

This strengthens backend engineering evidence and introduces SRE language such as timeouts and golden signals. It does not yet establish on-call experience or durable job processing.
