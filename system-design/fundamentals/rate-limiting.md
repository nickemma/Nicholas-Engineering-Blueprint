# Rate limiting

A rate limiter caps how much work one client, tenant or key can ask for. It protects the system from overload, and protects tenants from each other (the noisy neighbour). It also makes abuse expensive.

## The algorithms

| Algorithm | How | Memory per client | Behaviour |
|---|---|---|---|
| **Token bucket** | Tokens refill at a rate, up to a burst; each request takes one | O(1): tokens + a timestamp | Allows bursts up to the bucket size, then the steady rate. The most common choice |
| **Leaky bucket** | Requests drain at a fixed rate from a queue | O(queue) | Smooths output; adds delay |
| **Fixed window** | Count per calendar minute | O(1) | Allows 2× the limit across a window boundary |
| **Sliding window log** | Keep every timestamp in the window | O(requests) | Exact, but expensive |
| **Sliding window counter** | Weighted mix of this and the previous window's count | O(1) | A good approximation of the log |

## Where it runs

- **At the edge** (API gateway, load balancer): cheap, stops abuse before it costs anything.
- **In the service:** knows the tenant, the operation and the cost (an expensive query can cost more tokens).
- **Distributed:** many API replicas must share one limit. Keep the buckets in Redis, updated atomically (a Lua script), or give each replica a share of the limit and accept some slack.

## Numbers to know

A Redis-backed check costs one round trip, about 0.2–1 ms. At very high rates, check locally and sync in batches.

## How it fails

- **The limiter's store goes down.** Decide in advance: fail open (allow everything) or fail closed (refuse everything). For abuse protection, open with a local fallback is common. For a paid quota, it might be closed.
- **Counting the wrong thing:** limiting requests that were going to be refused anyway (unauthorised ones) lets attackers drain a victim's quota.
- **No signal to the client:** return `429 Too Many Requests` with `Retry-After`, so well-behaved clients slow down.
- **Clock skew** between replicas using their own clocks; use the store's clock.

## In an interview

Say the algorithm and why (usually a token bucket), the key (user, tenant, IP, API key), where the state lives, what happens when the store fails, and what the client sees.

## Where you built it

[Phase 6, step 5](../../lessons/06-safe-shared-queries/TEACHING.md#step-5-rate-limiting):
- a token bucket per tenant, local then in Redis through a Lua script using the server's clock;
- a fallback that fails open to a local limit;
- `429` with `Retry-After`;
- counting only requests the policy allowed.

[DSA guide 19](../../dsa/19-design/README.md) rebuilds the bucket at interview size.
