# Research track (personal)

My own MSc preparation. The learner-facing path is [JOURNEY.md](../JOURNEY.md); my capstone is [KESTREL](../capstones/01-kestrel.md).

## Destination

A thesis MSc in computer science, specialising in **systems and networking**, at the University of Waterloo (MMath, thesis) or UBC (MSc, thesis), followed by distributed-systems and infrastructure work that is ready for research.

## Supervisors I'd like to work with

Verify current interests, funding and intake before writing to anyone. Read two of their recent papers first, and connect them to something I built.

| Supervisor | Where | Why KESTREL connects |
|---|---|---|
| Samer Al-Kiswany | Waterloo | His group's studies of **partial network partitions** in cloud systems (OSDI 2018, OSDI 2020) are the closest prior work to KESTREL's sharpened question |
| Bernard Wong | Waterloo | Distributed systems and networking, including geo-distributed and network-aware systems. **Note:** his early, well-known *Meridian* (a network location service, SIGCOMM 2005) shares a name with my MERIDIAN project. Acknowledge that if I write to him |
| Khuzaima Daudjee | Waterloo | Distributed data management and replication: the consistency side of KESTREL |
| Ivan Beschastnikh | UBC | Distributed systems, analysis and testing tools, formal methods, and health/privacy collaborations: KESTREL's checking tools and its health motivation |

## KESTREL, sharpened

Earlier versions centred on privacy and local-first data sharing. The research question is now squarely systems and networking:

> Under partial and intermittent network partitions typical of under-resourced sites, how do consensus-based, CRDT-based and hybrid replication strategies compare in summary freshness, write availability, bandwidth and correctness? Can a partition-aware hybrid outperform both?

It builds on MERIDIAN (per-request consistency) rather than repeating it. The health setting remains the motivation and the workload. See the [full brief](../capstones/01-kestrel.md).

## How KESTREL differs from my other projects

My portfolio already covers distributed storage (MERIDIAN), developer platforms (VEYRONIX), search (LATTICE), model serving (TESSERA) and AI governance (SYNAPSE-AI). KESTREL contributes something different: a measured study of replication under *realistic, imperfect* connectivity, with a public-interest workload. Existing projects can serve as components or baselines.

## What committees and supervisors look for

- Evidence of research ability: reading papers critically, forming a question, running an honest experiment, writing it up.
- Fit with a supervisor's work.
- Solid fundamentals.

## Research habits

1. **Read papers with Keshav's three-pass method.** One-page note per paper: the problem, key idea, assumptions and failure model, evaluation, one weakness, one open question.
2. **Reproduce one result**, such as a partial-partition failure from the OSDI 2018 study, on my own Raft from Phase 4.
3. **Write the KESTREL capstone report** (6–10 pages, LaTeX), as my writing sample.
4. **Model the hybrid's safety property in TLA+.**
5. Use LaTeX and Zotero.

## Timeline

If the MSc starts in fall 2027, I want Phase 4, a technical report on partial partitions in my Raft, and the KESTREL proposal done before applications close.

## Maths readiness

Keep discrete maths, probability and proof-writing sharp alongside the BSc. Lynch's distributed-algorithms material and the FLP paper are good proof-reading practice. TLA+ builds formal reasoning.

## Optional certifications (after Phase 5)

AWS Solutions Architect Associate, CKA, Terraform Associate.
