# Track: Cloud and network

> About 25 weeks: 13 of its own, plus 12 in shared units · Builds on: the end of the core · Status: ready

## Who it's for

You want to build the systems traffic flows through: proxies, load balancers, edge networks, and the cloud platforms under them.

## Roles it targets

Network Software Engineer; Edge Engineer; Platform Engineer; Infrastructure Engineer; Cloud Infrastructure Engineer; Site Reliability Engineer. See [career.md](../../career.md).

## Shared units it needs

Skip any you've already done on another track.

- [Kubernetes and delivery](../shared-units/kubernetes-and-delivery/README.md) (5 weeks)
- [AWS and Terraform](../shared-units/aws-and-terraform/README.md) (2 weeks)
- [Messaging and resilience](../shared-units/messaging-and-resilience/README.md) (2 weeks)
- [Tenancy and abuse control](../shared-units/tenancy-and-abuse-control/README.md) (3 weeks)

## Parts

| Part | What you learn and build |
|---|---|
| [01 Networking in depth](01-networking-in-depth/README.md) | Congestion control, bufferbloat, HTTP/2 and HTTP/3, CDNs, anycast and BGP, partial partitions |
| [02 A Rust edge proxy](02-rust-edge-proxy/README.md) | L4/L7, connection pooling, circuit breaking; then Envoy beside it on the same benchmark |
| [03 The proxy's control plane](03-proxy-control-plane/README.md) | Config push, health checks, mTLS rotation, a sidecar, OpenBao, signed webhooks and SSRF, eBPF/XDP |
| [04 Capstone: a programmable edge proxy](04-capstone-programmable-edge-proxy/README.md) | Benchmarked for requests per second, memory and zero-downtime reloads |
