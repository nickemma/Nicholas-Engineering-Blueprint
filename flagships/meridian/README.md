# MERIDIAN — the journey

The system lives at **https://github.com/nickemma/meridian**. It shipped before this
blueprint existed.

- Charter (retro-documentation, *not* frozen intent) — [/docs/part-6-flagships/meridian.md](../../docs/part-6-flagships/meridian.md)
- Repository standard — [Chapter 40b](../../docs/part-6-flagships/repo-standard.md)
- [audit.md](audit.md) — the Level II re-examination
- Detours triggered by this work — [/detours](../../detours)

**Status:** ● shipped · re-examination scheduled in Module 2 (B5)

## Why there is no calibration table here

Meridian's charter documents a system that already existed. It records what is, not what
was predicted — so there is nothing to score, and filing predictions for work already
finished would be the least honest thing in this repository. See
[Chapter 40b §8](../../docs/part-6-flagships/repo-standard.md).

Its Level II work is **documentation and audit**, not a rebuild. Findings go in
[audit.md](audit.md).

## Re-examination tasks (Module 2)

| | Task | Done |
|---|---|---|
| R1 | Raft annotated line by line against the paper — elections, log matching, membership change, snapshots, read-index | ☐ |
| R2 | The WAL and fsync discipline re-read with Module 2's theory | ☐ |
| R3 | The linearizability claim either verified with a checker or downgraded in wording | ☐ |
| R4 | README upgraded to the Meridian Standard it already defines | ☐ |
| R5 | Repository docs brought to the Chapter 40b skeleton — threat model, benchmarks, ADRs | ☐ |
| R6 | Policy / lease / audit interfaces documented as **provided** to VEYRONIX and SYNAPSE-AI | ☐ |

## Session log

| # | Date | Work | Tag | Detours | Loose end |
|---|---|---|---|---|---|
