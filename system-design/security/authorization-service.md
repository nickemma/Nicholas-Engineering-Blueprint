# Design: an authorization service for sharing

**Track:** security · **Built in:** [Phase 6](../../lessons/06-safe-shared-queries/README.md) (authorization, tenants, audit), [capstone 8](../../capstones/08-consistent-authorization.md) · **Time:** 45 minutes

This is a worked reference. Do the design yourself first, with a timer, then read this and note what you missed.

## 0. The crux

**Permission checks must be fast** (they're on every request) **and correct immediately after a change.** Caching and replicas make them fast, and make one mistake easy, the **"new enemy" problem**:
1. Alice removes Bob from a folder.
2. She adds a secret document to it.
3. A stale cache still says Bob can see the folder, so Bob sees the document.

Deeply nested groups make checks slow. The time goes on consistency and on group nesting.

## 1. Requirements

**Functional**

1. Store relationships: "user U is a *viewer* of document D", "group G is a *member* of group H", "folder F is the *parent* of document D".
2. A schema that says how permissions follow: an editor is also a viewer; a viewer of a folder views its documents.
3. `Check(user, permission, object)` → yes or no.
4. `Expand`: who has this permission? `List`: what can this user see?

**Non-functional**

| Property | Target |
|---|---|
| Checks | 200,000 a second at peak |
| Writes | 2,000 relationship changes a second |
| Relationships | 5 × 10⁹ |
| Check latency | p99 < 10 ms |
| Correctness | No new-enemy violations; fail **closed** |
| Availability | 99.99%: if checks fail, every product fails |

## 2. Estimates

- **Storage:** 5 × 10⁹ relationships × ~100 bytes ≈ 500 GB; 1.5 TB with three copies. That needs partitioning, but modestly.
- **Database load:**
  - A check reads a few relationships if direct, and many if it walks nested groups and folders. Say an average of 5 reads.
  - Uncached, that's 200,000 × 5 = 10⁶ reads a second.
  - **A 90% cache hit rate brings it to 10⁵/s**, which a partitioned store handles. The cache isn't optional, so it has to be **correct**.
- **Fan-out:** a user in 50 groups, each nested 5 deep, makes one check into hundreds of reads. Nesting must be indexed.

## 3. API

- `Check(subject, permission, object, consistency)` → `allowed`, plus the snapshot it used.
- `Write(tuples)` → a **snapshot token** for the write.
- `Read`, `Expand`, `Watch(changes since token)`.

`consistency` is one of:
- `at_least_as_fresh(token)`, the default for content protected by a recent change;
- `full`;
- `minimize_latency`.

## 4. Core entities

- **Relationship tuple:** `(object, relation, subject)`, for example `(doc:42, viewer, user:bob)` or `(doc:42, parent, folder:7)`. A subject can itself be a set: `(folder:7, viewer, group:eng#member)`.
- **Schema:** the rules for how relations combine.

## 5. High-level design

~~~mermaid
flowchart LR
    APP[Product services] -->|Check, with token| CS[Check servers]
    CS -->|consistent hash of the check| CS
    CS --> CACHE[(Per-server cache, keyed by snapshot)]
    CS --> DB[(Relationship store: partitioned, replicated)]
    APP -->|Write| WS[Write path] --> DB
    DB -->|change stream| IDX[Group index builder] --> GI[(Nested-group index)]
    CS --> GI
    CS --> AUD[(Decision log)]
~~~

## 6. Deep dives

### 6.1 Snapshot tokens: correct and fast (the crux)

- **Every write returns a token:** the store's commit position (a WAL position, or a commit timestamp).
- **When a product writes content** protected by a recent permission change, it stores the token next to the content.
- **When it later checks access** to that content, it passes the token.
- **The check server must evaluate at a snapshot at least that fresh.**
  - A replica or cache entry that's behind the token can't answer; the check goes somewhere fresher, or waits.
  - Anything at or after the token is fine. Most checks don't need the newest data, only data **newer than the change that matters**.
- **This closes the new-enemy gap without making every check go to the primary.** Bob's check carries the token from when Alice added the document, which is after his removal. So no stale snapshot can answer it.
- **Cache keys include the snapshot.** A cached answer is valid for any check whose token it satisfies.

### 6.2 Making checks fast

- **Spread checks with consistent hashing.** All checks for the same object land on the same server, so its cache gets the hits. Without this, each server caches everything and hits little.
- **Evaluate in parallel:** a union of five branches runs five sub-checks concurrently, and returns on the first "yes".
- **Index nested groups.** A background builder maintains "user → every group they're in, transitively", from the change stream. A nested-group check becomes one lookup. The cost is index maintenance on group changes, and a short lag, so the index is used only for checks whose token it satisfies.
- **Bound the work:** limits on depth and fan-out, so a pathological schema can't take a server down.

### 6.3 Failing closed, and the blast radius

- If the service can't answer, the answer is **no**. That makes its availability the product's availability, so run it in every region and zone.
- Products cache **positive** answers briefly only where staleness is acceptable (`minimize_latency`), and never for protected content.
- **Every decision is logged:** who, what, which snapshot, the answer. That's for audits and for debugging "why could Bob see this?" (Phase 6's audit log).

## 7. Trade-offs

| Decision | Chose | Instead of | Because | Revisit when |
|---|---|---|---|---|
| Model | Relationships (ReBAC) | Roles only (RBAC) | Sharing, nesting and inheritance need relationships | The product has no sharing |
| Consistency | Snapshot tokens | Always read the primary | Fresh where it matters, cached where it doesn't | — |
| Failure | Fail closed | Fail open | A leak is worse than an outage for this data | — |
| Nesting | A precomputed index | Recursive walks only | Bounded latency for deep groups | Groups are shallow |

## 8. Failure modes

| Failure | Effect | Detection | Mitigation |
|---|---|---|---|
| A replica lags | Checks with recent tokens go to fresher copies | Lag metric; token-miss rate | Route by token; never answer below it |
| A client drops the token | New-enemy violations become possible | Checks without tokens on protected content | Make the token required by the SDK for content writes |
| The group index lags | Index-based checks fall back to walks | Index lag | Use the index only at snapshots it covers |
| A hot object (a company-wide doc) | One check server overloaded | Per-server load | Replicate hot keys' cache entries |
| Service down | Every product denies everything | SLOs | Multi-zone, multi-region; it's the most critical service there is |
| A schema change | Every cached answer may be wrong | Schema version | Version the schema into cache keys |

## 9. With more time

- **`List`:** "what can Bob see?" needs a reverse index.
- **Multi-region replication** with bounded staleness.
- **Policy conditions:** time-limited shares, IP restrictions.
- **A permissions-debugging UI.**

## 10. Where you've built this

- [Phase 6](../../lessons/06-safe-shared-queries/README.md):
  - a policy decision point behind every handler;
  - tenant isolation down to row-level security;
  - fail-closed checks;
  - a tamper-evident audit log.
- [Phase 4](../../lessons/04-replicated-state/README.md): replication and consistency models.
- [Capstone 8](../../capstones/08-consistent-authorization.md) measures the consistency trade-off.

## 11. What an interviewer will push on

- "Walk me through the new-enemy problem, and show where your design stops it."
- "Your cache hit rate drops to 50%. What happens to the database?"
- "Why fail closed, and what does that cost you?"
- "A user is in a group nested 20 deep. How long does a check take?"
