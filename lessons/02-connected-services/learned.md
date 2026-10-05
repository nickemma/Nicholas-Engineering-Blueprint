# Phase 2: what I learned

Fill this in as you go, with evidence: commands and their output, test names, logs, captures. Keep your filled-in copy in your own repository.

## Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | Use Little's law: with 4 workers, 1 s jobs and 10 arrivals a second, how fast does the queue grow, and when is a 100-slot queue full? | | |
| 1 | Why 503 and not 429? Why refuse instead of waiting? | | |
| 1 | What did `-count=20` reveal about `select`? | | |
| 2 | Command vs event; give one of each from this system | | |
| 2 | Why is exactly-once *delivery* impossible? What do you build instead? | | |
| 2 | Why do messages tolerate unknown fields when the HTTP API rejects them? | | |
| 2 | Show that 20 copies of one event write once, and what happens without compare-and-swap | | |
| 3 | What three things make a message survive a broker restart? | | |
| 3 | Ack after the work vs ack before: which gives which guarantee? | | |
| 3 | What did the integration tests reveal about RabbitMQ 4? | | |
| 3 | Narrate the kill-a-worker experiment step by step. Why did the job run twice? | | |
| 4 | Why must claiming a key and checking it happen under one lock? | | |
| 4 | Name the three sources of duplicates and the defence against each | | |
| 5 | Why jitter? Why stop retrying at the deadline? | | |
| 5 | Why must readers deploy before writers when `RunJob` becomes v2? | | |
| 5 | Show the freeze experiment's numbers and explain them | | |
| 6 | Why are protobuf field numbers permanent? | | |
| 6 | Map three gRPC codes to the HTTP statuses this API uses | | |
| 7 | Describe a handshake you captured, packet by packet | | |
| 7 | Did the SYN capture confirm the 7-second-tail hypothesis? | | |

## Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A full queue returns 503 and records the job as failed | | |
| A worker killed mid-job: the job still completes | | |
| A poison message ends up in the dead-letter queue | | |
| A retried `POST /jobs` with one key creates one job | | |
| Retries rescue most jobs at `FAIL_RATE=0.5` | | |
| The breaker opens during a broker freeze, and requests fail fast | | |
| gRPC and HTTP serve the same job | | |
| `tcpdump` shows the handshake and the HTTP request | | |

## Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the guide, and why:
- What is still unclear:
