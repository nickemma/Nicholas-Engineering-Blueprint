# KESTREL — Community Health Data, Shared Safely

## Purpose

KESTREL is a research-led systems project about a human problem: small community health organizations may need to coordinate around shared information, while records are sensitive, infrastructure is limited, and internet connections can be unreliable. A centralized service can be unavailable during an outage or require organizations to give up control of their data. KESTREL will explore whether a local-first, distributed design can make selected cross-site information useful without making the underlying records broadly accessible.

This is a working research direction, not a claim that a health product or clinical system already exists. We will validate the problem with people who understand the domain before treating it as fixed. Early experiments use synthetic or public data. Sensitive data, clinical use, or deployment with a care provider would require appropriate partners, consent, security review, and research ethics approval.

## Research question

> How can small, resource-constrained health organizations produce timely and trustworthy cross-site summaries when records remain under local control and network connectivity is intermittent?

The systems question is how to balance data freshness, availability, query latency, bandwidth use, privacy, and operator effort. The project will make those trade-offs measurable instead of claiming that one design is best in every condition.

## How KESTREL differs from the rest of the portfolio

Your public GitHub profile already presents work in distributed storage (MERIDIAN), developer platforms (VEYRONIX), search (LATTICE), model serving (TESSERA), and AI governance (SYNAPSE-AI). KESTREL should not rebuild those systems under another name. It should contribute a different thing: a user-validated, public-interest workload and a careful evaluation of how data-sharing choices affect people when organizations have limited connectivity and strict control over sensitive information. Existing projects or established components can serve as infrastructure or baselines where their behavior fits.

The research should compare credible alternatives, including a centralized baseline. Local-first replication is a hypothesis to test, not a promised improvement: it may improve access during outages while increasing stale-data, conflict, privacy, or operational risks.

This direction draws on distributed storage and networking, decentralized services, and geo-distributed performance work, as well as formal methods, systems developer tools, privacy, and secure distributed analysis. Those connections are visible in the research of [Bernard Wong](https://cs.uwaterloo.ca/~bernard/) and [Ivan Beschastnikh](https://www.cs.ubc.ca/~bestchai/), including work on distributed storage, network performance, formal methods, system analysis tools, and health/privacy collaborations.

## Intended users and benefit

- **Community health workers and local organizations** need useful shared summaries without sending every underlying record to one central service.
- **Data stewards** need clear control over which questions can be asked, by whom, and what leaves each site.
- **Operators** need a system that can recover from outages and explain what happened while disconnected.
- **Researchers and reviewers** need reproducible evidence about the guarantees, failure modes, privacy limits, and actual utility.

The intended benefit is better coordination and planning from information that organizations are willing and authorized to share. The system will not make diagnoses or replace clinical judgment.

## What we will build

Start with a small Go service, then grow it only when the next research question needs a new capability:

1. A reliable API and asynchronous work path.
2. A durable, auditable local data store.
3. Multiple site nodes that exchange approved summaries while links are available.
4. Explicit behavior for stale, conflicting, duplicated, or unavailable data.
5. Access policies and privacy controls that limit what each role and site can learn.
6. A reproducible evaluation under latency, bandwidth limits, node failure, and network partitions.
7. A usability and threat review with domain feedback before any claim of practical benefit.

The core project is distributed data infrastructure; AI is not a required component. A privacy-preserving analytics or ML extension is in scope only if a validated user need requires it and if we can compare its benefit and privacy cost against simpler summaries.

## Evidence and success criteria

KESTREL succeeds as a learning and research project if another person can reproduce its experiments and judge its claims. We will report:

- which data and queries are synthetic, public, or approved for use;
- freshness and availability during disconnection and recovery;
- latency and bandwidth across realistic network conditions;
- what information each role can access and what can leak through aggregate answers;
- how operators detect, recover from, and audit failures;
- what representative users find useful, confusing, or unsafe;
- limitations, negative results, and unresolved research questions.

An operational demo alone is not a research result. Each major feature should answer a question, state a hypothesis, compare against a baseline, and preserve enough evidence to reproduce the result.

## Security and privacy contract

Security and privacy are design constraints from the start. The implementation should:

- deny access unless a site and user have explicit permission;
- keep source records under the authority of the site that collected them;
- expose only the minimum approved answer to a cross-site query;
- authenticate communicating sites and protect data in transit;
- record who asked what, which policy applied, what was released, and when;
- fail closed for protected operations when identity or policy cannot be checked;
- test allowed use, denied use, and attempts to bypass the enforcement path.

These controls reduce risk; they do not prove that aggregates are harmless or that a deployment complies with health privacy law. Privacy leakage, inference from repeated queries, compromised endpoints, and operational mistakes remain part of the threat model. We will state those limits plainly.

## Learning path

| Phase | KESTREL capability | Main systems ideas | Evidence |
|---|---|---|---|
| 0 | A small request service | Go, HTTP, Linux process basics, tests | Run and trace a request; explain status codes and validation. |
| 1 | A reliable local service | Concurrency, timeouts, graceful shutdown, metrics | Show behavior under concurrent load and shutdown. |
| 2 | Separate sites and workers communicate | TCP, service boundaries, queues, retries, idempotency | Restart a worker and observe communication under failure. |
| Rust Bridge | Byte-oriented storage exercises | Rust ownership, serialization, checksums | Read and validate a record format. |
| 3 | Records and audit data survive crashes | SQL, transactions, append-only logs, recovery | Crash/recovery and backup/restore experiment. |
| 4 | Sites replicate selected state | Raft, consistency, partitions, clocks, failure models | Fault experiments, consistency checks, and a protocol model. |
| 5 | The system runs on constrained infrastructure | Containers, deployment, observability, capacity, incident response, network emulation | Repeatable deployment and a measured outage game day. |
| 6 | Sites answer narrowly authorized shared queries | Identity, policy, privacy threat models, query controls | Allowed/denied query evidence and privacy analysis. |
| 7 | Evaluate the design with domain feedback | Baselines, workload design, usability, privacy/utility trade-offs | Reproducible measurements and documented stakeholder feedback. |
| 8 | Defend the complete system | Threat model, TLS/mTLS, least privilege, supply chain, resilience | Design review, security exercise, limitations, and research report. |

The detailed lesson materials will be updated phase by phase. Until then, the existing Phase 0 request-service exercise remains the starting point.

## Working cycle

For each phase, choose one real question, inspect the current system, learn only the concepts needed, build one small change, measure expected behavior, induce one failure, diagnose it, and write down the result. Advance when the evidence and explanation are clear, not because a calendar says so.
