# Load balancing

A load balancer spreads requests over several servers, so capacity grows by adding servers and one server's death doesn't take the service down. It also hides the servers behind one address.

## The options

| Choice | Options | Trade-off |
|---|---|---|
| **Layer** | **L4** (TCP/UDP: forwards connections, can't see requests) or **L7** (HTTP: sees each request, can route by path, header or tenant, retry, terminate TLS) | L4 is cheaper and protocol-agnostic. L7 is smarter, but parses every request. Long-lived connections (gRPC, HTTP/2) need L7 to balance per request, not per connection |
| **Algorithm** | Round-robin; least connections or least outstanding requests; **power of two choices** (pick two at random, use the less loaded); consistent hashing (stickiness) | Round-robin ignores load. Least-loaded needs fresh load data. Two choices gets most of the benefit with little coordination. Hashing keeps a client or key on one server, which helps caches |
| **Where** | A dedicated balancer (hardware, cloud ALB/NLB), a client-side library, or a sidecar | Client-side and sidecars remove a hop and a single point of failure, but every client needs the server list |
| **Health** | Active checks (probe each server) and passive ones (count failures on real traffic) | Active catches dead servers; passive catches the half-broken ones that still answer probes |

## Numbers to know

- An L7 proxy adds roughly 0.1–1 ms per request, more with TLS on new connections.
- Cloud load balancers scale by themselves, but take minutes to warm up for sudden spikes. Plan for that, or pre-warm.

## How it fails

- **The balancer is a single point of failure.** Run two or more, behind DNS or a virtual IP.
- **Health checks that lie.** A server passes `/health` but fails real requests. Separate liveness ("restart me") from readiness ("send me traffic"), and check dependencies in readiness.
- **Retry storms.** Every layer retries, so load multiplies exactly when servers are struggling. Use retry budgets.
- **Uneven long connections.** One connection can carry a thousand requests to one server. Close connections periodically (Phase 6 found this, with certificates that weren't reloaded).
- **Thundering herd** when a server comes back cold, or a new one starts with an empty cache.

## In an interview

Say which layer, which algorithm and why, how health is checked, and how the balancer itself avoids being the single point of failure. Then move on. It's rarely the crux.

## Where you built it

[Phase 5, step 4](../../lessons/05-constrained-operations/TEACHING.md#step-4-services-dns-and-load-balancing):
- Kubernetes Services and kube-proxy (L4);
- DNS;
- a layer-7 balancer of your own, with readiness.

[Phase 6](../../lessons/06-safe-shared-queries/README.md) found that busy HTTP/2 connections never moved, and fixed it by limiting connection age.
