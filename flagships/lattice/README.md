# LATTICE — the journey

The system lives at **https://github.com/nickemma/lattice**. **One repository, not six** — see [Chapter 40b §8](../../docs/part-6-flagships/repo-standard.md).
Its architecture, API, threat model, runbook, and benchmark results live there, current
as of `main`. This directory holds what the code cannot: intent, prediction, surprise,
and judgment.

- Charter (frozen intent) — [/docs/part-6-flagships/lattice.md](../../docs/part-6-flagships/lattice.md)
- Repository standard — [Chapter 40b](../../docs/part-6-flagships/repo-standard.md)
- [calibration.md](calibration.md) — every prediction, predicted beside actual
- [as-built.md](as-built.md) — written at level exit, never before
- Detours triggered by this build — [/detours](../../detours)

**Status:** ○ not started

## Behavior ladder (Module 2)

Charter point 3 decomposed into shippable increments. Written at kickoff; see
[Chapter 40b §5](../../docs/part-6-flagships/repo-standard.md).

| | Behavior | Satisfies charter point 3 |
|---|---|---|
| B1 | durably stores a key; survives `kill -9` mid-write | no managed data services (constraint) |
| B2 | LSM with compaction; reads don't degrade with size | — (substrate for the index) |
| B3 | two processes talk with deadlines, retries, backpressure | internal gRPC contract |
| B4 | three nodes, one keyspace; one dies, reads succeed | survives node loss · tunable quorums |
| B5 | MERIDIAN re-read as a stranger, one real bug found | [meridian/audit.md](../meridian/audit.md) |
| B6 | a linearizability checker passes the store, or says why not | property testing (point 19) |
| B7 | wordcount over 10 GB, worker killed, answer still right | deterministic job re-execution |
| B8 | crawler politely fetches 100k+ pages, frontier in LatticeKV | crawl >=1M politely · SimHash dedup |
| B9 | ranked results from your own index, p99 < 200 ms | inverted index · PageRank · query p99 |
| B10 | chaos suite partitions during the demo, numbers hold | partial results within deadline |


## Session log

| # | Date | Shipped | Tag | Detours | Loose end |
|---|---|---|---|---|---|
