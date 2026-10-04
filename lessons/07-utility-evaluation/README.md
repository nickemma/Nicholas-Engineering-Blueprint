# Phase 7: evaluate utility, privacy, and usability

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: full code in `steps/`, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This page previews the concepts, tools, readings, and exit evidence. The base lesson uses a synthetic workload and a documented evaluation rubric; partner feedback is included when access and ethics review allow it. The optional AI sampler is a separate public-data exercise. Follow the full [self-study teaching guide](TEACHING.md) and record your work in [learned.md](learned.md).

The required evaluation and optional AI readings are embedded at the end of [TEACHING.md](TEACHING.md). Select the systems paper only after the baseline and measures are set; the guide specifies how to record that choice.

## Question and build

Do cross-site summaries help the intended users enough to justify their freshness, availability, privacy, bandwidth, and operator costs?

Build a reproducible synthetic experiment. The Phase 6 practice harness supports policy/API/network-path measurements only; compare centralized storage with local-first Kestrel only after the Kestrel transfer has separate site stores and a cross-site summary path. Otherwise mark that architecture comparison as not measured. Get bounded domain feedback only when access and ethics requirements are met.

## Teach in this order

1. **Turn need into a question.** Record the user, decision, data permitted, query, and desired freshness. Separate validated need from engineering preference.
2. **State a hypothesis and baseline.** Define what should improve and what the centralized design already does well. Keep workload and resources comparable.
3. **Choose measures.** Define freshness, availability, latency, bandwidth, privacy exposure, and operator effort before running tests.
4. **Build the workload.** Version data, query mix, network settings, and seeds. Explain how each changes the result.
5. **Run controlled conditions.** Measure the local API path under normal, constrained, partitioned, and recovered links. Test node loss only when your integrated Kestrel experiment includes replicated nodes; keep raw results and repeat runs.
6. **Review utility and usability.** With appropriate domain feedback, identify useful, confusing, or unsafe outputs. Human-subject work requires appropriate ethics process and consent.
7. **Analyze honestly.** Use Go benchmarks or a small Python notebook where helpful. Report uncertainty, negative results, and cases where the centralized baseline wins.

## Foundations closed

Hypothesis formation, baseline design, workload construction, performance analysis, reproducible experiments, privacy/utility trade-offs, stakeholder feedback, and research ethics boundaries.

## Reading placement

After stating the hypothesis and metrics, read evaluation sections of systems papers close to the workload. Use SRE for availability/operations measures and Kurose & Ross for network measures. Choose domain and ethics sources with qualified collaborators before involving people.

## Exit evidence and career signal

A second person can rerun the measurements you actually performed and regenerate tables/plots. Report methods, feedback, limits, and negative results. Preserve enough information to reproduce the workload and network settings; do not present the Phase 6 single-database harness as a local-first architecture comparison.

This produces applied research and performance-evaluation evidence. Small feedback exercises do not automatically generalize to every community health organization.
