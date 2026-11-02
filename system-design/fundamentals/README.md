# Fundamentals

The building blocks every design is made of. Each page is short:
- what the block is, and the options;
- the numbers worth knowing;
- how it fails;
- what to say in an interview;
- where in the Blueprint you built it.

Read them before your first design session. Then come back whenever a design leans on one.

| Page | The question it answers | Built in |
|---|---|---|
| [Estimation](estimation.md) | How big is this, really? | Python Bridge, Phase 5 |
| [Latency and throughput numbers](latency-numbers.md) | How long does each thing take? | Every phase's measurements |
| [Load balancing](load-balancing.md) | How is work spread over many servers? | Phase 5 |
| [Caching](caching.md) | How do you avoid doing the same work twice? | Phase 3 |
| [Queues and logs](queues.md) | How do you decouple producers from consumers? | Phases 2, 3 |
| [Replication](replication.md) | How does data survive a machine dying? | Phase 4 |
| [Partitioning](partitioning.md) | How do you split data too big for one machine? | Phase 4 |
| [Consistency models](consistency.md) | What will a reader see? | Phase 4 |
| [Consensus](consensus.md) | How do machines agree? | Phase 4 |
| [Rate limiting](rate-limiting.md) | How do you stop one client taking everything? | Phase 6 |
| [Idempotency](idempotency.md) | How do you make retries safe? | Phases 2, 3 |
| [Storage engines and types](storage.md) | Where does the data live, and in what shape? | Phase 3, Rust Bridge |
| [Observability](observability.md) | How do you know it's working? | Phases 1, 5 |
