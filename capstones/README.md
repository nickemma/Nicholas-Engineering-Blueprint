# The capstone

Runway taught you the techniques, through Phase 8. The capstone is where you use them on a question nobody has handed you an answer to. You'll pick a real problem, ask a precise question about it, build the system that lets you answer it, run the experiment, and report what you found, **including what didn't work**.

That's what makes a project stand out, in interviews and in research applications. Compare:

> "I built a distributed task queue using Kafka."

with:

> "Bursty workloads leave queues either slow or over-provisioned. I asked whether an adaptive scaling policy could cut p99 queue latency without raising cost, built a platform to test it, and found it helps for bursts over 30 seconds but not for sudden spikes, because scaling takes time to react."

The second is a **research project**. Every capstone here is built that way.

The ten projects are infrastructure, not demos. Four of them build the systems underneath AI products, not apps that call a model's API; the rest cover distributed systems, networking, security and big data. Each one is chosen to show what the strongest portfolio projects show: distributed systems, concurrency, resource management, performance, fault tolerance, and cost you can measure.

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
| 1 | [KESTREL](01-kestrel.md) | Distributed systems · networking · health | How should replicated records behave when health sites lose *part* of their connectivity? |
| 2 | [Federated learning on unreliable networks](02-federated-learning-edge.md) | ML · distributed systems · security | Which aggregation strategies stay accurate and robust when clients are flaky or malicious? |
| 3 | [Edge video analytics](03-edge-video-analytics.md) | Networking · ML | How should edge cameras trade video quality against bandwidth to keep detection accurate on fluctuating links? |
| 4 | [Cache-aware inference gateway](04-inference-gateway.md) | AI infrastructure · networking | Does routing LLM requests to workers that already hold their prompt's KV cache cut p99 time to first token, without hot spots? |
| 5 | [GPU scheduling on Kubernetes](05-gpu-scheduler.md) | AI infrastructure · cloud | Can memory- and fragmentation-aware placement with SLO-driven preemption raise GPU utilisation without starving anyone? |
| 6 | [A checkpoint store that doesn't stop training](06-checkpoint-store.md) | Distributed systems · storage · AI infrastructure | How much training stall can asynchronous, chunked checkpoints remove while "latest" is always complete? |
| 7 | [Network priority for distributed training](07-training-traffic-priority.md) | Networking · AI infrastructure | Does prioritising gradient traffic only when step time is at risk beat FIFO and always-on priority? |
| 8 | [Consistent authorization at scale](08-consistent-authorization.md) | Security · distributed systems | How do consistency choices in a Zanzibar-style permission service trade check latency against "new enemy" violations? |
| 9 | [Late data in stream processing](09-streaming-late-data.md) | Big data · distributed systems | Which watermark strategies trade result latency against completeness best on real, heavy-tailed lateness? |
| 10 | [Simulation testing for consensus](10-simulation-testing.md) | Distributed systems · testing | Which fault-exploration strategy finds real Raft bugs fastest, and does coverage predict it? |

Every brief has the same parts: the research loop above, plus a **suggested stack**, the **features to implement**, and how to **benchmark your work**.

## Go, Rust and Python: which for what

| Component | Language | Why |
|---|---|---|
| APIs and control planes | Go | Strong concurrency and straightforward service development; Runway's patterns carry over |
| Worker management, reconcilers, agents | Go | Network services and control loops |
| High-performance proxies and data paths | Go first; Rust if a measurement justifies it | Establish a baseline before optimising |
| Load generators | Go or Rust (Python while it keeps up) | Go is productive; Rust gives fine control. Either way, check that the tool isn't the bottleneck (Python Bridge) |
| Storage engines, performance-sensitive data processing | Rust, when measured | Memory safety and predictable resource use |
| Training, models, analysis | Python | The ecosystem is there (Phase 7) |

**Don't force both languages into every project.** A well-designed system with justified decisions impresses more than one with unnecessary language complexity. If you add Rust, the report should show the measurement that justified it.

## Benchmark your work

Numbers, bottlenecks and evaluations decide every capstone. Each brief lists its own measures; these rules apply to all of them.

- **Plan before you run.** Write the hypothesis, the baseline, the measures and the analysis first (Phase 7, step 1). Don't promise an improvement; let the benchmark decide.
- **Use the right load generator:**
  - [wrk2](https://github.com/giltene/wrk2) for HTTP request and response at a **constant rate**: it records latency in HdrHistogram and corrects for coordinated omission;
  - [ghz](https://ghz.sh/) for gRPC;
  - for streams, tokens or custom protocols, write your own open-loop generator (`kload` is the template).
- **Curves, not single numbers.** Raise the offered load step by step and plot throughput against p99 latency. Report the knee, and the goodput (work that met its objective) there.
- **Tails during failures.** Kill a node, partition the network, slow a disk. Report p99 in short windows before, during and after, and the time to recover.
- **Name the bottleneck.** Use the USE method (utilisation, saturation, errors) from Phase 5 on CPU, memory, disk, network and, where you have one, the GPU (`nvidia-smi`, NVIDIA's [DCGM exporter](https://github.com/NVIDIA/dcgm-exporter)). "It got slow" is not a finding; "the gateway's single Redis connection saturated at 8,000 requests a second" is.
- **Cost.** Where cost is part of the question, compute it per unit of work (per million tokens, per thousand jobs, per checkpointed gigabyte) from published prices, with the date you read them.
- **Rigour:**
  - warm-up discarded;
  - at least 5 repeats, interleaved across conditions;
  - an A/A run to know your noise;
  - bootstrap confidence intervals.
- **Record everything:** hardware, OS and kernel, versions, configuration, seeds. Commit the raw data and the scripts that regenerate every figure.

## No GPU? Every project still works

Every brief runs on a laptop. Three of the AI-infrastructure briefs (4, 5 and 7) touch GPUs; for those:

- **Simulate the GPU.** Mock workers that emulate prefill and decode timing (brief 4), simulated GPUs with memory and utilisation (brief 5), and CPU training whose traffic is real (brief 7). These answer the systems question, which is about queues, placement and networks, not about the GPU's arithmetic.
- **Use a small model on CPU:** llama.cpp's server or vLLM's CPU backend with a 0.5–1 billion-parameter quantised model.
- **Confirm on real hardware, optionally:** rent one GPU for a few hours to check a handful of points against your simulation. Set a budget before you start, and record what you spent. A short validation run is usually a few dollars to a few tens of dollars; check current prices.

## How to choose

1. **Pick a problem you care about.** You'll spend months on it. Domain interest carries you through the hard weeks.
2. **Check the skills map in each brief.** Every project leans on certain phases. Lean into your strengths, but choose one stretch area.
3. **Check feasibility.** Every brief uses public or synthetic data and runs on a laptop plus, at most, free-tier cloud or a few hours of a rented GPU on a budget you set. If you change the scope, keep that true.
4. **Or propose your own**, using [the proposal template](proposal-template.md). The test: can you state a research question that an experiment could answer, and a baseline to beat?

## How the capstone runs

| Stage | Weeks | Output |
|---|---|---|
| 1. Proposal | 1–2 | [proposal-template.md](proposal-template.md), filled in: problem to measures, plus a risk list. Get it reviewed by a peer or mentor |
| 2. Baseline | 2–3 | The simplest credible system and its measurements. **You need a number to beat before you build anything clever** |
| 3. Build | 3–4 | Your proposed system, with tests, CI and observability, reusing Runway's components where they fit |
| 4. Experiments | 2–3 | Every condition from the proposal, repeated, with confidence intervals; throughput-versus-latency curves; failure and adversarial cases; the bottleneck named |
| 5. Harden | 1 | Threat model, SBOM, signed images, vulnerability scans, fuzz tests on every parser |
| 6. Report and defence | 1–2 | A 6–10 page report (template inside the proposal file) and a 15-minute talk with a live failure demo |

## How it's judged

| Criterion | Weak | Strong |
|---|---|---|
| Question | Vague ("make it faster") | Precise, answerable, and it matters to someone named |
| Baseline | None, or a straw man | The simplest thing a competent engineer would actually deploy |
| Experiment | One run, on a happy path | Repeated runs, controlled variables, failure cases, confidence intervals |
| Performance | One number from one run | Throughput-versus-latency curves, p99 during failures, the bottleneck named with evidence, cost per unit of work where it matters |
| Evidence | Screenshots and adjectives | Raw data, scripts that regenerate every figure, settings recorded |
| Honesty | Only the good results | Negative results, threats to validity, and where the answer stops being true |
| Engineering | A demo that works once | Tests, CI, observability, a reproducible build from a clean checkout |
| Communication | Jargon and a wall of text | A reader outside the field understands the problem, the answer and the limits |

The capstone is the strongest single item in your portfolio, and the best writing sample you can attach to a research application.
