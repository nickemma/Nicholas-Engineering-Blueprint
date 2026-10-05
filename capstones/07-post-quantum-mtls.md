# 7. The cost of a post-quantum service mesh

**Field:** quantum-safe cryptography · distributed systems · networking · **Difficulty:** medium–high

## Problem

A large enough quantum computer could break the key exchange that protects today's TLS connections. Traffic recorded today could be decrypted later ("harvest now, decrypt later"). The response is **post-quantum cryptography**. NIST standardised the ML-KEM key-encapsulation mechanism in FIPS 203 (2024), and major TLS libraries now offer **hybrid** key exchange that combines classical X25519 with ML-KEM. Go's `crypto/tls` enables `X25519MLKEM768` by default from Go 1.24.

Post-quantum keys and ciphertexts are much **larger**. In a microservice platform, where services open many short mTLS connections, often over constrained links, the extra bytes and round trips may matter.

## Who

Platform and security teams planning a migration to post-quantum cryptography. Operators of service meshes, IoT fleets and edge systems.

## Gap

- Performance studies of post-quantum TLS mostly measure single handshakes between a browser and a server (for example, Sikeridis, Kampanakis and Devetsikiotis, NDSS 2020).
- Fewer measure the effect on a **whole distributed system**: tail latency of request chains, connection churn, constrained links, CPU at scale, and the interaction with connection pooling.

## Research question

> What does switching a microservice platform's mTLS from classical to hybrid post-quantum key exchange cost, in p50/p99 latency of multi-hop requests, CPU and bandwidth? Under which conditions (connection churn, packet loss, low bandwidth, handshake-heavy traffic) does the cost become significant, and which mitigations recover it?

## Hypothesis and baseline

- **Baseline:** classical X25519 key exchange in TLS 1.3.
- **Hypothesis:** with connection pooling, the steady-state cost is negligible. But with high connection churn on lossy, low-bandwidth links, larger handshakes can need extra round trips and visibly raise p99. Session resumption and long-lived connections recover most of that.

## System

- **Runway's services** with mTLS between them (from Phase 6), with the key-exchange groups made configurable.
- **A request-chain workload:** client → API → three downstream services, with a configurable connection policy (new connection per request, pooled, resumed).
- **Network emulation** (Phase 5): bandwidth, latency, loss, and MTU limits.
- **Packet capture analysis** (Phase 2's `tcpdump` skills) to count handshake bytes and round trips.
- **Load generation and analysis** with your Python Bridge tools.

## Experiment

| Variable | Values |
|---|---|
| Key exchange | X25519; X25519MLKEM768 (hybrid) |
| Connection policy | New per request; pooled; session resumption |
| Link | Data-centre; 10 Mbit/s with 50 ms; 1 Mbit/s with 200 ms and 2% loss |
| Request chain depth | 1, 3, 5 hops |
| Load | Low to near saturation |

## Measures

- p50/p99 end-to-end latency.
- Handshake time.
- Bytes and packets per handshake.
- CPU per request.
- Throughput at the SLO.

## What you might find

The cost may be invisible for pooled connections in a data centre, and noticeable for churn-heavy traffic on lossy links, where a bigger first flight of the handshake doesn't fit in the initial congestion window. Mitigations may matter more than the algorithm itself.

## Limitations to expect

- Software crypto on one CPU type.
- Post-quantum *signatures* (certificates) are a separate, larger change; say whether you include them.
- The library's defaults change over time; pin and record versions.

## Skills used

Phases 2 (gRPC, packets), 5 (network emulation, observability), 6 (mTLS, PKI) and the Python Bridge and Phase 7 (experimental method).

## Read first

- NIST FIPS 203, *Module-Lattice-Based Key-Encapsulation Mechanism Standard*, 2024
- Sikeridis, Kampanakis and Devetsikiotis, *Post-Quantum Authentication in TLS 1.3: A Performance Study*, NDSS 2020
- The Go `crypto/tls` documentation for `CurvePreferences` and the release notes covering `X25519MLKEM768`
- Kurose & Ross §8.6 (TLS)
