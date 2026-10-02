# The KESTREL journey

## Destination

Build the systems skills to design, evaluate, and operate distributed infrastructure that addresses a real public-interest need. KESTREL's current research direction is privacy-aware, local-first information sharing for community health organizations with limited infrastructure and intermittent connectivity.

The project aims to let participating organizations use approved cross-site summaries while retaining control over their source records. It is an experimental prototype, not a clinical product. It starts with synthetic or public data and needs domain partners, consent, and ethics review before any sensitive data or real care setting is involved.

## Why this path exists

KESTREL should teach systems engineering in service of a research question and people who could benefit from the result. It is not a collection of unrelated technology demos, and an AI model is not the reason to build it. AI may be studied as an optional extension only if a validated user need and careful evaluation justify it.

The working question is:

> How can small, resource-constrained health organizations produce timely and trustworthy cross-site summaries when records remain under local control and network connectivity is intermittent?

This creates a concrete systems trade-off among freshness, availability, latency, bandwidth, privacy, and operational complexity. It connects to Bernard Wong's work on distributed storage, decentralized systems, and networking, and Ivan Beschastnikh's work spanning distributed systems, formal methods, system analysis tools, privacy, and health collaborations. The research fit should guide the experiments; it does not imply endorsement or supervision.

## The path at a glance

```text
0. Make one request work
1. Make one service reliable
2. Connect sites and workers
3. Make local records durable and auditable
4. Replicate approved state through failure
5. Operate and measure the system under network constraints
6. Enforce safe cross-site queries
7. Evaluate utility, privacy, and usability with domain feedback
8. Defend the design and publish reproducible evidence
```

Each phase produces a working part of the same research system. The repository currently contains the Phase 0 service; later phases remain planned work.

## Phases

| Phase | Question | What we build or study | Proof before moving on |
|---|---|---|---|
| 0 — Start | Can I make and inspect a program that handles a request? | A tiny Go HTTP service with a health endpoint. | Run it, call it with `curl`, change it, and explain the request path. |
| 1 — Reliable service | How does one service handle requests without falling over? | An API that accepts and tracks work. | Show concurrent requests, invalid input, and graceful shutdown. |
| 2 — Sites communicate | What changes when work crosses process and network boundaries? | API, worker, and bounded queue; later, site-to-site messages. | Kill/restart a worker and explain retries, duplicates, and network behavior. |
| 3 — Durable local data | How do records and audit events survive a crash? | Database-backed state and a focused append-only storage experiment. | Recover consistent data after a controlled crash; explain the limits. |
| 4 — Distributed state | What fails when selected state spans multiple sites? | A small replicated metadata or key-value service. | Inject node failures and partitions; check consistency guarantees. |
| 5 — Constrained operation | Does the system remain useful on limited, unreliable links? | Containerized deployment and a repeatable network-emulation setup. | Measure availability, freshness, latency, bandwidth, and recovery under faults. |
| 6 — Safe shared queries | What can one site learn from another, and who can ask? | Authenticated, policy-checked queries over approved summaries. | Show authorized and denied behavior; analyze leakage and repeated-query risks. |
| 7 — Utility and usability | Do the outputs answer a real need without excessive cost or complexity? | Baseline comparison and a small domain-informed evaluation. | Publish methods, measurements, user feedback, and limitations. |
| 8 — Research capstone | Can another person trust and reproduce the claims? | Hardened prototype, threat model, failure study, and report. | Present guarantees, failure cases, privacy boundaries, and reproducible evidence. |

## Capability map

| Capability | Where it enters | Why KESTREL needs it |
|---|---|---|
| Systems foundations | Phases 0–3 | Linux processes, concurrency, networking, memory, filesystems, transactions, and crash recovery. |
| Distributed systems and networking | Phases 2–5 | Service communication, queues, replication, consistency, partitions, DNS/routing basics, and constrained-link behavior. |
| Storage and data systems | Phases 3–4 | Durable records, indexes, logs, recovery, and replicated metadata. |
| Security and privacy | Every phase; deeper in 6–8 | Site identity, least privilege, query authorization, auditability, threat modeling, and analysis of information leakage. |
| Platform and operations | Begin in Phase 0; deepen in 5 | Repeatable deployment, observability, capacity, network emulation, recovery procedures, and incident review. |
| Research practice | Begins with Phase 2 | Hypotheses, baselines, controlled failure, reproducible experiments, clear limitations, and responsible engagement with domain experts. |

## What “done” means

A phase is complete when you can run it from a clean checkout, explain its data flow, reproduce one relevant failure, point to evidence for its guarantee, and name a trade-off. The capstone also needs a research question, baseline, reproducible evaluation, privacy/threat analysis, and explicit limitations.

## Responsible scope

- Use synthetic or public data until appropriate partners, consent, security review, and ethics approval are in place.
- Do not use the prototype for diagnosis, treatment, or emergency care.
- Keep community stakeholders involved in choosing useful questions and interpreting results.
- Report negative results and privacy limitations; a distributed design does not automatically provide privacy.
- Build only the infrastructure needed to test a specific question. Add ML or AI only when a real need and measurable benefit justify it.

## First move

Continue with Phase 0 in [`projects/00-request-service`](../projects/00-request-service/README.md). The first objective is still small: understand a request path, validation, and tests. The purpose behind the learning is now clearer; later capabilities will be added when they help answer KESTREL's research question.
