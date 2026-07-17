# Part VII — Resource Library & Appendices

*The full library across six source types, plus templates and checklists.*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../README.md) — v1.1*

---

# Chapter 48 · The Library — Books

**Why this chapter matters:** the full reading list, organized by track and tier, so the six-source framework of Chapter 17 has its complete bibliography. Required = read as scheduled; Recommended = as the week allows; Advanced = after Week 40 or when a project demands it.

| Track | Books | Tier |
|---|---|---|
| Foundations | CS:APP (Bryant & O’Hallaron) | Required |
| Foundations | The Linux Programming Interface (Kerrisk); Beej’s Guide (free); TCP/IP Illustrated Vol. 1 | Rec / Req / Rec |
| Networking | Computer Networking: A Top-Down Approach (Kurose & Ross) | Required |
| Distributed systems | Designing Data-Intensive Applications (Kleppmann) — the bible | Required |
| Distributed systems | Database Internals (Petrov); Distributed Systems (van Steen & Tanenbaum, free) | Rec / Rec |
| Platform engineering | Production Kubernetes (Rosso); Programming Kubernetes (Hausenblas) | Required |
| Platform engineering | Kubernetes Up & Running (Burns); Google SRE + SRE Workbook (free); Terraform Up & Running | Rec |
| AI infrastructure | Designing ML Systems (Huyen); AI Engineering (Huyen) | Required |
| AI infrastructure | Programming Massively Parallel Processors (Kirk & Hwu); d2l.ai (free) | Rec |
| Security & crypto | Security Engineering 3e (Anderson, free); Threat Modeling (Shostack) | Required |
| Security & crypto | Serious Cryptography 2e (Aumasson); Intro to Modern Cryptography (Katz & Lindell) | Rec / Adv |
| Leadership & craft | Staff Engineer (Larson); A Philosophy of Software Design (Ousterhout); The Software Engineer’s Guidebook (Orosz) | Advanced |
| Architecture (secondary) | Building Microservices (Newman); Fundamentals of Software Architecture (Richards & Ford) | Advanced |

Note on the secondary architecture shelf: Newman and Richards/Ford teach enterprise-architecture framing, which is useful interview breadth but is *not* your identity — your narrative is from-scratch infrastructure. Read them after Week 40 for vocabulary, not for direction.

# Chapter 49 · The Library — Papers, Blogs, RFCs, Talks, Repos

### 49.1 The research-paper canon (the ~40 reading-log spine)

| Domain | Papers |
|---|---|
| Distributed foundations | Lamport “Time, Clocks” · “The Tail at Scale” · “Fallacies of Distributed Computing” |
| Consensus | Raft (extended) · “Paxos Made Simple” · ZooKeeper · Chubby |
| Storage & data | GFS · Bigtable · Dynamo · Spanner · the Log-Structured Merge-Tree paper |
| Compute | MapReduce · Spark/RDD · Dryad (optional) |
| Search | “Anatomy of a Large-Scale Hypertextual Web Search Engine” (Brin & Page) · the Mercator crawler |
| Platform & ops | Borg · “Borg, Omega, and Kubernetes” · Dapper · Zanzibar |
| AI systems | “Attention Is All You Need” · Megatron-LM · ZeRO · Mixed Precision Training · FlashAttention · Orca · vLLM/PagedAttention · GPipe |
| Security & identity | Macaroons · BeyondCorp · SAIF · “Model Cards” · NIST AI RMF · OWASP LLM Top 10 |

### 49.2 Engineering blogs (the practice layer)

Cloudflare · Stripe · Cockroach Labs · Google Research & the Google SRE blog · the CNCF blog · Discord Engineering · Netflix TechBlog · Uber Engineering · the Modal and vLLM blogs (AI infra) · Simon Willison’s blog (LLM security) · Marc Brooker’s blog (distributed systems) · Murat Demirbas’s blog (papers, distilled).

### 49.3 RFCs & specifications (the ground truth)

RFC 9110/9112 (HTTP) · RFC 8446 (TLS 1.3) · RFC 9000 (QUIC) · the Raft paper as spec · the gRPC & Protocol Buffers specs · the OpenTelemetry specification · the SPIFFE/SPIRE spec · the Kubernetes API conventions · the SLSA framework.

### 49.4 Conference talks & channels (the intuition layer)

- **Courses/series:** MIT 6.824 (Distributed Systems, lectures online) · Andrej Karpathy’s “Neural Networks: Zero to Hero.”
- **Talks:** Kavya Joshi (Go internals) · Kyle Kingsbury / Jepsen talks (consistency) · Tyler McMullen (edge systems) · relevant CNCF/KubeCon and Strange Loop archives.
- **Channels/newsletters:** The Pragmatic Engineer (Orosz) · ByteByteGo (system design) · SWE-focused distributed-systems newsletters · the CNCF and LWN feeds.

### 49.5 Repositories to read (the apprenticeship)

etcd (raft package) · Kubernetes (controller-runtime, a small controller) · vLLM (scheduler) · nanoGPT · SPIRE · Open Policy Agent · Prometheus · and — the deepest lesson — your own repos, re-read six months later.

# Chapter 50 · Using This Handbook

A short operating manual for the document itself:

- **Weekly:** fill the weekly-review template every Sunday; commit it to the repo. This is the single highest-leverage habit in the blueprint.
- **Per level:** at each exit, check the exit criteria, answer the reflection questions, and re-score the skills matrix (Chapter 10) and the metrics (Chapter 12).
- **Quarterly:** cut a new version (v1.1…) — update what you’ve learned, prune what didn’t work, and log it in CHANGELOG.md.
- **At Penn start:** cut v2.0 — re-aim the beyond-40-weeks engine at coursework + job conversion.
- **When in doubt:** every decision resolves against one sentence — does this reinforce “secure, reliable distributed infrastructure and AI systems at scale”? If not, it doesn’t belong.

# Appendix A · Templates

These live in /templates/ in the repo. Filling one should never require a blank page.

### design-doc-template.md

```text
# <System> Design Doc
## Problem        # what and why, in plain language
## Goals / Non-goals
## Requirements   # functional + non-functional (scale, latency, consistency)
## Design         # the approach, with a diagram
## Alternatives   # what else was considered
## Trade-offs     # what we gave up, what we gained, what would change the call
## Risks / failure modes
## Rollout & observability
```

### project-template.md (the 24-point charter, condensed)

```text
# <Project> Charter
Vision · Problem · Functional reqs · Non-functional reqs · Constraints · Trade-offs
Architecture / Sequence / Component / Infra diagrams (links to assets/)
DB schema · API spec · Threat model · Security controls
CI/CD · Observability · Testing strategy · Benchmarks · Load tests
Deployment guide · Scalability roadmap · Future work · Lessons learned
```

### weekly-review.md

```text
# Week NN — Level X
Shipped · Concept learned · Paper logged · OSS · Writing · Career
Metrics delta · Blocked/cut (+reason) · Single most important thing next week
```

### paper-review.md

```text
# <Paper Title> (<year>)
Problem · Key idea · How it works (3–5 lines)
How it applies to MY systems · One critique or open question
```

### reading-notes.md & architecture-template.md

reading-notes.md mirrors paper-review for books (chapter → 3 takeaways → where it applies). architecture-template.md is the diagram checklist: context → container → component → the trust boundaries to mark.

# Appendix B · Checklists

### Flagship Definition-of-Done

- All 24 charter sections present · Meridian-Standard README · diagram above the fold · ≤90s demo · live URL where feasible.
- Threat model + security review · benchmarks with hardware named · chaos/failure scenarios tested · runbook · lessons-learned post.
- Deployed via IaC · cross-linked to connected systems · pinned in the right order.

### Level-exit checklist

- Exit criteria met · reflection questions answered publicly · skills matrix re-scored · metrics updated · writing package shipped · next level’s prerequisites confirmed.

### Weekly checklist

- Something shipped · one concept teachable · one paper logged · OSS touched · writing advanced · [Wk18+] applications sent · review committed · Sunday protected.

# Appendix C · Glossary

A living glossary lives in the repo; a starter set of the terms this handbook assumes fluency in:

| Term | One-line meaning (as used here) |
|---|---|
| Consensus | Getting distributed nodes to agree on a value despite failures (Raft, Paxos). |
| Linearizability | The strongest single-object consistency: operations appear instantaneous and ordered. |
| Quorum | The minimum node count that must respond for a read/write to be valid (R+W>N). |
| Control plane / data plane | The part that decides (config, scheduling) vs the part that does the per-request work. |
| Reconciliation | Continuously driving observed state toward desired state (Kubernetes controllers). |
| SLO / error budget | A reliability target, and the allowed amount of failure before you stop shipping features. |
| KV cache (LLM) | Stored attention keys/values so a model doesn’t recompute past tokens each step. |
| Continuous batching | Adding/removing requests from a running inference batch to keep the GPU full. |
| SVID / workload identity | A short-lived cryptographic identity issued to a service or agent (SPIFFE). |
| Deny-by-default | A policy stance where everything is forbidden unless explicitly allowed. |
| Hash chain | An append-only log where each entry includes the previous entry’s hash — tamper-evident. |

> This completes Version 1.0 of the Blueprint. Seven parts, six levels, six interconnected flagships, one identity. The next move is execution — and, as you asked, a focused pass on aligning your website, GitHub, LinkedIn, and Medium so every surface says the same sentence. Build. Secure. Lead.
