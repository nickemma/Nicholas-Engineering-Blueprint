# EMBER — the journey

The system lives at **https://github.com/nickemma/ember**.
Its architecture, API, threat model, runbook, and benchmark results live there, current
as of `main`. This directory holds what the code cannot: intent, prediction, surprise,
and judgment.

- Charter (frozen intent) — [/docs/part-6-flagships/ember.md](../../docs/part-6-flagships/ember.md)
- Repository standard — [Chapter 40b](../../docs/part-6-flagships/repo-standard.md)
- [calibration.md](calibration.md) — every prediction, predicted beside actual
- [as-built.md](as-built.md) — written at level exit, never before
- Detours triggered by this build — [/detours](../../detours)

**Status:** ○ not started — charter not yet frozen

## Behavior ladder (Module 1)

Charter point 3 decomposed into shippable increments. Written at kickoff; see
[Chapter 40b §5](../../docs/part-6-flagships/repo-standard.md).

| | Behavior | Satisfies charter point 3 |
|---|---|---|
| B1 | accepts one connection and echoes | — (substrate) |
| B2 | holds 10,000 idle connections | — (substrate) |
| B3 | understands HTTP/1.1; fuzzer-proof parser | reverse-proxy over HTTP/1.1 |
| B4 | ported to Go, same benchmark runs | constraint 5 — C → Go, no frameworks |
| B5 | proxies upstream, survives upstream death | reverse-proxy · circuit breaking |
| B6 | caches, provably correct vs `Cache-Control` | LRU+TTL cache honoring cache-control |
| B7 | per-tenant rate limits, survives a burst | per-tenant config · token-bucket limiting |
| B8 | TLS 1.3, cert rotated with no dropped connection | terminate TLS 1.3 · hot reload, zero drops |
| B9 | on AWS, instrumented, p99 published vs nginx | non-functional requirements — all three |

**Deferred:** admin console (charter point 3) → Module 3, when VEYRONIX gives a reason to build consoles.

## Session log

| # | Date | Shipped | Tag | Detours | Loose end |
|---|---|---|---|---|---|
