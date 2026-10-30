# Consistency models

A consistency model is a promise about **what a reader can see** after writes, when there are copies, caches and concurrency. "Eventually consistent" isn't an answer until you say what a user would see in the meantime.

## The models, strongest first

| Model | The promise | Costs | Example |
|---|---|---|---|
| **Linearizable** | Every operation appears to happen at one instant between its start and end; everyone sees the same order, matching real time | A majority round trip per operation; unavailable to the minority side of a partition | etcd, a Raft key-value store |
| **Sequential** | One order everyone agrees on, but it needn't match real time | Slightly cheaper | |
| **Causal** | If A could have influenced B, everyone sees A before B; unrelated writes may appear in any order | Track dependencies (vector clocks) | Comment threads |
| **Read your writes** | You see your own writes; others may not yet | Route a user's reads to fresh copies | A profile edit |
| **Monotonic reads** | You never see older data after newer | Stick a user to one replica | |
| **Eventual** | With no new writes, copies converge... eventually | Cheapest; always available | DNS, caches |

**Transactions have their own ladder (isolation levels):** read committed, then repeatable read / snapshot isolation, then serializable. Each step removes a class of anomaly: dirty reads, lost updates, write skew.

## CAP, stated precisely

During a **network partition**, a system must choose between **consistency** (linearizability: refuse operations it can't order) and **availability** (answer, possibly with stale data). When there's no partition, the real trade-off is **latency** against consistency (PACELC). "We chose AP" means nothing until you say what users see.

## How it fails

- **Stale reads from replicas or caches**, after a user's own write.
- **Lost updates:** two read-modify-writes overlap; one disappears. Use compare-and-swap, `SELECT ... FOR UPDATE`, or versions.
- **Clock-based ordering:** "last writer wins" with wall clocks can drop the actually-later write when clocks skew.
- **The new enemy problem:** a permission change and the content it protects become visible in the wrong order ([capstone 8](../../capstones/08-consistent-authorization.md)).

## In an interview

For each piece of data, state the model it needs, and why. Balances, inventory, locks and permissions need strong guarantees. Like counts, feeds and recommendations can be eventual. Then say what a user sees during a partition.

## Where you built it

- [Phase 1](../../lessons/01-reliable-service/README.md): compare-and-swap against lost updates.
- [Phase 3, step 3](../../lessons/03-durable-auditable-data/TEACHING.md#step-3-transactions): isolation anomalies reproduced and fixed.
- [Phase 4, step 7](../../lessons/04-replicated-state/TEACHING.md#step-7-a-replicated-key-value-store-checked-for-linearizability): a key-value store checked for linearizability with Porcupine.
