# The journey

## Destination

Become a Distributed Systems & AI Infrastructure Engineer who can design, build, secure, operate, and clearly explain a production-grade distributed AI platform.

## Why this path is different

The previous material was comprehensive, but it asked you to hold too much at once: nineteen stages, many subjects, multiple projects, and a large reading list before there was a clear starting point.

This version has one story: **a request enters a system, useful work happens, data survives, the system keeps working when machines fail, and eventually it serves AI models safely for many users.** We will learn each layer when our current system needs it.

The rule is simple: **one active phase, one project, one next problem.**

## The path at a glance

```text
0. Make one request work
1. Make one service reliable
2. Make services work together
3. Make data survive
4. Make state survive multiple machines
5. Run it like a production system
6. Serve a model through it
7. Turn it into a shared AI platform
8. Prove it is secure and resilient
```

Each phase produces a working piece of the same evolving platform. We will not create the next project folder until we reach that phase.

## Phases

| Phase | Question we answer | What we build | What we learn only when needed | Proof before moving on |
|---|---|---|---|---|
| 0 — Start | Can I make and inspect a program that handles a request? | A tiny Go HTTP service with a health endpoint. | Terminal, Git, Go basics, files, HTTP, tests. | Run it, call it with `curl`, change it, and explain the request path. |
| 1 — Reliable service | How does one service handle real requests without falling over? | A small API that accepts and tracks work. | Data modelling, errors, contexts, concurrency, configuration, logs, metrics, timeouts. | Show a concurrent request, a bad request, and a graceful shutdown. |
| 2 — Services together | What changes when work happens in another process or machine? | The API plus a background worker and a simple queue. | Client/server boundaries, HTTP or gRPC, queues, retries, idempotency, backpressure. | Kill the worker, restart it, and show that a job is handled safely. |
| 3 — Durable data | How does the system remember correctly after a crash? | A durable job store, first with a real database and then a small append-only experiment. | Transactions, indexes, write-ahead logs, recovery, isolation, backups. | Stop the process during a write and recover a consistent result. |
| 4 — Distributed state | What fails when state lives on several machines? | A small three-node metadata/key-value service. | Replication, partial failure, clocks, consistency, leader election, consensus. | Disconnect or kill nodes and explain which guarantees still hold. |
| 5 — Operations | How do I run and diagnose this system for real? | The service stack containerized and deployed with observability. | Containers, Kubernetes fundamentals, CI/CD, metrics, traces, logs, SLOs, alerting, capacity. | Find and repair a deliberately introduced production-style incident using a runbook. |
| 6 — Model serving | What is different about serving an LLM? | A model runtime behind the existing gateway, with streaming responses. | Tokens, context windows, prefill/decode, GPU basics, latency and throughput. | Measure time-to-first-token, tokens per second, and the bottleneck. |
| 7 — AI platform | How do many teams use models safely and economically? | A multi-tenant AI gateway with authentication, quotas, routing, metering, and retrieval. | Tenant isolation, rate limits, budgets, caching, batching, model routing, autoscaling. | Demonstrate that a noisy tenant cannot exceed its limit or starve another tenant. |
| 8 — Capstone | Can I defend the whole system under failure and attack? | A deployed, documented AI platform with a design review. | Threat modelling, secrets, identity, authorization, mTLS, supply chain, chaos testing, incident response. | Present the architecture, handle failure scenarios, and show the security and operations evidence. |

## How a phase works

Every phase follows the same short loop:

1. **See it work.** We begin with a small runnable example; no theory dump.
2. **Build it together.** You make one bounded change at a time.
3. **Name the idea.** Once you have felt the problem, we attach the correct terms and mental model.
4. **Break it.** We introduce one realistic failure and diagnose it.
5. **Explain it back.** You give a short explanation in your own words.
6. **Keep evidence.** Save the code, a test or measurement, and a few notes on the trade-off.

If an idea does not click, we stop and approach it differently. Finishing a document is never the goal; understanding the system in front of us is.

## What “done” means

A phase is complete only when you can do all five:

1. Run the project from a clean checkout.
2. Draw the request and data flow simply.
3. Reproduce one failure and explain the cause.
4. Point to the test, metric, or log that proves the behavior.
5. State one trade-off you chose and what you would improve next.

That is enough. No required reading quotas, artificial lesson counts, or parallel side tracks.

## Practices that never wait for the last phase

Security and operations are not subjects we postpone until the end. From the first project onward, we use version control, tests, input validation, and clear errors. Logs and basic metrics arrive in Phase 1; explicit trust boundaries, safe secret handling, and least privilege arrive as soon as services communicate. Later phases deepen these practices into threat models, runbooks, incident response, and production controls.

## Future repository layout

The repository stays small. We create folders only when they become useful:

```text
README.md
plan/
  structure.md          # this roadmap
projects/
  00-request-service/   # created when Phase 0 begins
  01-reliable-service/  # created only after Phase 0 is complete
notes/
  decisions.md          # short design choices and trade-offs
  failures.md           # failures, diagnosis, and fix
```

Each project will contain only what helps you learn and operate it: code, a short README, tests, and evidence from one failure or measurement. Large reading lists, duplicate plans, and speculative future projects stay out until they have a job to do.

## First move

Begin with Phase 0: create `projects/00-request-service`, write a small Go program that serves `/health`, and inspect it from the terminal. The first session will explain every command and line used; prior Go or systems knowledge is not assumed.
