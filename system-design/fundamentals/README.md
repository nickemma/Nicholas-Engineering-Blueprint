# Fundamentals

The building blocks every design is made of. Each page is short:
- what the block is, and the options;
- the numbers worth knowing;
- how it fails;
- what to say in an interview;
- where in the Blueprint you built it.

Start with [one request and one database](../classic/first-design.md). Use the readings below when a requirement or failure mode makes the component relevant.

## 20 system design building blocks

Practise these in three passes. For your first session, follow the request from client to storage and pick the API and data model. When you add load, estimate the bottleneck and choose a scaling or caching change. When you add replicas, async work or another service, describe what happens during failures and how you'll observe recovery.

| # | Topic | Decision to practise |
|---|---|---|
| 1 | [Vertical and horizontal scaling](load-balancing.md#vertical-and-horizontal-scaling) | Do you give one instance more resources or add instances? Size capacity for losing one replica. |
| 2 | [Load balancing](load-balancing.md) | What gets balanced, and how does an unhealthy backend stop receiving new work? |
| 3 | [Caching](caching.md) | What is the cache key, how stale may it get, and can the origin survive a miss surge? |
| 4 | [CDNs](caching.md#cdn-and-edge-caching) | Which responses can you share across edge clients, and what evidence shows the origin did less work? |
| 5 | [Database indexes](storage.md#indexes-start-with-the-query) | Which filter and sort should the index serve, and how will you measure the read gain and write cost? |
| 6 | [Replication](replication.md) | When do you acknowledge writes, and what can a new leader recover? |
| 7 | [Sharding](sharding.md) | What key spreads the workload, and how would you move a hot shard? |
| 8 | [Consistent hashing](partitioning.md) | How many keys move when membership changes, and how skewed is the new placement? |
| 9 | [SQL and NoSQL](storage.md) | Do you need joins and constraints, or does a specific access pattern justify a different store? |
| 10 | [CAP theorem](consistency.md#cap-stated-precisely) | If the replicas cannot talk, which requests complete on each side and what can those clients observe? |
| 11 | [Consistency](consistency.md) | After an acknowledged write, what is the next read allowed to return? |
| 12 | [Message brokers](queues.md) | What does a publish confirm or consumer acknowledgment prove? Walk through a worker crash. |
| 13 | [Pub/sub](queues.md#publishsubscribe-and-work-queues) | Which subscribers need their own copy, and which workers should share one stream of work? |
| 14 | [Microservices](#service-boundaries-and-api-gateways) | What warrants an independently deployed service, and who owns its writes? |
| 15 | [API gateway](#service-boundaries-and-api-gateways) | Which routing and client policies belong at the gateway, and what happens when the gateway fails? |
| 16 | [Rate limiting](rate-limiting.md) | What is the budget keyed by, and what does a rejected client see? |
| 17 | [Circuit breakers](queues.md#retries-backlog-and-circuit-breakers) | Which dependency calls should stop after repeated failures, and what signal permits a recovery probe? |
| 18 | [Idempotency](idempotency.md) | If a reply is lost after commit, how does a retry get the original effect and result? |
| 19 | [Retries and backlog](queues.md#retries-backlog-and-circuit-breakers) | What can retry, how much work can accumulate, and how long will recovery take? |
| 20 | [Observability](observability.md) | Which client outcome alerts you, and how do you trace it through the request or event path? |

### Service boundaries and API gateways

A microservice owns a capability and can be deployed independently. Keep the first design in one application until a specific split earns its cost, such as worker compute that needs independent scaling. Give each service ownership of its write path and define its API or event contract. For the split, draw what happens when a call times out after the remote side has committed. [Switchyard API and worker deployment](../../3-tracks/shared-units/kubernetes-and-delivery/lessons/03-deploy-the-jobs-path-with-persistent-storage.md)

An API gateway gives clients an entry point for routing, authentication and limits. A load balancer distributes traffic among healthy replicas and can also perform routing. Walk through a request from a tenant to a service replica and identify the layer that enforces each policy. Account for gateway capacity and failure, and keep resource-level authorization with the service that owns the resource. [Tenant and route policy](../../3-tracks/shared-units/tenancy-and-abuse-control/README.md) · [Inference gateway design](../ai-infrastructure/llm-inference-gateway.md)

## Reference pages

| Page | The question it answers | Built in |
|---|---|---|
| [Estimation](estimation.md) | How big is this, really? | Core 02, Phase 5 |
| [Latency and throughput numbers](latency-numbers.md) | How long does each thing take? | Every phase's measurements |
| [Load balancing](load-balancing.md) | How is work spread over many servers? | Phase 5 |
| [Caching](caching.md) | How do you avoid doing the same work twice? | Phase 3 |
| [Queues and logs](queues.md) | How do you decouple producers from consumers? | Phases 2, 3 |
| [Replication](replication.md) | How does data survive a machine dying? | Phase 4 |
| [Partitioning](partitioning.md) | How do you split data too big for one machine? | Phase 4 |
| [Sharding decisions](sharding.md) | How do you choose, size, and move a shard under load? | Storage engines, consensus in depth |
| [Consistency models](consistency.md) | What will a reader see? | Phase 4 |
| [Consensus](consensus.md) | How do machines agree? | Phase 4 |
| [Rate limiting](rate-limiting.md) | How do you stop one client taking everything? | Phase 6 |
| [Idempotency](idempotency.md) | How do you make retries safe? | Phases 2, 3 |
| [Storage engines and types](storage.md) | Where does the data live, and in what shape? | Phase 3, Rust Bridge |
| [Observability](observability.md) | How do you know it's working? | Phases 1, 5 |
