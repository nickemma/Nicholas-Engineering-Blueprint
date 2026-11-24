# Proxy control-plane evidence

The fresh replay rebuilt both the proxy and management code in 84 steps. It ran the portable gate, which includes the Rust tests, Go integration tests under the race detector, and the deliberately changed retry acknowledgement. [Replay](replay.txt) · [Portable gate transcript](portable.txt)

| Check | Observed result |
|---|---|
| Route change | The unhealthy candidate left generation zero active. Once the candidate was healthy, the held request returned from origin A and the new request returned from origin B. Rollback published the original route as generation two. |
| Lost acknowledgement | Retrying generation one returned `unchanged`. The disposable build returned `duplicate` instead and failed the expected retry assertion. |
| Management identity and rotation | The observer identity was denied. Fresh connections observed controller/sidecar serial pairs 3/2, 3/5, and 6/5. Generation three was applied and read back on the rotated connection. |
| Webhook receipt | A valid retry left one stored receipt. Invalid signatures, expiration, conflicting duplicates, unregistered destinations, and redirects were rejected. |

## Live profiles

- **OpenBao 2.7.1.** The service ran as a disposable loopback-published dev container. The scoped token read the signing path and received HTTP 403 for another path. The receiver accepted deliveries with KV versions one and two and refused the retired version. [OpenBao transcript](openbao.txt)
- **XDP.** The replay-built Rust proxy ran in the isolated lab on Linux 6.18.58.1 under WSL2. The generic XDP program on `edge-lab` counted from 2 to 34, while the origin request count went from 1 to 6. All five responses matched the baseline bytes. Packets include TCP setup and acknowledgements, and the packet delta can vary across runs. [XDP transcript](xdp.txt)

Reproduce the runs from the assembled learner workspace. [Gate instructions](../gate/README.md)
