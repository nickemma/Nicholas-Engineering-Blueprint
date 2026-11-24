# Programmable edge proxy evidence

The portable gate tested swaps and rollback through the real Go mTLS sidecar and Rust proxy. A request held at the original origin completed after a new request reached the updated origin. The disposable control returned HTTP 503 to the held request and failed the continuity assertion. [113-step replay](replay.txt) · [Portable transcript](reference/portable.txt) · [Clean export verification](clean-export.txt)

## Managed reloads at 120 requests per second

Each trial scheduled 240 requests over two seconds. The release binary served 720 timed requests in three trials without updates and 720 in three reload trials. There were no drops, timeouts, resets, unexpected statuses, or mismatched responses. Each reload incorporated four applied generations and one rejected attempt. Readback after the rejected generation three confirmed that generation two and its route still served.

| Managed mode | Successful req/s | Scheduled-start p50 (ms) | Scheduled-start p99 (ms) | Sampled Rust peak RSS (KiB) |
|---|---:|---:|---:|---:|
| Steady | 119.94–119.98 | 1.80–1.86 | 2.62–2.78 | 4,004–4,044 |
| Reload | 119.93–119.99 | 1.74–1.92 | 2.71–2.81 | 4,108–4,160 |

The successful update windows ranged from 5.34 to 7.40 ms, including health checks and the management round trip. An overlapping request could use either observed origin. The held-request check and generation readbacks establish the before and after behavior independently. RSS samples were taken every 25 ms. The managed trial measures one Rust process with a separate same-host sidecar and origin fixture. [Managed raw trials](reference/managed)

## Steady HTTP/1.1 comparison

The same 4 KiB object was requested directly and through Rust and Envoy 1.38.5. Each pair of rate and path had three two-second trials. All 48,600 timed requests returned correct bytes. The pilot selected 2,500 req/s as the higher reference rate after an Envoy run at 5,000 req/s recorded 166 driver-cap drops. [Environment](reference/steady/environment.json) · [Pilot](reference/pilot.jsonl)

| Offered req/s | Path | Successful req/s | Scheduled-start p99 (ms) | Sampled Rust peak RSS (KiB) |
|---:|---|---:|---:|---:|
| 200 | Direct | 199.9–200.0 | 2.09–2.14 | — |
| 200 | Rust | 199.9–200.0 | 2.47–2.57 | 4,052–4,060 |
| 200 | Envoy | 199.9–200.0 | 2.59–2.73 | — |
| 2,500 | Direct | 2,499.4–2,499.7 | 1.60–1.74 | — |
| 2,500 | Rust | 2,499.1–2,499.4 | 1.39–1.77 | 4,348–4,432 |
| 2,500 | Envoy | 2,499.1–2,499.5 | 1.82–2.43 | — |

The runner samples Rust RSS from driver launch, including warm-up. The paths all kept pace with these offered rates. Scheduled-start latency includes driver launch lag, and these runs measure the tested fixture rather than proxy capacity. [Steady summaries](reference/steady/results.jsonl) · [Raw trial directory](reference/steady)

## Before and after CPU profiles

Both paths built five million equivalent upstream URIs using IPv4 and IPv6 inputs. The formatted variant spent samples in address formatting. Caching the parsed authority lowered the median of five unprofiled timings from 2.145 s to 1.204 s, a 1.78× increase in isolated construction rate. This experiment measures URI construction. The separate HTTP benchmark measures the final proxy build. [Before flame graph](reference/profile/before.svg) · [After flame graph](reference/profile/after.svg) · [Raw profile timings](reference/profile/profile.jsonl)

## Release

The archive contains the standalone source, locked inputs, operator and benchmark commands, and the reference captures. The design record describes route publication and recovery after process restart. [Standalone source archive](switchyard-edge-capstone.tar.gz) · [Architecture decision record](ADR.md) · [Gate and export instructions](../gate/README.md)
