# The Flagship Repository Standard

*Companion to [The Flagship Charter Standard](charter-standard.md) — the other half of the 24 points.*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../../README.md) — v1.2*

---

# Chapter 40b · The Flagship Repository Standard

**Why this chapter matters:** Chapter 40 defines what a charter contains before a system exists. This chapter defines what the system's own repository contains once it does, how that repository is *derived* from the charter, and how the gap between the two is measured rather than quietly closed. A charter without this chapter becomes a document that gets edited until it agrees with reality — which destroys the only thing it was for.

---

## 1 · One document cannot be both frozen and current

A charter makes dated, falsifiable claims: *p99 added latency under 2 ms at 10k RPS*, *five BoltDB buckets*, *tokens/sec competitive with vLLM*. Its entire value comes from never being edited. An architecture document that is never edited, meanwhile, is a lie by the fourth week of the build.

So the 24-point standard is a standard for a **pair** of documents, separated by tense.

| | Charter — `docs/part-6-flagships/<name>.md` | Repository docs — `<flagship>/docs/` |
|---|---|---|
| Tense | What I set out to build | What exists right now |
| Written | Once, at kickoff, before code | Continuously, as code changes |
| Edited | Never — append-only | Every session that changes behavior |
| Audience | Someone assessing my judgment | Someone using or operating the system |
| Being wrong means | A calibration row | A bug |

Neither is a copy of the other. The repository documents are *derived* from the charter at kickoff and then diverge freely — and the divergence is the deliverable.

---

## 2 · Where each of the 24 points lives

**6 charter · 15 repository · 2 split · 1 blueprint.**

| # | Point | Home | Location | Anchor |
|---|---|---|---|---|
| 1 | Vision | **Charter** | Two lines echoed in repo `README.md` | — |
| 2 | Problem statement | **Charter** | — | — |
| 3 | Functional requirements | **Charter** | Decomposed into the behavior ladder (§5) | — |
| 4 | Non-functional requirements | **Charter** | Measured in `docs/benchmarks.md` | `charter:4` |
| 5 | Constraints | **Charter** | — | — |
| 6 | Trade-offs | **Split** | Decided before → charter. Discovered during → `docs/decisions/` | — |
| 7 | Architecture diagram | Repo | `docs/architecture.md` + `docs/assets/` | `charter:7` |
| 8 | Sequence diagram | Repo | `docs/architecture.md` | `charter:8` |
| 9 | Component diagram | Repo | `docs/architecture.md` | `charter:9` |
| 10 | Database schema | Repo | `docs/architecture.md` | `charter:10` |
| 11 | API specification | Repo | `docs/api.md` | `charter:11` |
| 12 | File structure | Repo | It *is* the repo; a `tree` block in `README.md` | — |
| 13 | Infrastructure diagram | Repo | `deploy/README.md` | `charter:13` |
| 14 | Threat model | Repo | `docs/threat-model.md` | `charter:14` |
| 15 | Security controls | Repo | `docs/threat-model.md` — controls table | `charter:15` |
| 16 | CI/CD pipeline | Repo | `.github/workflows/` — the pipeline is the document | — |
| 17 | Observability | Repo | `docs/runbook.md` + `deploy/dashboards/` | `charter:17` |
| 18 | Monitoring & logging | Repo | `docs/runbook.md` | `charter:18` |
| 19 | Testing strategy | Repo | `docs/testing.md` | `charter:19` |
| 20 | Performance benchmarks | **Split** | Predicted → charter (point 4). Measured → `docs/benchmarks.md` | `charter:20` |
| 21 | Deployment guide | Repo | `docs/runbook.md` | `charter:21` |
| 22 | Scalability roadmap | **Charter** | — | — |
| 23 | Future improvements | Repo | `LATER.md` — a live list, not a plan | — |
| 24 | Lessons learned | **Blueprint** | `flagships/<name>/as-built.md` + the essay | — |

**Read the EMBER charter against this table.** It covers 1–2, 3, 4, 5–6, 7–9, 10–11, 14–15, 19–20, 22–24 and omits **12, 13, 16, 17, 18, 21**. Every omitted point is repository-side. Whoever wrote that charter instinctively skipped exactly the points that describe a *running* system, because there wasn't one. The gaps are not a defect to patch — they are this split, discovered before it was named. No charter body needs surgery.

---

## 3 · The charter anchor — how derivation and divergence become the same mechanism

Every repository document section that implements a charter point carries an HTML comment naming it:

```markdown
## Storage
<!-- charter:10 · schema -->
BoltDB, five buckets: tenants, routes, certs, limits, audit.
```

Invisible when rendered. Present in the file. Three things follow.

**Derivation.** At kickoff, each anchored section is created by copying the charter's claim in verbatim, as an initial hypothesis. That copy is the last time the two documents agree, and it is deliberate: the repo document starts as the charter's prediction and is then edited by reality.

**Coverage.** `grep -rn "charter:" docs/` lists every point the repository claims. `scripts/divergence.sh` (in this blueprint) does it across all six repos and prints which of the 24 have no anchor yet — a live map of what remains unbuilt.

**Divergence, caught at the moment it happens.** When a session's edit contradicts an anchored claim, one line goes in that commit's body:

```
feat(store): persist breaker state across restart

Behavior: M1-B5
Diverges: charter 10 — six buckets, not five; circuit state must survive restart
```

Then `git log --grep="^Diverges:"` is the divergence history, for free, and `as-built.md` gets **assembled at level exit rather than composed from memory**.

> **The rule:** never edit an anchored repository section to match the charter. Edit it to match the code, and record the divergence. The charter is allowed to be wrong forever; that is its job.

---

## 4 · The repository skeleton — identical in all six

Copy `templates/repo-skeleton/` at every kickoff.

```
<flagship>/
├── README.md              what it is · quickstart · architecture diagram · status · tree (12)
├── LICENSE                Apache-2.0
├── Makefile               up · test · bench · lint · fmt
├── CHANGELOG.md           releases — v0.1.0, v0.2.0 …
├── LATER.md               the cut line's graveyard (23)
├── docs/
│   ├── architecture.md    7 · 8 · 9 · 10
│   ├── api.md             11
│   ├── threat-model.md    14 · 15
│   ├── runbook.md         17 · 18 · 21
│   ├── benchmarks.md      4 · 20
│   ├── testing.md         19
│   ├── decisions/         6 (discovered) — ADRs, numbered
│   └── assets/            diagram sources + renders
├── deploy/                13 — Dockerfile · compose · terraform · dashboards
├── .github/workflows/     16
└── <language layout>      12
```

Eight documents, six repos, one shape. By TESSERA you will open a new repo and know exactly what the empty files are before you've decided anything about the system.

**Note on ADRs.** `docs/decisions/` replaces the `TRADEOFFS.md` the v1.1 journey READMEs promised, and it's an upgrade: dated, individually linkable, one decision per file beats one growing document nobody re-reads. The test for whether something is an ADR: *would a future contributor otherwise reverse this decision without knowing why it was made?* `SO_REUSEADDR` is a code comment. "C data plane before the Go port" is an ADR.

---

## 5 · How the charter tells you what to type today

Charter point 3 states what must be true at the end. It is not a work queue. The **behavior ladder** in `flagships/<name>/README.md` is that requirement set decomposed into orderable, individually shippable increments — and it is the join between the charter and a Tuesday evening.

EMBER, worked:

| Behavior | Satisfies charter point 3 requirement |
|---|---|
| B1 · accepts one connection, echoes | — (substrate) |
| B2 · holds 10,000 idle connections | — (substrate) |
| B3 · understands HTTP/1.1, fuzzer-proof parser | reverse-proxy over HTTP/1.1 |
| B4 · ported to Go, same benchmark | constraint 5 (C → Go, no frameworks) |
| B5 · proxies upstream, survives upstream death | reverse-proxy · per-upstream circuit breaking |
| B6 · caches, provably correct vs `Cache-Control` | LRU+TTL cache honoring cache-control |
| B7 · per-tenant rate limits, survives a burst | per-tenant config · token-bucket limiting |
| B8 · TLS 1.3, cert rotated with no dropped connection | terminate TLS 1.3 · hot reload, zero drops |
| B9 · on AWS, instrumented, p99 published vs nginx | non-functionals 4 — all three |

Two behaviors map to no requirement. That's correct: B1 and B2 are the scaffolding a gateway stands on, and the charter describes a gateway, not a curriculum. Conversely, "admin API + console" appears in point 3 but in no behavior — it lands in Module 3, when VEYRONIX gives you a reason to build consoles. Note it in the ladder as deferred rather than leaving it unaccounted for.

Every kickoff produces this table. It takes twenty minutes and it is the difference between a charter that guides the build and a charter that decorates the repo.

---

## 6 · The kickoff ritual — ninety minutes, identical for every flagship

This is what you come back to do when each one starts.

**Blueprint side — 30 minutes**

1. **Sanity-check the predictions, then freeze.** Vague claims are fixable *only now*. "Competitive with vLLM" is not a prediction; replace it with a number you'll be scored against. After the freeze, never.
2. **Stamp the charter.** At the top: `> **Frozen** YYYY-MM-DD at blueprint v1.2. Append-only from here.`
3. **Extract predictions into `calibration.md`.** Every number, count, and named entity from points 4, 10, and 11 becomes a row with *Predicted* filled and *Actual* blank.
4. **Write the behavior ladder** into `flagships/<name>/README.md`, mapped to point 3 as in §5, with an empty session log beneath it.
5. **Create `as-built.md`** with headers only and a line saying it's written at level exit.

**Repository side — 60 minutes**

6. **Copy `templates/repo-skeleton/`.** Every document, including ones for parts that don't exist yet.
7. **Seed the anchors.** Under each `<!-- charter:N -->`, paste the charter's claim verbatim. Where nothing is built, write `**Status:** not built.` beneath the anchor — so the full 24-point shape is legible from commit one and you always know what's outstanding.
8. **Seed `LATER.md`** from charter point 23.
9. **Set the repo description and topics.** One line from charter point 1; topics from the technology set. This is the first thing a reviewer reads.
10. **First commit:** `docs: repository skeleton derived from <name> charter @ blueprint-v1.2`

That commit message is the derivation, recorded in git.

---

## 7 · Level exit — writing `as-built.md`

Run `scripts/divergence.sh <name>`. Walk each anchor against its charter line. Then:

```markdown
# EMBER — as built

Charter frozen 2026-07-29 at blueprint v1.2 · shipped v1.0.0 on 2026-09-06

## Divergence
| Charter | Predicted | Shipped | Why |
|---|---|---|---|
| 4 · p99 added latency | < 2 ms @ 10k RPS | 3.4 ms @ 10k RPS | TLS handshakes dominate; session resumption unimplemented → LATER |
| 10 · schema | 5 buckets | 6 | `breakers` — circuit state must survive restart |

## Cut
| From charter | Where it went | Why |
|---|---|---|
| Admin console | Deferred to Module 3 | No reason to build a console before VEYRONIX needs one |

## Held
Point 3: all four functional requirements shipped as written. Point 5: both constraints
held — no proxy framework entered the tree. Point 22: untouched, still the plan.

## What I'd design differently
Prose. Two or three paragraphs. This is the flagship essay's first draft.
```

**The "Held" section is not padding.** A divergence table alone reads as a list of mistakes. Held requirements are evidence that some of your judgment was correct, dated, from before you knew. Over six flagships that section is the more interesting half.

Then: append an **As built** pointer to the charter (its only permitted edit), flip the README dashboard, update the metrics snapshot, bump the blueprint version, publish the essay.

---

## 8 · The six flagships — deltas from the standard

The standard above is complete for EMBER. The other five each bend it in one specific place, and the bends are where honesty is easiest to lose.

### EMBER — the clean case
Charter frozen before line one exists. Full skeleton, full calibration, nothing special. Use it as the reference implementation of this chapter.

### LATTICE — one repository, not six
Charter point 9 names six components (`kv · weave · crawler · indexer · rank · query`). That is not six repositories. LATTICE ships as one system, is benchmarked as one system, and fails as one system — so it is **one repo** with `cmd/` per component and `internal/<component>/`. Six repos for one system is fake modularity at six times the documentation cost, and it destroys the single most legible thing about LATTICE: that one person built the whole stack.
One anchor set, one `docs/architecture.md`, one benchmark document covering the crawl, the index build, and the query path.

### MERIDIAN — the exception: audit, not calibration
Meridian shipped before this blueprint existed. Its charter is retro-documentation, therefore **it cannot be frozen intent and `calibration.md` does not apply** — you cannot claim to have predicted a system you had already built. Filing predictions there would be the single most dishonest thing in the whole repo.
Instead, `flagships/meridian/audit.md`:

```markdown
# MERIDIAN — re-examination (Level II)
This charter documents a system built before the blueprint. It records what exists,
not what was predicted. No calibration table applies.

## Raft, annotated against the paper
| Paper property | My implementation | Verdict |
|---|---|---|
| Log matching | ... | correct / bug #N / unverified |
| Membership change | ... | |
| Read-index | ... | |

## Bugs found
## Claims I could not substantiate
## README upgraded to the Meridian Standard — <date>
```

That last section matters most. "Linearizable secret reads on the strong path" is a strong claim in the charter. Level II's job is to either verify it with a checker or downgrade the wording. **A claim you cannot substantiate is a liability in an interview**, and this is the document where you find that out privately first.

### VEYRONIX — freeze late, and label the head start
Partly built and publicly announced. Freeze the charter **at today's state**, and in `as-built.md` add a fourth section:

```markdown
## Already true at freeze
Points that were satisfied before Module 3 began — so the calibration table
doesn't take credit for work already done.
```

Without it, VEYRONIX's calibration looks like the most accurate prediction in the blueprint, for the obvious reason.

### TESSERA — fix the predictions before freezing
Point 4 says *"competitive with (benchmarked against) vLLM."* That is unfalsifiable and it's the most important number in your portfolio. Before freezing, commit to something scoreable — e.g. *within 2× of vLLM tokens/sec at batch 32 on a single L4, and TTFT within 50 ms at batch 1.* You are allowed to lose that bet. You are not allowed to have made no bet.
Same for *"no OOM under KV-cache pressure"* → name the admission-control threshold and the sequence length it holds to.

### SYNAPSE-AI — the threat model inversion, and pinned dependencies
Charter constraint 5 says the threat model gates the build, yet §2 routes threat models to the repo. Both hold: `docs/threat-model.md` is SYNAPSE's **first commit**, tagged `v0.0.1-threat-model` before any code — so "written before the build" is provable from git history — and it stays a living document thereafter. Frozen by tag, current on `main`.
SYNAPSE also consumes three of your own systems, so it gets a ninth document: `docs/dependencies.md`, naming the pinned tag of EMBER, MERIDIAN, and TESSERA it integrates against. When a Module 5 game day breaks it, that file is the difference between an hour and a day.

---

## 9 · What stays in the blueprint regardless

The interconnection map (Chapter 40) is a statement about the portfolio, not about any one system — it never migrates into a repository. Neither do the reading log, weekly reviews, detours, calibration tables, as-built documents, or the essays.

Compressed, the whole division:

> **The repository answers "what is this system and how do I run it?"**
> **The blueprint answers "what did he predict, what surprised him, and what does he now know?"**

No fact belongs in both.

---

## 10 · Edit required to Chapter 40

Replace the paragraph beginning *"The charters below are specified in prose and tables…"* with:

> The charters below are specified in prose and tables (diagrams described precisely enough to render in draw.io or Excalidraw). Each charter is **frozen intent**: written once at kickoff, before code, and append-only thereafter. It is *not* the repository's documentation.
>
> Of the 24 points, **six are intent** and live here permanently — vision, problem statement, functional and non-functional requirements, constraints, and the scalability roadmap. **Fifteen describe a running system** and live in that flagship's own repository, rewritten as the code changes: architecture, sequence and component views, schema, API, file structure, infrastructure, threat model and controls, CI/CD, observability, monitoring, testing, deployment, and future improvements. **Two are split** — trade-offs decided before the build stay here while those discovered during it become ADRs in the repository; benchmark *predictions* stay here and are scored against the repository's *measured* results. **One belongs to neither**: lessons learned live in `flagships/<name>/as-built.md` and the flagship essay.
>
> A charter's requirements are never corrected to match what shipped. Divergence is the point: at level exit an **As built** document is written beside it — predicted against actual, what was cut, what held — and the original stands unedited. See [Chapter 40b · The Flagship Repository Standard](repo-standard.md) for the routing table, the charter-anchor mechanism, and the kickoff ritual.

Also delete the sentence *"Each is written to be the DESIGN_DOC.md that anchors its repo."* No `DESIGN_DOC.md` exists in this standard; a repository is anchored by its `README.md` and `docs/architecture.md`.

---

*Chapter 40b · Blueprint v1.2 · Build · Secure · Lead*
