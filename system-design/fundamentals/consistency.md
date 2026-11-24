# Consistency models

A consistency model is a promise about **what a reader can see** after writes, when there are copies, caches and concurrency. "Eventually consistent" isn't an answer until you say what a user would see in the meantime.

## The models, strongest first

| Model | The promise | Costs | Example |
|---|---|---|---|
| **Linearizable** | Every operation appears to happen at one instant between its start and end; everyone sees the same order, matching real time | Requires a way to establish a current view. A quorum-based design may delay or reject requests on the minority side of a partition. | etcd, a Raft key-value store with linearizable reads |
| **Sequential** | One order everyone agrees on, but it needn't match real time | Slightly cheaper | |
| **Causal** | If A could have influenced B, everyone sees A before B; unrelated writes may appear in any order | Track dependencies (vector clocks) | Comment threads |
| **Read your writes** | You see your own writes; others may not yet | Route a user's reads to fresh copies | A profile edit |
| **Monotonic reads** | You never see older data after newer | Stick a user to one replica | |
| **Eventual** | With no new writes and successful propagation, copies converge | Clients can see stale data before convergence | DNS, caches |

**Transactions have their own ladder (isolation levels):** read committed, then repeatable read / snapshot isolation, then serializable. Each step removes a class of anomaly: dirty reads, lost updates, write skew.

## CAP, stated precisely

If replicas can become partitioned, a replicated read/write object cannot guarantee both linearizability and a successful response to every valid request at every non-failing replica. For example, suppose one side accepts a write and a client later reads from the isolated side. The isolated replica can answer from its local state and risk a stale read, or wait for coordination and give up availability for that read during the partition. State the behavior for each operation and what reconciliation does after the link returns. [Gilbert and Lynch's CAP proof](https://groups.csail.mit.edu/tds/papers/Gilbert/Brewer6.pdf)

## How it fails

- **Stale reads from replicas or caches**, after a user's own write.
- **Lost updates:** two read-modify-writes overlap; one disappears. Use compare-and-swap, `SELECT ... FOR UPDATE`, or versions.
- **Clock-based ordering:** "last writer wins" with wall clocks can drop the actually-later write when clocks skew.
- **The new enemy problem:** a permission change and the content it protects become visible in the wrong order.

## In an interview

For each piece of data, state the model it needs, and why. Balances, inventory, locks and permissions need strong guarantees. Like counts, feeds and recommendations can be eventual. Then say what a user sees during a partition.

## Where you built it

- [Core 01](../../2-core/01-go-runtime-and-reliable-services/lessons/07-a-race-a-mutex-cant-fix.md): compare-and-swap against lost updates.
- [Postgres in depth, lesson 01](../../3-tracks/storage-engines/01-postgres-in-depth/lessons/01-reproduce-isolation-anomalies.md): isolation anomalies reproduced and fixed.
- [Consensus in depth, lesson 05](../../3-tracks/storage-engines/02-consensus-in-depth/lessons/05-check-a-client-history.md): a key-value store checked for linearizability with Porcupine.
