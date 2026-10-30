# Design: a URL shortener

**Track:** classic · **Built in:** [Phase 1's exercise](../../lessons/01-reliable-service/exercises.md) (shortlinks), [Phase 3](../../lessons/03-durable-auditable-data/README.md) (cache), [Phase 6](../../lessons/06-safe-shared-queries/README.md) (rate limits) · **Time:** 45 minutes

This is a worked reference. Do the design yourself first, with a timer, then read this and note what you missed.

## 0. The crux

Two things are hard; everything else is a table with two columns.
1. **Generating short codes** that are unique, short and not guessable in sequence, without one counter every write must wait for.
2. **Serving redirects** at a hundred times the write rate, with a low tail latency, from a hot set that follows a power law.

Most time goes to the code generation, then the read path.

## 1. Requirements

**Functional**

1. Create a short link for a long URL; optionally a custom alias.
2. Redirect a short link to its long URL.
3. Links can expire.
4. Owners see click counts (minutes behind is fine).

**Non-functional**

| Property | Target |
|---|---|
| New links | 100 million a month |
| Reads to writes | 100 : 1 |
| Redirect latency | p99 < 20 ms inside our region (excluding the user's internet) |
| Availability | 99.99% for redirects; 99.9% for creating |
| Durability | Links last years; losing one breaks someone's printed poster |

**Out of scope:** user accounts beyond an API key, custom domains, link editing.

## 2. Estimates

- **Writes:** 10⁸ a month ÷ 2.6 × 10⁶ seconds ≈ 40/s on average, ~120/s at a 3× peak.
- **Reads:** 100 × 40 = 4,000/s on average, ~12,000/s at peak.
- **Storage:** about 500 bytes a link (URL, code, owner, times) × 1.2 × 10⁹ links a year ≈ 600 GB a year; 1.8 TB with three copies.
- **Code length:** base-62 (a–z, A–Z, 0–9). 62⁷ ≈ 3.5 × 10¹² codes; at 1.2 × 10⁹ a year, that's thousands of years.

**What this decides:**
- Writes are small enough for **one primary database**.
- Reads are 100 times bigger and repeat heavily, so **a cache** in front.
- 600 GB a year fits on one machine for years, so **no partitioning yet**.
- **7 characters** is enough.

## 3. API

- `POST /links {url, alias?, expires_at?}` → `201 {code, short_url}`; idempotent with an `Idempotency-Key` header.
- `GET /{code}` → `302 Location: <url>`, or `404` / `410 Gone`.
- `GET /links/{code}/stats` → click counts.

## 4. Core entities

- `links(code PK, url, owner, created_at, expires_at)`
- `clicks_daily(code, day, count)`, written by the analytics pipeline

## 5. High-level design

~~~mermaid
flowchart LR
    U[User] --> LB[Load balancer] --> R[Redirect service]
    R --> C[(Redis cache)]
    R -.miss.-> DB[(PostgreSQL primary + replicas)]
    R -->|click event| Q[Kafka] --> A[Analytics aggregator] --> DB
    O[Owner / API] --> W[Create service] --> DB
    W -->|scan URL| S[Abuse scanner]
~~~

**A redirect:**
1. The redirect service looks the code up in Redis.
2. On a miss, it reads a replica and fills the cache with a TTL.
3. It returns `302`.
4. It emits a click event to Kafka without waiting for it.

**A create:** the create service makes a code, inserts the row (the unique key guards against collisions), and queues the URL for an abuse scan.

## 6. Deep dives

### 6.1 Generating codes (the crux)

| Option | How | Problems |
|---|---|---|
| Hash the URL, take 7 characters | Same URL, same code | Collisions need handling anyway; different owners of the same URL share a code; guessable from the URL |
| One global counter, in base 62 | Unique by construction | A single point every write waits on; codes are sequential, so anyone can enumerate every link |
| **Counter ranges** | Each server leases a block of 10,000 IDs from the database; it hands them out locally | Sequential within a block; a crash wastes the rest of its block (harmless) |
| **Random 7 characters + a unique constraint** | Generate, insert; on a duplicate-key error, retry | A collision check per write |

**Chosen: random codes with a unique constraint.**
- **The collision maths:** after a year, 1.2 × 10⁹ of 3.5 × 10¹² codes are taken. A new code collides with probability 1.2 × 10⁹ ÷ 3.5 × 10¹² ≈ 0.03%. So a retry is rare, and two in a row about one in ten million.
- **What it buys:** no coordination, and codes nobody can enumerate.
- **Custom aliases** use the same table and the same constraint, and fail with `409` if taken.
- **Revisit when:** the table fills to about 10%, when collisions reach 10% per insert. That's centuries away; going to 8 characters fixes it.

### 6.2 The read path

- **Cache-aside in Redis**, keyed by code, with a TTL of a day. Link popularity follows a power law, so a small cache serves most reads: expect over 90% hits.
- **Negative caching:** cache "not found" for a minute, so scans of random codes don't reach the database.
- **Stampede:** a viral link that expires from the cache is filled by one request; the others wait for it (singleflight).
- **302, not 301:** browsers cache a 301 forever, which saves load but loses click counts and makes expiry impossible. Use 302 or 307.
- **The latency budget** (p99 under 20 ms): load balancer ~1 ms, cache hit ~1 ms, service ~1 ms. A miss adds a replica read of ~5 ms. Comfortably inside.

### 6.3 Clicks without slowing redirects

The click is an event to Kafka, sent asynchronously. An aggregator sums clicks per code per minute and writes the counts. Losing a few clicks during a broker outage is acceptable (they're counts); losing redirects isn't. If Kafka is down, the redirect still succeeds.

### 6.4 Abuse

Shorteners hide phishing links.
- Rate-limit creation per API key (a token bucket).
- Scan new URLs against blocklists asynchronously, and disable a code by setting a flag that the redirect checks.
- Show an interstitial warning for links that are flagged but unconfirmed.

## 7. Trade-offs

| Decision | Chose | Instead of | Because | Revisit when |
|---|---|---|---|---|
| Codes | Random + unique constraint | Counter ranges | No coordination; not enumerable | Collisions per insert exceed ~1% |
| Store | One PostgreSQL primary + replicas | A key-value store | 600 GB a year, 120 writes/s, and we want constraints | Several TB, or write rates in the thousands |
| Redirect | 302 | 301 | Click counts and expiry need every request | Clicks stop mattering |
| Clicks | Async through Kafka | A write per redirect | Redirects mustn't wait for analytics | — |

## 8. Failure modes

| Failure | Effect | Detection | Mitigation |
|---|---|---|---|
| Redis down | Every read goes to replicas: 12,000/s | Cache error rate; replica load | Replicas sized for the full load, or an in-process cache of the hottest links; fail open |
| Primary down | No new links; redirects keep working from cache and replicas | Write errors | Promote a replica (accepting a few seconds of lost writes, or synchronous replication to one) |
| A viral link | One key's traffic on one cache node | Per-key rate | In-process cache for the top keys |
| Kafka down | Click counts pause | Producer errors | Drop, or buffer locally with a bound |
| Code enumeration | Scraping of private links | Many 404s from one client | Random codes; rate limit 404s per IP |

## 9. With more time

Multi-region:
- read replicas and caches in each region;
- writes to one home region, or regional code prefixes so each region generates its own codes without coordinating.

Custom domains. Link editing (invalidate the cache on write).

## 10. Where you've built this

- [Phase 1's shortlinks exercise](../../lessons/01-reliable-service/exercises.md): the core, with exact concurrency guarantees.
- [Phase 3](../../lessons/03-durable-auditable-data/README.md): cache-aside and stampede protection, and idempotency keys.
- [Phase 6](../../lessons/06-safe-shared-queries/README.md): rate limiting per key.
- [DSA guide 01](../../dsa/01-arrays-hashing/README.md): the hashing underneath.

## 11. What an interviewer will push on

- "Two servers generate the same random code at the same moment. What happens?" (The unique constraint rejects one; it retries.)
- "Why not 301?"
- "The cache is down during a viral spike. Walk me through the next minute."
- "How would you do this in three regions?"
