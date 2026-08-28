# The Project Track

**Project-based, not stage-based. The stages still exist — they're now the syllabus each project pulls from, taught at the moment the project needs them.**

v3.0 · replaces the stage-sequential ordering · 52 weeks · 20 hrs/week

---

## The change

Before: nineteen stages in order, projects arriving when the stages allowed.
Now: five project phases, each one dragging its prerequisite stages in with it.

Nothing is dropped. Every one of the nineteen stages is still covered — but you'll meet a concept the week you need it to make something work, which is the flow you said Lesson 1 gave you and the stage-sequential plan was about to lose.

**The rule that keeps this honest:** we still stop and teach properly. When the project hits consensus, we don't hand-wave Raft — we spend three weeks on it, with the same explain-it-back gate. Project-based learning fails when "I need it to work" beats "I need to understand it." That doesn't happen here.

---

## The order, and why

| # | Project | Weeks | Layer it teaches | Stages folded in |
|---|---|---|---|---|
| 1 | **TESSERA v0** — the gateway | 1–10 | One machine, running things | S1 · S2 · S3 · S4 · S5 · S6 |
| 2 | **LATTICE** — distributed search | 11–26 | Data that survives, operating at scale | S7 · S8 · S9 · S10 · S11 · S12 · S13 |
| 3 | **PLINTH** — the platform | 27–34 | Platform engineering | control planes, operators, GitOps, IaC |
| 4 | **TESSERA v1** — AI infrastructure | 35–46 | AI infrastructure | S14 · S15 · S16 · S17 |
| 5 | **SYNAPSE-AI** core | 47–52 | Securing an AI platform | S18 · S19 |

### Why Tessera first

**Lowest floor.** Tessera v0 is a Go HTTP service, Postgres, Redis, Docker, and a small model on CPU. That's buildable from where you are. Lattice's floor is OpenSearch and Kafka on Kubernetes — you'd spend six weeks on prerequisites before writing a line of Lattice.

**It has to run continuously.** Operating is a duration, not a drill. Starting the gateway in week 3 gives you eleven months of uptime, real incidents, and an `INCIDENTS.md` with entries in it. Starting it in month 8 gives you four.

**You're applying now.** The AI-infrastructure claim is the largest unevidenced thing in your profile. Something running, with measured numbers, needs to exist early — not in month ten.

**It's the spine.** Everything else plugs into it. Lattice becomes its retrieval tier. Plinth deploys it. Synapse governs it. Building the spine first means every later project has somewhere to attach.

### Why Lattice second

It's the broadest employability project you have. SRE, platform, infrastructure, distributed systems, and data-infra roles all read Lattice as directly relevant. It's also where the hard theory lives — storage engines, replication, consensus, sharding — and that theory is what you cannot fake in an interview.

### Why Plinth third

Veyronix is off the table, and platform engineering is a role family you'd otherwise have no evidence for. Plinth is the minimal replacement: small enough to finish in eight weeks, real enough that its core loop is the same one Kubernetes runs on.

---

## The 52 weeks

```
w1   ─┐
      │  TESSERA v0        S1 Go and the machine underneath it
w10  ─┘  the gateway       S2 processes, signals, limits
                           S3 sockets, HTTP, TLS
                           S4 concurrency, backpressure, retries
                           S5 containers, Kubernetes basics
                           S6 tokens, models, multi-tenancy
         ▸ ships week 10 and never turns off again

w11  ─┐
      │  LATTICE           S7 storage engines, WAL, crash recovery
      │  distributed       S8 replication, clocks, partial failure
      │  search            S9 Raft
      │                    S10 sharding, quorums, consistency
w26  ─┘                    S11 stateful workloads on Kubernetes
                           S12 observability, SLOs, chaos
                           S13 security hardening
         ▸ ships week 26 with a real postmortem

w27  ─┐
      │  PLINTH            control loops and reconciliation
      │  the platform      the Kubernetes API from the inside
w34  ─┘                    operators, CRDs, golden paths, GitOps
         ▸ ships week 34, deploying your own systems

w35  ─┐
      │  TESSERA v1        S14 what's inside a model
      │  AI infrastructure S15 prefill, decode, KV cache, batching
      │                    S16 GPUs, parallelism, scheduling
w46  ─┘                    S17 the platform: tenancy, budgets, economics
         ▸ Lattice folds in as the retrieval tier

w47  ─┐  SYNAPSE-AI        S18 securing a workload the input controls
w52  ─┘  + the defence     S19 design under hostile questioning
```

---

## The week, now that you're applying

You're job-hunting while building, so the split changes for the first twelve weeks.

**Weeks 1–12 — application mode**

| Day | Hours | Block |
|---|---|---|
| Mon | 3 | Project session (teach + build) |
| Tue | 3 | Project session |
| Wed | 3 | **DSA** — patterns, in Go |
| Thu | 3 | Project session |
| Fri | 3 | Project session (break & measure) |
| Sat | 3 | **System design** — 1 written design, timed, then critique |
| Sun | 2 | Applications + outreach (1.5) · reflection (0.5) |

That's 12h project, 6h interview prep, 2h search.

**Weeks 13+ — build mode.** Interview prep drops to Saturday only (3h), project takes 14h, search stays at 2h and rises again when you have live processes.

**The rule I'll hold you to:** the interview track never gets merged into build time. Not once. Portfolio gets you interviews; DSA and system design get you offers. Every engineer who fails this year fails by letting the fun work eat the boring work.

---

## The interview track

### DSA — Wednesdays, in Go

NeetCode 150, in pattern order, not problem order. Arrays & hashing → two pointers → sliding window → stack → binary search → linked list → trees → heap → backtracking → graphs → intervals → greedy → 1-D DP. Skip advanced DP and advanced graphs until everything else is solid.

Pace: 4–5 problems per session, ~60 by week 12, all 150 by week 30.

**The method:** 25 minutes stuck, then read the solution, then **re-implement from scratch the next day**. Grinding without the second-day re-implementation is time you will not get back.

Log by pattern, not by problem — `interview-track/dsa/sliding-window.md` with the shape of the pattern, not 150 files of solutions.

### System design — Saturdays

One written design per week, 45 minutes, timed, then critique your own before I critique it.

Weeks 1–12, the classics: URL shortener · rate limiter · distributed cache · news feed · chat system · object store · message queue · search autocomplete · notification service · payment ledger · web crawler · metrics pipeline.

Weeks 13+, the ones your projects give you an unfair advantage on: multi-tenant API platform · distributed search · a deploy system · multi-tenant model serving · GPU scheduler · model registry with rollback.

**Your advantage:** most candidates recite a design they read. You'll have operated one. "What happens if a node dies" is a very different answer when you watched it happen at 2am and wrote the postmortem.

### Applications

Start now, at 5 per week, tailored. Rise to 10–15 once Lattice ships.

**Three résumé variants, no more.** One for backend/platform, one for SRE/infrastructure, one for AI/ML infrastructure. Applying to seven role families with one document is how good candidates get filtered by keyword matching.

---

## What you can apply for, and when

Honest ladder. Each row assumes the row above is done and documented.

| From | Roles genuinely open to you | The evidence |
|---|---|---|
| **Now** | Backend Engineer (Go, Node) · API Engineer | Shipped production backend work |
| **Week 10** — Tessera v0 | + Backend/Platform at API companies · junior DevOps | A running multi-tenant gateway with auth, budgets, metering, metrics, and measured overhead |
| **Week 26** — Lattice | + SRE · Infrastructure Engineer · Platform Engineer · Distributed Systems Engineer · Cloud Engineer · Data Infrastructure Engineer | A stateful distributed system on K8s you built, broke, and wrote a postmortem for |
| **Week 34** — Plinth | + Developer Platform / DevEx Engineer · Kubernetes Platform Engineer · Internal Tools | A control plane with a reconciliation loop and an operator |
| **Week 46** — Tessera v1 | + ML Infrastructure Engineer · Inference Engineer · AI Platform Engineer · **most** MLOps roles | GPU serving, measured TTFT and cost per token, multi-tenant economics |
| **Week 52** — Synapse | + the intersection roles almost nobody can fill | Security engineered into an AI platform, with a threat model |

### Four honest caveats

**1. MLOps is not fully covered, and you should know exactly what's missing.**
MLOps has two halves. Tessera covers *serving* — deployment, scaling, monitoring, cost. It does not cover *training operations* — data pipelines, feature stores, experiment tracking, model registries, retraining triggers, drift detection. If MLOps is a target rather than a nice-to-have, we add a 3-week module in week 47 building a retraining pipeline for a small model. Say the word and it goes in. Otherwise apply to *inference* and *AI platform* roles, where you'll be genuinely strong, rather than MLOps roles where you'll be half-qualified.

**2. "Easily" is the wrong word.**
Applying to sponsored infrastructure roles from Nigeria is hard regardless of portfolio. What this year buys you is *legibility* — a hiring manager can tell in ninety seconds that you're not the hundredth backend engineer in the pile. It does not buy you a shortcut past volume, timing, or luck. Expect 150+ applications for a handful of real processes.

**3. Breadth is a liability if you present it as breadth.**
Seven role families on one profile reads as unfocused. The projects give you range; the *presentation* has to be narrow. Lead with one identity, let the others be things a recruiter discovers.

**4. The order of what you learn is not the order of what you claim.**
By week 26 you'll be technically strong in areas you cannot yet claim confidently in an interview, because you'll have built them but not yet been questioned on them hard. That's what the Saturday design sessions and the final defence stage are for.

---

## What stays the same

- Every project session still runs the ten-step cycle, ending with explaining it back
- Failure days are still curriculum — each project has several
- Every benchmark names its hardware
- Every project ends with the four reflection questions
- Repo structure unchanged; `stages/` becomes `projects/p01-tessera-v0/` etc., same seven children
- One published piece per month

---

## Files

| Project | Charter |
|---|---|
| TESSERA (v0 and v1) | `PROJECT-TESSERA.md` |
| LATTICE | `PROJECT-LATTICE.md` |
| PLINTH | `PROJECT-PLINTH.md` |
| SYNAPSE-AI | `PROJECT-SYNAPSE.md` |
