# Rust edge proxy gate

Run from the assembled learner workspace. Set `BLUEPRINT_ROOT` to the absolute path of the Blueprint checkout. The gate runs rustfmt, Clippy, Rust tests, and Python 3 fixtures against the built binary. It binds only loopback sockets.

~~~bash
module="$BLUEPRINT_ROOT/3-tracks/cloud-and-network/02-rust-edge-proxy"
bash "$module/gate/run.sh" "$PWD"
~~~

| Check | Required observation |
|---|---|
| TCP half-close | The origin reads all request bytes through EOF and the client still reads the full origin response. |
| HTTP routing | The two origins see only their selected requests. The query and binary body arrive intact. An unknown route returns 404 and an oversized body returns 413. |
| Pooling | Twelve requests over separate downstream connections produce fewer than twelve upstream accepts. Disabling reuse produces twelve and fails that assertion. |
| Capacity and deadline | A stalled origin sees at most 32 in-flight requests. Those requests return 504, the excess request returns 503, and the other origin returns 200. Both routes serve again after recovery. |
| Circuit breaker | An open-circuit request leaves the origin count fixed. A failed probe reopens the circuit, and a single successful probe restores traffic. Bypassing breaker admission fails the origin-count assertion. |

The reference and negative builds each run against local fixtures. The two changes used for the negative builds live in temporary copies of the learner workspace. [Captured gate output](../evidence/gate.txt)

The performance portion runs separately with Docker and Go. Include a direct baseline and repeated samples from both proxies at two offered rates. Report response parity, successful throughput, p50 and p99, launch lag, and the outcomes of all offered requests. [Benchmark procedure](../lessons/06-compare-with-envoy.md) · [Reference results](../evidence/README.md)
