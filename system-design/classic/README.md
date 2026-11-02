# Classic warm-ups

Generalist design questions, asked everywhere. Use them to drill the [45-minute script](../README.md#the-45-minute-script) until it's automatic, then move to your role's track.

**Worked design:** [a URL shortener](url-shortener.md). Do it yourself first, then compare.

**How to use the prompts:**
1. Set a 45-minute timer and design with the [template](../_template.md).
2. Open **the crux** only if you haven't named one by minute 10.
3. Open **what a strong answer covers** only after the timer, then score yourself with the [scorecard](../scorecard.md).

## 1. A chat service

One-to-one and group chat (groups up to 500), 50 million daily users, messages delivered in under a second when the recipient is online, history kept forever, read receipts.

<details><summary>The crux</summary>Delivering each message to the right connected devices in order, at scale: millions of long-lived connections spread over many servers, so the system must know which server holds each user's connection. Plus ordering per conversation, and offline delivery.</details>

<details><summary>What a strong answer covers</summary>

- Estimates: concurrent connections (~10–20% of daily users), messages a second, storage a year.
- WebSockets on stateless-ish gateway servers; a **presence/session registry** mapping users to gateways.
- Per-conversation ordering: a sequence number from the conversation's partition owner, not timestamps.
- Storage partitioned by conversation ID, time-ordered within it (wide-column or partitioned SQL).
- Group fan-out: on write for small groups; reading members at delivery for large ones.
- Offline: store, then push notification; sync from the last seen sequence number on reconnect.
- At-least-once delivery with client-side deduplication by message ID.
- Failure: a gateway dies, so its clients reconnect elsewhere and resync.
</details>

**Built in:** [Phase 2](../../lessons/02-connected-services/README.md) (messaging, ordering, idempotency), [Phase 4](../../lessons/04-replicated-state/README.md) (partitioning).

## 2. A news feed

Users follow others; the home feed shows recent posts from people they follow, ranked or by time. 300 million daily users, 1 billion feed reads a day, 50 million posts a day, some accounts with 50 million followers.

<details><summary>The crux</summary>Fan-out: writing each post into every follower's feed (fast reads, but a celebrity post means 50 million writes) or assembling feeds at read time (cheap writes, expensive reads). The answer is a hybrid, and the celebrity threshold is the thing to discuss.</details>

<details><summary>What a strong answer covers</summary>

- Estimates: reads per second (~12,000 average), posts per second (~600), fan-out writes per second if everyone is pushed.
- **Push (fan-out on write) for ordinary accounts; pull (on read) for accounts above a follower threshold**, merged at read time.
- Feed storage: a capped list of post IDs per user, in a cache, rebuilt from the source when missing.
- Ranking as a separate stage (link to the ML track's feed ranking).
- Pagination by cursor, not offset.
- Failure: the fan-out queue lags, so feeds are late but correct; deleted posts are filtered at read time.
</details>

**Built in:** [Phase 2](../../lessons/02-connected-services/README.md) (queues), [Phase 3](../../lessons/03-durable-auditable-data/README.md) (caching), [DSA guide 08](../../dsa/08-heaps/README.md) (merge *k* sorted lists).

## 3. Ride matching

Match riders with nearby drivers in under 2 seconds. 5 million rides a day in 500 cities; drivers send their location every 4 seconds; a driver must never get two riders at once.

<details><summary>The crux</summary>Two things: a fast spatial index over constantly moving drivers (about 1 million location updates every 4 seconds at peak), and an assignment that can't double-book a driver when two matchers pick the same one at once.</details>

<details><summary>What a strong answer covers</summary>

- Estimates: location updates per second (~250,000 for 1 million active drivers), matches per second.
- Spatial index: a geohash or S2 cell → drivers, held **in memory**, partitioned by city or region. Location updates are overwrites, not history.
- Location history goes to a log separately, for analytics.
- Matching: query nearby cells, rank by estimated arrival time.
- **Reserving a driver atomically:** a compare-and-set on the driver's state, or a short lease with a fencing token, so two matchers can't both win.
- Failure: a matcher dies mid-assignment, so the lease expires and the driver frees up.
- Surge pricing and dispatch optimisation as extensions.
</details>

**Built in:** [Phase 4](../../lessons/04-replicated-state/README.md) (leases, fencing, partitioning), [Phase 1](../../lessons/01-reliable-service/README.md) (compare-and-swap).

## 4. Ticket booking

Sell 50,000 seats for a concert that goes on sale at 10:00, when 2 million people arrive within a minute. No seat sold twice; people can hold seats for 10 minutes while paying.

<details><summary>The crux</summary>A flash crowd of reads and contended writes on a small inventory. Admission must be controlled with a virtual queue, and seat holds must be exact (no double booking) while expiring reliably.</details>

<details><summary>What a strong answer covers</summary>

- **A virtual waiting room:** admit users at the rate the booking system can serve; give each a token and a position.
- Seat map reads served from a cache or snapshot, slightly stale; only the hold is exact.
- **Holds:** a conditional update (`UPDATE seats SET held_by = ?, until = ? WHERE id = ? AND held_by IS NULL`), or a lock per seat with expiry.
- Expiry by timestamp checked on read, plus a sweeper; idempotent payment confirmation.
- Partition by event; the event is the hot spot, so the queue protects it.
- Bots: rate limits per account and device, and proof of humanity at the queue.
- Failure: payment succeeds after the hold expired. Decide what happens: refund, or honour it if the seat is still free.
</details>

**Built in:** [Phase 3](../../lessons/03-durable-auditable-data/README.md) (transactions, `SKIP LOCKED`), [Phase 6](../../lessons/06-safe-shared-queries/README.md) (rate limiting), [Phase 2](../../lessons/02-connected-services/README.md) (idempotency).
