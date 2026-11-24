# Sharding decisions under load

[Partitioning](partitioning.md) compares placement schemes. This drill takes the next decisions: how to choose a key from the workload, size for skew, and move an active shard without losing an acknowledged write.

## The prompt

A multi-tenant event store handles 12,000 writes/s at peak. A replica group sustains 2,000 writes/s at the target p99 with the given event mix. Most reads list one tenant's recent events. One tenant accounts for 4,800 writes/s. Clients retry timeouts using the same request ID. Pick a placement strategy and walk through adding capacity while writes continue elsewhere.

Before reading on, state the invariant your move must preserve. Ask whether tenant-wide order must be exact, how much read fan-out is acceptable, and whether the 2,000 writes/s measurement included migration traffic.

## Choose what to colocate

| Candidate | Benefit | What breaks in this workload |
|---|---|---|
| Hash by tenant | Recent-event reads contact one group. Tenant-local transactions stay local. | The largest tenant needs more than twice one group's measured capacity. Extra groups alone leave it on one shard. |
| Hash every event | Spreads independently keyed writes. | A tenant recent-events read can require a fan-out and ordered merge across all groups. |
| Start with tenant placement and split high-volume tenants into buckets | Keeps ordinary tenant reads local and bounds fan-out for tenants you split. | You need a bucket directory, merge and pagination rules, and a separate plan for one hot bucket or key. |

Choose the third option if the query can merge bucket-local streams. Route a high-volume tenant by a stable hash of its event ID. Merge each bucket's descending index using a deterministic tie-breaker such as event ID, and define the cursor's ordering and visibility semantics. If the product requires transactional ordering for every write within a tenant, the sequencing point needs a separate throughput budget. Splitting may no longer solve the bottleneck.

## Size for the hottest part

Six groups is the arithmetic minimum at 2,000 writes/s per group with perfectly balanced load. At a 75% planning target, each group budgets 1,500 writes/s. Eight groups cover 12,000 writes/s in aggregate. The largest tenant alone needs at least four evenly loaded placements at that target. Check the measured load of each placement, including its other tenants. Treat both counts as lower bounds. Budget migration traffic and validate p99 under peak and failure load. [Capacity planning](../../math/04-capacity-planning/README.md)

Replication protects state within a group. Losing one replica can reduce the group's headroom. Losing the whole group requires an explicit recovery or availability decision for the data it owned. Spare write throughput elsewhere matters only when those groups can safely serve that data.

## Walk the move

1. **Prepare.** Record the range, source, destination, and current routing generation. Copy an initial snapshot while the source owns serving. Account for writes during the copy.
2. **Fence and catch up.** Close source write admission for that range and establish a committed boundary. Copy the remaining committed updates and relevant retry receipts. Verify the destination has reached that boundary.
3. **Activate.** Publish a higher generation, then let the destination serve under it. Enforce ownership at the serving groups so clients with stale routing cannot cause writes at the old source. Reject or redirect stale strongly consistent reads too.
4. **Handle a lost reply.** A client can retry a write whose commit preceded fencing. Deduplicate with the transferred receipt and return the original logical result. Keep the same request identity across redirects.
5. **Recover.** Before activation, the coordinator can retry a failed copy while the destination remains inactive. After activation, recover forward. Moving back is another fenced handoff under a newer generation. Confirm the active owner before making that decision.

This policy trades a short per-range write pause for a single writable owner. Measure the pause, stale-route retries, copied bytes, catch-up lag, and client p99 during migration. The lesson's fixed replica groups preserve values and retry receipts across an interrupted move. [Move a key range](../../3-tracks/storage-engines/02-consensus-in-depth/lessons/07-move-a-key-range.md)

## Change one constraint

- **One event key generates most writes.** Which assumptions behind hashing by event ID fail? Decide whether to change the operation, serialize that key, or apply admission control. Explain what the client sees.
- **A scan must reflect one consistent instant.** What guarantee does a timestamp tie-breaker provide? What extra snapshot or coordination would you need?
- **The destination becomes unreachable just after activation.** Who can accept writes? Which evidence would justify moving ownership again?

Score your answer on the decision, its rejected alternative, and what would change your mind. [Design scorecard](../scorecard.md)
