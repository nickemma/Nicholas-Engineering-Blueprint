# Extended review

Related modules for this review are [Go service and gRPC](../../../2-core/01-go-runtime-and-reliable-services/README.md).

Answer from memory, then check yourself against [the lesson](README.md). Write each "predict" answer before running anything.

## A. Queues and backpressure

1. What's the difference between synchronous and asynchronous work, from the caller's point of view?
2. State Little's law. With 2 workers and 500 ms jobs, what's the maximum throughput? If 10 jobs a second arrive, how quickly does the queue grow?
3. Why is an unbounded queue a bug, not a feature?
4. Predict: one worker, a queue of 2, and five 1-second jobs sent at once. What are the five status codes, and why?
5. When several `select` cases are ready, what does Go do? What bug did that cause, and how was it fixed?
6. Why did step 1's shutdown need two contexts? What does each one mean?
7. What's a gauge, and why is queue depth one?

## B. Messages and events

8. Command or event: `RunJob`, `JobCompleted`, `ChargeCard`, `CardCharged`. How did you decide?
9. What's in an envelope, and why is each field there?
10. Define at-most-once, at-least-once and exactly-once-in-effect. Which does this system provide?
11. What does the tolerant reader pattern say, and why is it the opposite of the HTTP API's rule?
12. What are bounded contexts? Name the two in this phase, and what each one owns.
13. Why is the worker forbidden from touching job records?
14. Predict: "completed" arrives before "started". What state does the job end in, and which code path handles it?
15. Why does `transition` loop? Why is the loop guaranteed to end?

## C. RabbitMQ

16. Connection vs channel: what's each one, and why does a worker with 4 consumers use 1 TCP connection?
17. What do a durable queue, a persistent message and a publisher confirm each protect against?
18. When does the worker ack? What would change if it acked on receipt?
19. What does prefetch 1 do, and why does it matter for slow jobs?
20. What is a quorum queue, and what protocol keeps its copies in agreement?
21. Which two RabbitMQ behaviours surprised the integration tests? How does the code handle each one?
22. Why does the adapter republish with an `x-runway-attempt` header instead of nacking with requeue?
23. Narrate exactly what happens when a worker is killed with SIGKILL one second into a four-second job.
24. What is crash-only design, and why does the API exit when it loses the broker?

## D. Idempotency

25. A client's `POST /jobs` times out. Why can't it simply retry without a key?
26. Predict the response to: the same key and same body twice; the same key and a different body; the same key while the first request is still running.
27. Why aren't 5xx responses remembered?
28. Why does a replay still say `queued` after the job completed?
29. List the three sources of duplicates and the defence against each.
30. Why can't a worker reliably remember "I already did this"? What does the inbox pattern do?

## E. Retries, versions, breakers

31. Transient or permanent: a timeout, a 400, a 503, an unreadable message, a context deadline. Why?
32. With base 100 ms and max 1 s, what's the ceiling before retries 1 to 5? What's the actual wait with full jitter?
33. Why does jitter matter when a thousand clients fail together?
34. Why do retries happen *inside* the job deadline?
35. What is upcasting? Why must workers be upgraded before the API?
36. Draw the circuit breaker's states and transitions. Why only one trial call in half-open?
37. Quote the freeze experiment's numbers. What would they look like without a breaker, at a thousand requests a second?
38. What is a dead-letter queue *for*? What would you do with a message in one?

## F. gRPC and the wire

39. Why can a protobuf field be renamed but not renumbered?
40. Map `InvalidArgument`, `NotFound` and `Unavailable` to HTTP statuses.
41. How does a client's deadline reach a gRPC server?
42. Describe the three packets of a TCP handshake.
43. Why is HTTP/1.1 readable in `tcpdump` but gRPC isn't?
44. What's an ephemeral port?

## G. Explain it whole

45. Draw the whole system at the end of step 6: processes, queues, ports, and the path of one job from `POST /jobs` to `completed`. Mark every place a message could be duplicated or lost, and the defence at each.
46. Rebuild Phase 2 in your own repository, then run the kill and freeze experiments on your code. What differed?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, logs, captures. Keep your filled-in copy in your own repository.

### Explain it

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

### Evidence checklist

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

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the guide, and why:
- What is still unclear:
