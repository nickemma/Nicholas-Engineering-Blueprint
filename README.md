# The Nicholas Emmanuel Engineering Blueprint

**Nicholas Emmanuel builds secure, reliable distributed systems and AI infrastructure at scale.**

A 49-week apprenticeship in distributed systems and AI infrastructure — taught from zero, built in public, and documented including the parts that broke.

Nineteen stages. Roughly 196 lessons. Every stage answers one question and ends with something running that didn't run before.

**The goal is not completed courses.** By the end: design, implement, secure, operate, and explain a production-grade distributed AI infrastructure system.

> *Software engineering is not the act of writing code. It is the discipline of designing systems that continue to function correctly under changing requirements, increasing scale, operational failures, evolving security threats, and human collaboration.* — [The credo](docs/vision.md)

**New here?** → [START-HERE.md](START-HERE.md)

---

## Where I am

See [PROGRESS.md](PROGRESS.md) for the live position.

| Layer | Stages | Question | Status |
|---|---|---|---|
| I — One machine | [S1](stages/s01-how-a-computer-runs-your-code)–S4 | How does a computer run your code, and serve many users? | ◐ in progress |
| II — Running things | S5–S6 | How do you package software, and what does serving a model require? | ○ |
| III — Data that survives | S7–S10 | How does data survive crashes, replication, and disagreement? | ○ |
| IV — Operating at scale | S11–S13 | How do you run it, watch it, and defend it? | ○ |
| V — AI infrastructure | S14–S18 | How do you serve models as a platform? | ○ |
| VI — Proving it | S19 | Can you design one from scratch and defend it? | ○ |

Full map: [docs/curriculum-tree.md](docs/curriculum-tree.md)

---

## Navigation

| | |
|---|---|
| [START-HERE.md](START-HERE.md) | For anyone following along |
| [PROGRESS.md](PROGRESS.md) | Current position, stage bars, failures survived |
| [docs/curriculum-tree.md](docs/curriculum-tree.md) | All 19 stages, what each teaches, where the flagships land |
| [docs/how-this-works.md](docs/how-this-works.md) | The teaching contract — the cycle, the lesson types, the advancement rule |
| [docs/vision.md](docs/vision.md) | Identity, why this path, outcomes, metrics |
| [docs/learning-system.md](docs/learning-system.md) | The learning system, weekly cadence, engineering standards |
| [stages/](stages) | One folder per stage — lessons, labs, experiments, failures, reflections |
| [flagships/](flagships) | Design artifacts for the systems (code lives in its own repos) |
| [templates/](templates) · [weekly-reviews/](weekly-reviews) | The working directories |

---

## The systems

| System | What it is | Code |
|---|---|---|
| **TESSERA** | LLM inference platform — multi-tenant gateway, token budgets, measured cost per token. Goes live in S6 and stays running to the end. | [nickemma/tessera](https://github.com/nickemma/tessera) |
| **LATTICE** | Distributed search and retrieval — OpenSearch on Kubernetes, hybrid keyword + vector. Becomes Tessera's retrieval tier in S17. | [nickemma/lattice](https://github.com/nickemma/lattice) |
| **SYNAPSE-AI** | AI agent governance plane — identity, delegation, consent, and audit. Treats AI agents as users with the same governance controls as humans. S19 | [nickemma/synapse-ai](https://github.com/nickemma/synapse-ai) |
| **MERIDIAN** · | Shipped previously. | [meridian](https://github.com/nickemma/meridian) · |

---

## Scoreboard

Reviewed at every stage exit.

| Metric | Now | Target |
|---|---|---|
| Stages completed | 0 | 19 |
| Lessons written up | 0 | ~196 |
| Failures survived and documented | 0 | 40+ |
| Stage projects running | 0 | 8 |
| Published pieces | 0 | 12 |
| Weekly reviews committed | 0 | 49 |
| Days the inference gateway has been up | — | 240+ |

The last row is the one that matters most. Operating is a duration, not a drill.

---

## Following along

Every lesson contains the plain-English explanation, the exact commands, the code, and what broke. Fork it and build alongside — the `breaks/` folder in each stage is where the real learning is.

[Website](https://techieemma.vercel.app) · [GitHub](https://github.com/nickemma) · [LinkedIn](https://linkedin.com/in/techieemma) · [Medium](https://techieemma.medium.com) · [X](https://twitter.com/techieemma)

---

*v2.0 · August 2026 · Living source of truth. See [CHANGELOG.md](CHANGELOG.md).*

*Build · Secure · Lead*
