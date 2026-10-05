# Phase 8: the capstone

Runway taught you the techniques. The capstone is where you use them on a question nobody has handed you an answer to. You'll pick a real problem, ask a precise question about it, build the system that lets you answer it, run the experiment, and report what you found, **including what didn't work**.

That's what makes a project stand out, in interviews and in research applications. Compare:

> "I built a distributed task queue using Kafka."

with:

> "Bursty workloads leave queues either slow or over-provisioned. I asked whether an adaptive scaling policy could cut p99 queue latency without raising cost, built a platform to test it, and found it helps for bursts over 30 seconds but not for sudden spikes, because scaling takes time to react."

The second is a **research project**. Every capstone here is built that way.

## The research loop

Every project follows the same structure. Your proposal, your report and your talk all use it:

| Part | The question it answers |
|---|---|
| **Problem** | What goes wrong in the real world? |
| **Who** | Who has this problem, concretely? |
| **Gap** | Why don't existing solutions solve it? |
| **Research question** | What exactly are you trying to find out? One sentence, answerable with evidence |
| **Hypothesis and baseline** | What do you expect, and what will you compare against? |
| **System** | What will you build to answer the question? |
| **Experiment** | What conditions will you test, and how will you control them? |
| **Measures** | Which numbers decide whether it worked? |
| **Results** | What did you find? (You fill this in; the briefs only suggest what you *might* find) |
| **Limitations** | Where does the answer stop being true? What's still unsolved? |

## The ten projects

| # | Project | Field | The question in one line |
|---|---|---|---|
| 1 | [KESTREL](01-kestrel.md) | Networking and systems · health | How should replicated records behave when health sites lose *part* of their connectivity? |
| 2 | [Gray-failure detection](02-gray-failure-detection.md) | Systems · AIOps | Can services that watch each other catch "half-broken" failures that health checks miss? |
| 3 | [Federated learning on unreliable networks](03-federated-learning-edge.md) | ML and AI · distributed systems | Which aggregation strategies stay accurate and robust when clients are flaky or malicious? |
| 4 | [Carbon-aware scheduling](04-carbon-aware-scheduling.md) | Cloud and infrastructure · energy | How much carbon can shifting jobs in time save before deadlines suffer? |
| 5 | [Cold-chain integrity](05-cold-chain-integrity.md) | Supply chain and pharmacy | Can an offline-first, tamper-evident log protect medicine temperature records across distributors? |
| 6 | [Drug-shortage early warning](06-drug-shortage-early-warning.md) | Pharmacy · data and ML | Can public supply signals predict medicine shortages weeks ahead? |
| 7 | [Post-quantum service mesh](07-post-quantum-mtls.md) | Quantum-safe cryptography · distributed systems | What does post-quantum TLS cost a microservice platform, and where does it hurt? |
| 8 | [Private outbreak detection](08-private-outbreak-detection.md) | Mathematics · medicine | How small an outbreak can clinics detect together when their counts are protected with differential privacy? |
| 9 | [Learned cache admission](09-learned-cache-admission.md) | Data systems · ML | Can a tiny learned policy beat classic caching on real traces, at a CPU cost worth paying? |
| 10 | [Edge video analytics](10-edge-video-analytics.md) | Networking · ML | How should edge cameras trade video quality against bandwidth to keep detection accurate on fluctuating links? |

## How to choose

1. **Pick a problem you care about.** You'll spend months on it. Domain interest carries you through the hard weeks.
2. **Check the skills map in each brief.** Every project leans on certain phases. Lean into your strengths, but choose one stretch area.
3. **Check feasibility.** Every brief uses public or synthetic data and runs on a laptop plus, at most, free-tier cloud. If you change the scope, keep that true.
4. **Or propose your own**, using [the proposal template](proposal-template.md). The test: can you state a research question that an experiment could answer, and a baseline to beat?

## How the capstone runs

| Stage | Weeks | Output |
|---|---|---|
| 1. Proposal | 1–2 | [proposal-template.md](proposal-template.md), filled in: problem to measures, plus a risk list. Get it reviewed by a peer or mentor |
| 2. Baseline | 2–3 | The simplest credible system and its measurements. **You need a number to beat before you build anything clever** |
| 3. Build | 3–4 | Your proposed system, with tests, reusing Runway's components where they fit |
| 4. Experiments | 2–3 | Every condition from the proposal, repeated, with confidence intervals, plus failure and adversarial cases |
| 5. Harden | 1 | Threat model, SBOM, signed images, vulnerability scans, fuzz tests on every parser |
| 6. Report and defence | 1–2 | A 6–10 page report (template inside the proposal file) and a 15-minute talk with a live failure demo |

## How it's judged

| Criterion | Weak | Strong |
|---|---|---|
| Question | Vague ("make it faster") | Precise, answerable, and it matters to someone named |
| Baseline | None, or a straw man | The simplest thing a competent engineer would actually deploy |
| Experiment | One run, on a happy path | Repeated runs, controlled variables, failure cases, confidence intervals |
| Evidence | Screenshots and adjectives | Raw data, scripts that regenerate every figure, settings recorded |
| Honesty | Only the good results | Negative results, threats to validity, and where the answer stops being true |
| Engineering | A demo that works once | Tests, CI, observability, a reproducible build from a clean checkout |
| Communication | Jargon and a wall of text | A reader outside the field understands the problem, the answer and the limits |

The capstone is the strongest single item in your portfolio, and the best writing sample you can attach to a research application.
