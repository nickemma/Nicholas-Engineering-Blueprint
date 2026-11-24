# Rust edge proxy evidence

The local gate passed from a fresh lesson replay. The pool check saw one upstream socket for 12 downstream connections. Disabling reuse increased the count to 12 sockets. The breaker bypass sent a fourth request upstream, and the gate caught it. [Gate transcript](gate.txt)

## HTTP/1.1 comparison

On one Linux WSL2 host, a Go client fetched the same 4 KiB object from the same Go origin directly, through the release build of the Rust proxy, and through Envoy 1.38.5. Each path ran three times for 2 seconds at each offered rate. It had 32 successful warm-up requests per trial. The driver, origin, and proxies used two workers each. The runs used loopback and kept the upstream pools warm across trials where the existing sockets were still usable. Exact configuration and versions are in the captured files. [Environment](reference/environment.json) · [Envoy configuration](reference/envoy.json)

Each range below spans three trial values. Latencies use successful completions measured from the scheduled arrival. Drops count arrivals the driver discarded when all 64 slots were occupied.

| Offered req/s | Path | Successful req/s | p50 (ms) | p99 (ms) | Driver drops per trial |
|---:|---|---:|---:|---:|---:|
| 200 | Direct | 199.9 | 1.52–1.53 | 2.15–2.22 | 0 |
| 200 | Rust | 199.9–200.0 | 1.71–1.73 | 2.37–2.55 | 0 |
| 200 | Envoy | 199.9–200.0 | 1.90–1.95 | 2.65–2.66 | 0 |
| 8,000 | Direct | 7,886–7,999 | 0.37–0.48 | 1.66–13.29 | 0–220 |
| 8,000 | Rust | 7,857–7,998 | 0.63–0.87 | 1.76–6.65 | 0–280 |
| 8,000 | Envoy | 7,656–7,996 | 1.36–1.74 | 3.23–10.08 | 0–680 |

- At 200 req/s, all three paths returned the expected HTTP/1.1 response for every arrival. Direct had the lowest latency. The driver's p99 launch lag was 1.21–1.29 ms across the trials, so a substantial part of the measured latency elapsed before dispatch.
- At 8,000 req/s, driver drops accounted for every missed completion. The direct path also dropped arrivals in two trials, and the ranges overlapped. These trials show pressure in the shared setup and do not establish a proxy capacity ranking.
- No reference trial produced an HTTP error, I/O error, timeout, or protocol or payload mismatch. Each origin request count equaled the successful measured responses plus the 32 warm-up requests. The origin also counted newly accepted sockets, so a zero in a warm trial means existing upstream connections sufficed.

The offered rates came from a single exploratory sweep during development, before enabling upstream TCP no-delay in Rust. Its 10,000 req/s direct run already dropped arrivals. [Pilot summaries](pilot.jsonl)

## Raw runs

Each reference summary row names a gzip-compressed JSON trial in the same directory. Every scheduled arrival has timestamps, a status, and an outcome. Each trial also records measured wall time and the delta from the origin counters. [Trial summaries](reference/results.jsonl) · [Raw runs](reference) · [Envoy log](reference/envoy.log)

Recreate the experiment from a replayed build using the commands in [Compare the proxy with Envoy](../lessons/06-compare-with-envoy.md).
