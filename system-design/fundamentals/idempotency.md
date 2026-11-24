# Idempotency

An operation is idempotent if doing it twice has the same effect as doing it once. Networks lose responses, clients retry, and queues redeliver, so **every write that can be retried must be idempotent**, or retries create duplicate payments, emails and jobs.

## The techniques

| Technique | How | Use when |
|---|---|---|
| **Naturally idempotent operations** | "Set the status to shipped", not "increment the count" | You can choose the operation's shape |
| **Idempotency key** | The client sends a unique key with the request; the server stores the key with the result, and returns the stored result for a repeat | APIs that create things (payments, orders, jobs) |
| **Inbox (deduplication) table** | The consumer records each message ID it has processed, in the same transaction as the effect | Queue consumers with at-least-once delivery |
| **Conditional writes** | Compare-and-swap on a version: "update if version = 7" | Concurrent updates to one record |
| **Fencing tokens** | Each lock holder gets an increasing number; the storage refuses older ones | Work done under a lock that might have expired |

## The details that matter

- **Scope the key:** a key is unique per client or tenant, not globally. Otherwise one tenant's key collides with another's, or leaks whether a key exists.
- **Store the key and the effect atomically.** If they're separate, a crash between them breaks the guarantee.
- **Same key, different request:** reject it (a `409` or `422`); don't silently return the first result.
- **In-flight duplicates:** a retry arrives while the first attempt is still running. Lock on the key, or return "in progress".
- **Expiry:** keep keys longer than the longest retry window.

## How it fails

- Retrying a non-idempotent operation after a timeout. The first attempt may have succeeded.
- Deduplicating in memory, so a restart forgets.
- Recording "processed" **before** the effect (lost on a crash) or after it in a separate transaction (duplicated on a crash).

## In an interview

At every arrow in your diagram that can be retried, say how duplicates are made harmless. Interviewers listen for it.

## Where you built it

- [Core 01, lessons 14 and 16](../../2-core/01-go-runtime-and-reliable-services/lessons/14-timeouts-retries-and-idempotency.md): idempotency keys end to end; the three sources of duplicates; killing a worker mid-job.
- [Core 03, lesson 06](../../2-core/03-docker-and-postgres/lessons/06-a-retried-submission-survives-a-restart.md): keys and an inbox in PostgreSQL.
- [Core 07, lesson 09](../../2-core/07-distributed-systems-fundamentals/lessons/09-fence-a-worker-that-outlives-its-lease.md): fencing tokens.
