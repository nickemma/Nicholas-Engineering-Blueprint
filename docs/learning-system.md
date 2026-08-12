# The Learning System

*How the apprenticeship actually runs: the cycle, the week, the standards, the writing.*

*Destination: [Engineering Vision](docs/learning-system.md)*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../README.md)*

---

## 9 · The architecture of the year

Nineteen stages in six layers. A layer is a rung of capability; a stage is a question.

| Layer | Stages | Weeks | What becomes true |
|---|---|---|---|
| I — One machine | S1–S4 | 1–13 | You know what your abstractions cost, and can serve many users from one box reliably |
| II — Running things | S5–S6 | 14–17 | You can package software, place it, and serve a model behind a gateway you built |
| III — Data that survives | S7–S10 | 18–31 | You build systems that survive crashes, partitions, and disagreement |
| IV — Operating at scale | S11–S13 | 32–40 | You run a stateful distributed system, know when it's sick, and can defend it |
| V — AI infrastructure | S14–S18 | 41–52 | You serve models as a multi-tenant platform, with an economy and a threat model |
| VI — Proving it | S19 | 52+ | You design one from scratch and defend it under hostile questioning |

**Why the weighting.** Time goes where the gap is, not evenly. Layer III gets 14 weeks because consensus and storage are the densest interview surface and the hardest to fake. Layer I gets 13 because starting from zero means the single-machine model has to be genuinely solid — everything distributed is built on it. Layer V gets 12 because it's the newest material and the differentiator.

**Nothing is throwaway.** Each stage's output is the next stage's input:

```text
S1–S4  concurrency, sockets, RPC
          └─> S6's gateway is built out of them
S6     the gateway, running
          └─> S17's platform is this, grown up
S7     storage engine (WAL, LSM, recovery)
          └─> S9's Raft replicates a log you already understand
S9     Raft
          └─> S11 operates a system that runs one (OpenSearch), and you know why it behaves that way
S11    LATTICE
          └─> S17 folds it in as TESSERA's retrieval tier
```

---

## 10 · The teaching cycle

Every topic, without skipping steps:

```text
1. Explain it simply       → plain English, zero jargon
2. Mental model            → an analogy you can hold
3. Real terminology        → now the word has something to attach to
4. Tiny Go example         → 10–30 lines, runnable
5. You implement it
6. I review it
7. We break it deliberately
8. You fix it
9. Complexity increases
10. You explain it back    ← the gate
```

Step 10 is not a formality. If you can't explain it, the lesson isn't finished, and we don't proceed.

### Five lesson types

| Type | What happens |
|---|---|
| 🧠 CONCEPT | I teach, you ask, I check |
| 🔬 EXPERIMENT | We prove something on your machine, with numbers |
| 💻 BUILD | You implement |
| 💥 BREAK | I inject a failure, you diagnose |
| 🧪 ASSESSMENT | I test whether it stuck |

### The advancement rule

**We advance on demonstrated understanding, not elapsed time.** If a lesson doesn't land, it's re-taught with a different analogy, a diagram, an experiment, harder examples — until it clicks. Saying "I don't get it" is the mechanism working, not a setback.

### Progressively removing the magic

You never learn a layer before you've felt the pain it solves.

```text
HTTP server → TCP server → RPC → many RPC servers → + replication
→ + crashes → + disagreement → + thousands of them
```

---

## 11 · The week

20 hours. Four 3-hour lessons, two build blocks, one interview block, one reflection.

| Day | Hours | Block | Deliverable by day's end |
|---|---|---|---|
| Mon | 3 | Lesson | Lesson file drafted, lab committed |
| Tue | 3 | Lesson | Lesson file drafted, lab committed |
| Wed | 2 | Independent build / fix what broke | A commit |
| Thu | 3 | Lesson | Lesson file drafted, lab committed |
| Fri | 3 | Lesson (usually BREAK or EXPERIMENT) | A `breaks/` or `experiments/` entry with numbers |
| Sat | 3 | DSA (1.5) + system design (1.5) | Problems logged; one written design |
| Sun | 3 | Build (2) + reflection (1) | `weekly-reviews/week-NN.md` committed |

**Flex rules.** If a week collapses: drop Wednesday's build first, then Sunday's build. Never drop the reflection — the redesign answer is where learning consolidates. Never drop Saturday — the interview track compounds and cannot be crammed.

### The weekly review

```text
# Week NN — Stage S, Lessons X–Y
Shipped:        # what runs now that didn't on Monday
Concept:        # the one idea I can now teach
Broke:          # what failed and the root cause
Measured:       # a number, with the hardware
Paper:          # title + the one insight
Career:         # applications, connections, OSS
Blocked / cut:  # what slipped and the conscious reason
Next week:      # the single most important thing
```

---

## 12 · Engineering standards

The definition of done. It scales with stakes — a lab ships a subset, a stage project ships more, a flagship ships all of it.

| # | Artifact | Lab | Stage project | Flagship |
|---|---|---|---|---|
| 1 | README that works from a clean clone | ✓ | ✓ | ✓ |
| 2 | Tests, failing before the fix | | ✓ | ✓ |
| 3 | Structured logs + `/metrics` + health check | | ✓ | ✓ |
| 4 | Benchmark with hardware named | | ✓ | ✓ |
| 5 | Architecture diagram | | ✓ | ✓ |
| 6 | Design doc — problem, approach, alternatives, tradeoffs | | ✓ | ✓ |
| 7 | Failure-mode analysis | | ✓ | ✓ |
| 8 | Survived its failure day | | ✓ | ✓ |
| 9 | Threat model | | | ✓ |
| 10 | Load test — ceiling, degradation curve, breaking point | | | ✓ |
| 11 | Runbook | | | ✓ |
| 12 | ADRs for significant decisions | | | ✓ |
| 13 | Deployed with IaC, not by hand | | | ✓ |
| 14 | Incident log, once it's running continuously | | | ✓ |
| 15 | ≤90-second demo — ideally a failure survived | | | ✓ |
| 16 | Reflection: what broke, what I'd redesign | ✓ | ✓ | ✓ |

**The README order** (the artifact hiring managers actually read): one-line identity → what it is and why it exists → architecture diagram above the fold → what each layer proves → stack table with a *why* column → quick start → tradeoffs → links to every doc.

**Design docs before code** for anything larger than a lab. One page minimum, committed before the first commit of implementation.

---

## 13 · Writing

Writing is half the strategy. A system nobody knows about builds no reputation.

**One published piece per month.** A finding, not a tutorial. The distinction matters: *"How to learn Go"* is noise; *"I killed a data node mid-merge and watched p99 for an hour"* is signal.

Per stage, four artifacts:

| Artifact | What it is |
|---|---|
| Lesson write-ups | Every lesson, in the repo — the raw material |
| One published piece | The stage's signature finding, 1,200–2,500 words |
| A reflection | The four questions, answered publicly |
| Distribution | 3–5 short posts pulled from the above — a number, a diagram, a failure |

**Cadence:** Sunday drafts, mid-week ships. Never publish a first draft.

**Reading log:** one paper a week, one page of notes, `reading-log/`. Roughly 49 by the end. It's the retention system and the networking opener in one file.

---

## 14 · Reading

Six source types, all read *with* the build, never ahead of it.

| Source | Role |
|---|---|
| Books | The spine — a chapter the week its topic is live |
| Papers | The canon — one a week, logged |
| Engineering blogs | How Cloudflare, Stripe, Cockroach actually built it |
| Talks | The 40-minute version of a hard idea, often from its inventor |
| RFCs & specs | Ground truth — what the standard actually says |
| Repositories | The apprenticeship — etcd, Kubernetes, vLLM source |

Per layer:

| Layer | Track |
|---|---|
| I | CS:APP · The Linux Programming Interface · Beej's Guide · Kurose & Ross |
| II | Kubernetes Up & Running · Liz Rice on containers |
| III | Designing Data-Intensive Applications · Database Internals · the Raft paper · the distributed canon |
| IV | Google SRE · Systems Performance · Anderson's Security Engineering · Shostack |
| V | Karpathy Zero-to-Hero · PMPP · the vLLM/PagedAttention paper · the inference literature |
| VI | Staff Engineer · A Philosophy of Software Design |

**The one discipline that matters most:** if a week collapses, the reading slides and the shipping survives. Bulk-reading ahead feels like progress and retains almost nothing.

---

## 15 · Case studies

Every implementation chains to a real system, so theory → implementation → production is always connected:

```text
Your storage engine → LSM/WAL          → RocksDB, PostgreSQL
Your Raft           → consensus        → etcd → the Kubernetes control plane
Your RPC            → gRPC             → Envoy
Your supervisor     → cgroups, ns      → Docker, containerd
Your gateway        → batching, KV cache → vLLM
```

---

## 16 · Failure days

Curriculum, not garnish. Every stage project gets one.

process crashes · network failures · packet loss · latency spikes · timeouts · disk failures · memory exhaustion · duplicate requests · stale data · concurrent writes · partial failures · expired certificates

> A distributed system isn't defined by what happens when everything works. It's defined by what happens when things don't.

Every failure day produces a `breaks/` file and a row in the failure log. That log is your interview material — the rule is that a root cause must be a *decision*, not an event. "Disk filled" is an event. "No log rotation and no disk alert" is a cause.

---

## 17 · The parallel tracks

Four things run across all 49 weeks, independent of stage:

- **Saturdays** — DSA in Go (NeetCode 150 order) and system design. Never merged into build time.
- **The gateway stays up** — from S6 to the end. Operating is a duration, not a drill.
- **Open source** — one organization, one subsystem, from month 9. Docs → tests → small bugs → a feature → a design discussion.
- **The career clock** — surfaces aligned by month 2; first PR month 4; applications from month 9 at 5–8/week, rising to 10–15.

---

## 18 · Repo discipline

The repository is the first flagship a recruiter sees. Structure is in [`REPO-STRUCTURE.md`](docs/repo-standard.md); these are the habits:

- **Commit the weekly review every Sunday.** Forty-nine consecutive Sunday commits shows consistency instead of claiming it.
- **Publish the failures.** The `breaks/` folders are the most valuable thing in the repo, for followers and hiring managers both.
- **Thinking in, flagship code out.** Design artifacts here, code in its own repo, linked both ways.
- **Version the handbook itself.** Tag releases, keep the changelog. Treating your own growth as a maintained system is itself the demonstration.
- **Create stage folders when the stage starts.** Nineteen folders of stubs is noise and it lies about progress.
