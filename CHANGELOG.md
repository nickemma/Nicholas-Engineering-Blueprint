# Changelog

Version history for this handbook. The handbook is maintained as a system: versioned, reviewed at every stage exit, and re-scored at every major release.

Format follows [Keep a Changelog](https://keepachangelog.com). Point releases are refinements; major releases are changes of direction.

---

## [2.0.0] — 2026-08-12

Restructured from a self-directed 40-week roadmap into a taught 49-week apprenticeship. This is a change of method, not of destination — the identity sentence and the target specialization are unchanged.

### Added
- `docs/how-this-works.md` — the teaching contract: the ten-step cycle, the five lesson types, the advancement rule, the code-review format
- `docs/curriculum-tree.md` — nineteen stages in six layers, each stage a question
- `stages/` — one folder per stage, with a fixed seven-child layout (`lessons/`, `labs/`, `experiments/`, `breaks/`, `project/`, `reflections/`, `assessment.md`)
- The lesson file anatomy — nine fixed sections ending in *explaining it back*, which is the advancement gate
- `START-HERE.md` — entry point for people following along
- `PROGRESS.md` — live position, per-stage bars, and the failures-survived log
- `DEBT.md` — skipped or half-understood material, reviewed at every stage exit
- `breaks/` as a first-class artifact — failure days are curriculum, not garnish
- `experiments/` as a first-class artifact — every measurement names its hardware
- Continuous operation as a metric: the inference gateway goes live in Stage 6 and stays up, with an incident log
- Design defence as the final stage — a written design interrogated under hostile questioning

### Changed
- Six Levels → nineteen Stages in six Layers. A level was a block of time; a stage is a question with an exit assessment.
- Starting point is now zero. Nothing assumed — not Go, not Linux, not systems knowledge.
- Weekly cadence: 25–30 speculative hours → 20 committed hours, as four 3-hour lessons plus build, interview, and reflection blocks
- Single-node storage engine now precedes consensus. Raft replicates a log; the log has to be understood first.
- AI infrastructure enters at Stage 6 (CPU-only) instead of the final third, so GPU access and platform concerns are de-risked early
- Kubernetes split into *using it* (Stage 5) and *operating stateful workloads on it* (Stage 11)
- Security distributed as a per-stage obligation with two dedicated stages, rather than one block
- Measurement promoted to a first-class skill with a standing weekly block
- Scoreboard recalibrated to what this method actually produces: stages completed, lesson write-ups, documented failures, gateway uptime, published findings
- Lattice and Tessera converge into one platform at Stage 17 rather than remaining separate flagships
- README rewritten around the six layers and the live position

### Removed
- The six-flagship portfolio target. Two systems built properly beats six with good READMEs.
- SYNAPSE-AI deferred beyond this cycle — its thinking survives inside Stage 18
- "50+ architecture documents" and similar volume metrics — inflated targets corrupt the scoreboard
- Pre-written stage folders. Stages are created the week they begin.

### Fixed
- Weekly hours corrected to 20
- Metrics that counted output volume rather than demonstrated understanding

---

## [1.1.0] — 2026-07

### Added
- Part II — Learning Architecture & Framework: the weekly planner, engineering standards, the writing system, the reading framework, repo layout

### Changed
- Success metrics re-calibrated for honesty — architecture-document and article counts redefined against what actually counts

---

## [1.0.0] — 2026-06

Initial handbook.

### Added
- Part I — Engineering Vision & Career Strategy: identity, positioning, market map, sponsorship logic, the credo, engineering and learning philosophy, skills matrix, success metrics
- The six-level, 40-week structure
- UPenn MSE-SSC alignment and the four-elective decision of record
- The flagship portfolio: EMBER, LATTICE, MERIDIAN, VEYRONIX, TESSERA, SYNAPSE-AI

---

## Release policy

- **Patch** (x.y.Z) — corrections, broken links, clarified wording
- **Minor** (x.Y.0) — a stage's material substantially revised, a new document, a metric re-set with a written reason
- **Major** (X.0.0) — a change of method or direction. Expected next at the start of the UPenn program.

Reviewed at every stage exit. A missed target triggers one of exactly two responses: re-plan the remaining weeks, or consciously re-set the target with a written reason. Silent drift is the only prohibited option.

[2.0.0]: https://github.com/nickemma/Nicholas-Engineering-Blueprint/releases/tag/v2.0.0
[1.1.0]: https://github.com/nickemma/Nicholas-Engineering-Blueprint/releases/tag/v1.1.0
[1.0.0]: https://github.com/nickemma/Nicholas-Engineering-Blueprint/releases/tag/v1.0.0
