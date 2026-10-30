# Partitioning

Partitioning (sharding) splits data across machines when one machine can't hold it, or can't take the load. Each item lives in one partition, chosen by its **key**.

## The options

| Scheme | How a key finds its partition | Good | Bad |
|---|---|---|---|
| **Hash** of the key, modulo *n* | `hash(key) % n` | Even spread | Changing *n* moves almost every key |
| **Consistent hashing** | The first node after the key's hash on a ring | Adding a node moves ~1/*n* of the keys | Needs virtual nodes for balance |
| **Range** (by key order) | A table of key ranges to partitions | Range scans are cheap; easy to split hot ranges | Sequential keys (timestamps) all land on the last partition |
| **Directory** | A lookup service maps keys to partitions | Total flexibility; move any key | The directory is critical: replicate it (Raft) |

**Choosing the key is the real decision.**
- It must spread load evenly.
- It should keep data that's queried together in the same partition (one tenant's rows; one user's messages).
- Queries that don't include the key must ask every partition (**scatter-gather**).

## Numbers to know

- Plan partitions for 5–10 years of growth. Splitting later is the hardest operation in the system.
- With *k* partitions involved in each query, the query's latency is the slowest of *k*: the tail grows with fan-out.

## How it fails

- **Hot keys and hot partitions:** one celebrity, one tenant, one popular product. Split the key (append a suffix), cache it, or isolate it.
- **Rebalancing under load:** moving data competes with serving it. Throttle it.
- **Cross-partition transactions:** need two-phase commit or sagas, and they're slow and fragile. Choose keys so most transactions stay in one partition.
- **Secondary indexes:** local ones (per partition) mean scatter-gather reads; global ones mean cross-partition writes.

## In an interview

Name the partition key and why, the scheme, how a hot key is handled, and what happens to queries that don't have the key. Do the arithmetic: how many partitions, and how much data each.

## Where you built it

- [Phase 4, step 11](../../lessons/04-replicated-state/TEACHING.md#step-11-consistent-hashing-and-a-cache-spread-over-several-servers): consistent hashing with virtual nodes, rebalancing measured.
- [Phase 4, step 12](../../lessons/04-replicated-state/TEACHING.md#step-12-transactions-across-shards): transactions across shards.
- [Phase 6](../../lessons/06-safe-shared-queries/README.md): the tenant as the natural key for isolation.
- [DSA guide 19](../../dsa/19-design/README.md): the hash ring, rebuilt from scratch.
