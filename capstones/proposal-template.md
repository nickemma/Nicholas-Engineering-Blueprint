# Capstone proposal: <title>

**Author:** · **Date:** · **Brief:** <link to the capstone brief, or "own proposal">

## 1. Problem

What goes wrong in the real world? Use one concrete scenario and, if you can, one number that shows the size of the problem.

## 2. Who has this problem

Name the people or organisations, and what it costs them today.

## 3. Gap

What do people use now? Why isn't it enough? Cite at least two existing systems or papers, and say precisely where each falls short **for this problem**.

## 4. Research question

One sentence that an experiment can answer. Not "Can I build X?", but "Under conditions C, does approach A improve measure M compared with baseline B, and at what cost?"

## 5. Hypothesis and baseline

- **Hypothesis:** what you expect, and why.
- **Baseline:** the simplest credible alternative a competent engineer would deploy. You'll measure it first.

## 6. System

The architecture as a diagram. Which parts you'll reuse from Runway, and which are new. What's deliberately left out.

## 7. Stack

| Part | Language or tool | Why this, and not the alternative |
|---|---|---|
| | | |

Use Go for APIs and control planes, Python for models and analysis, and Rust only where a measurement will justify it. If you plan Rust, say which measurement would show it was needed.

## 8. Features

The numbered features the system needs to answer the question. Mark which ones the experiment depends on, and which you'll cut first if time runs short.

## 9. Experiment

| Variable | Values | Why |
|---|---|---|
| Independent variables (what you change) | | |
| Controlled variables (what you hold fixed) | | |
| Workloads and data | | |
| Failure and adversarial conditions | | |
| Repetitions | at least 5 per condition | |

## 10. Measures

| Measure | Definition | Better is |
|---|---|---|
| | | |

State which measure decides the research question, before you see any results.

## 11. Benchmark plan

- **Load generator:** which one (wrk2, ghz, your own), open- or closed-loop, and how you'll check it isn't the bottleneck.
- **Load levels:** the offered loads for the throughput-versus-latency curve.
- **Failures:** what you'll inject, when, and the windows you'll report p99 in.
- **Resources:** what you'll record to name the bottleneck (CPU, memory, disk, network, GPU).
- **Cost:** the prices you'll use, and the unit (per million tokens, per thousand jobs, ...), if cost is part of the question.
- **Rigour:** warm-up, repeats, interleaving, the A/A run, and the intervals you'll report.

## 12. Risks and mitigations

| Risk | Likelihood | Mitigation or fallback |
|---|---|---|
| The data isn't available or is too small | | |
| The baseline is already good enough | | A negative result, reported honestly, is a valid result |
| The scope is too big | | What you'll cut first |

## 13. Ethics and data

Which data you'll use (public, or synthetic and how it's generated), any personal information, and why it's safe. Any real-world deployment needs the right partners and approval. Capstones use public or synthetic data.

## 14. Plan

| Week | Milestone | Evidence |
|---|---|---|
| | | |

---

# Report template (for stage 6)

1. **Abstract**: the problem, the question, the method, the main result and the main limitation, in 150 words.
2. **Introduction**: the problem, who has it, the gap, and your question and contributions.
3. **Background and related work**: what exists, and where it falls short.
4. **Design**: the system, and why it's built that way.
5. **Implementation**: what you built, how it's tested, and what you reused.
6. **Evaluation**: the setup, the baseline, the results with confidence intervals, and failure cases.
7. **Discussion**: what the results mean, threats to validity, and negative results.
8. **Limitations and future work.**
9. **Reproducibility**: one command to rebuild, and one to regenerate every figure.
10. **References.**
