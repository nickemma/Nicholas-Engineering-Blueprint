# EMBER — Edge Gateway

*Organization-grade project charter (24-point standard).*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../../README.md) — v1.1*

---

# Chapter 41 · EMBER — Edge Gateway

**Level I · Weeks 1–5 · AWS · Provides: TLS termination, proxying, caching, rate limiting to every later flagship**

### 1–2 · Vision & problem

Every internet-facing system needs an edge: TLS, routing, caching, protection. Teams rent it (Cloudflare, an ALB) without understanding it. EMBER is that layer, built from raw sockets — both a permanent piece of personal infrastructure and proof of from-the-metal competence.

### 3 · Functional requirements

- Terminate TLS 1.3; reverse-proxy to configured upstreams over HTTP/1.1 and HTTP/2.
- Per-tenant, per-route configuration: upstreams, cache policy, rate limits.
- LRU+TTL response cache honoring cache-control; token-bucket rate limiting; per-upstream circuit breaking.
- Admin API + console for live config; hot reload with zero dropped connections.

### 4 · Non-functional requirements

- p99 added latency < 2 ms at 10k RPS on a single mid-size EC2 instance.
- Config changes apply in < 1 s without connection loss; graceful restart.
- Observable: RPS, p50/p99, cache hit rate, upstream health as Prometheus metrics.

### 5–6 · Constraints & trade-offs

- **Constraint:** data-plane core hand-written (C → Go), no proxy frameworks; BoltDB for config (embedded, simple).
- **Trade-off:** single-node first — chose operational simplicity over HA for v1; the scalability roadmap adds a shared control plane. Documented, not hidden.
- **Trade-off:** BoltDB (single-writer) over a networked store — fine for config write rates, revisited if multi-node.

### 7–9 · Architecture / sequence / component (described)

- **Architecture:** clients → [EMBER: TLS → router → middleware chain → upstream pool] → upstreams; control plane (admin API + BoltDB) beside the data plane; Prometheus scrapes both.
- **Sequence (cached request):** client → TLS handshake → route match → rate-limit check → cache lookup (hit) → response; (miss) → breaker check → upstream → cache store → response, with access log emitted throughout.
- **Component:** proxy · route · limit · cache · breaker · admin · store · console — each isolated, tested in isolation.

### 10–11 · Schema & API

- **BoltDB buckets:** tenants · routes(host,path→upstreams,policy) · certs(domain→pem,expiry) · limits(tenant→rate,burst) · audit(append-only).
- **Admin API:** CRUD /v1/routes, /v1/certs, /v1/limits; GET /v1/upstreams/health; GET /metrics; GET /healthz.

### 14–15 · Threat model & security

- Assets: TLS private keys, upstream topology, tenant configs. Adversaries: external attacker (DDoS, slowloris), malicious tenant (quota abuse).
- Controls: strict TLS config, connection/rate limits, FD-exhaustion protection, per-tenant isolation, admin API behind auth, audit log of all config changes.

### 19–20 · Testing & benchmarks

- Unit (parser, limiter, cache); integration (full proxy path); load (wrk vs nginx baseline); chaos (upstream death, cert expiry, slowloris).
- Published: p50/p99/throughput vs nginx on identical EC2; flamegraphs before/after one optimization; cache on/off deltas.

### 22–24 · Scalability roadmap, future, lessons

- **Scale:** shared control plane (etcd-backed) → multiple data-plane nodes → anycast. **Future:** WAF rules, HTTP/3, mTLS to upstreams. **Lessons:** captured in the blog post — what nginx does that you learned to respect.
