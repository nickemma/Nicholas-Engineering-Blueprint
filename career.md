# Career plan

Job-search plan, kept beside the evidence they point to. The learner-facing version is the [career map in JOURNEY.md](JOURNEY.md#11-career-map). My MSc plan is in [notes/research-track.md](notes/research-track.md), and my capstone is [KESTREL](capstones/01-kestrel.md).

Links were checked on 2026-10-29. Careers pages move, so if one breaks, search the company's name plus "careers".

## 1. Target roles

Phases 0–7 are done, and I have five years of professional experience, so per the career map I should aim at mid-level roles. Search for each of these titles.

| Family | Titles to search | Fit now | Evidence to point at |
|---|---|---|---|
| Backend | Backend Software Engineer; Software Engineer, Backend | **Strong** | Phases 1–3 (layered service, PostgreSQL, outbox, caching, idempotency); Westpay's idempotent payment APIs |
| Platform | Platform Engineer; Platform Software Engineer; Developer Infrastructure / Developer Productivity Engineer | **Strong** | Phase 5 (Helm, CI/CD by digest, a reconciler); VEYRONIX |
| Infrastructure and cloud | Infrastructure Engineer; Software Infrastructure Engineer; Cloud Infrastructure Engineer; Cloud Engineer; Compute Infrastructure Engineer | **Strong** once the AWS gap below is closed | Phase 5 (Kubernetes, Terraform for AWS); LATTICE (Terraform, ArgoCD) |
| Reliability | Site Reliability Engineer; Production Engineer | **Competitive**: what's missing is real on-call | Phase 5 (SLOs, burn-rate alerts, game day, postmortem, runbook); LATTICE's chaos suite and postmortem |
| Distributed systems | Distributed Systems Engineer; Systems Software Engineer | **Competitive**, and strong with the distributed design track | Phase 4 (own Raft, Porcupine, TLA+, sharding, fencing); MERIDIAN |
| Data and storage | Data Infrastructure Engineer; Storage Engineer; Database Engineer | Data infrastructure **competitive**; storage engine teams a **stretch** | Phase 7 (Kafka to Parquet, Spark, DuckDB); Rust Bridge log; MERIDIAN's LSM engine |
| ML infrastructure | ML Infrastructure Engineer; MLOps Engineer; ML Platform Engineer | **Competitive** | Phase 7 (serving behind the Go API, registry, gate, drift, shadow); TESSERA |
| AI infrastructure | AI Infrastructure Engineer; Inference Engineer; LLM Serving / Inference Infrastructure Engineer; GPU Platform Engineer; AI Systems Engineer | **Competitive** for serving and gateway roles now (TESSERA); GPU and training roles after Phase 8; **strong** with an AI-infrastructure capstone (briefs 4–7) | TESSERA (vLLM on GPU nodes, a multi-tenant gateway, token budgets, cost per million tokens); Phase 7's serving; Phase 8 |
| Networking | Network Software Engineer | **Stretch**: not covered by the career map | Phase 2 (TCP), Phase 5 (L4/L7 balancing, impairment), Phase 6 (mTLS, sidecar); KESTREL is the networking evidence |
| DevOps | DevOps Engineer | **Selectively**. Skip roles that are mostly ticket-driven operations | Phase 5 CI/CD, images, IaC; Phase 6 supply-chain scans |

## 2. Where

- **Canada:** remote or on-site, anywhere in the country.
- **Elsewhere:** remote only.
- **For every posting, record:** whether it sponsors a Canadian work permit, or whether it can hire a remote contractor or employee in Nigeria. Many "remote" roles are remote within one country only. Read the location line before tailoring anything.

## 3. Target companies

Don't apply to "the company". On each careers page, filter the location to Canada (or remote), then search for these terms: `infrastructure`, `platform`, `reliability`, `SRE`, `distributed systems`, `storage`, `production engineering`, `inference`, `GPU`, `ML platform`. Read the team's engineering writing before applying, and name something specific from it in the cover note.

### Big tech and large engineering organisations

| Company | Careers | Engineering writing | Look for |
|---|---|---|---|
| Amazon / AWS | [amazon.jobs](https://www.amazon.jobs/en/), [AWS careers](https://aws.amazon.com/careers/) | [Amazon Science](https://www.amazon.science/) | AWS service teams (storage, databases, compute, networking); Vancouver and Toronto offices |
| Microsoft | [careers.microsoft.com](https://careers.microsoft.com/) | [Microsoft dev blogs](https://devblogs.microsoft.com/) | Azure infrastructure and platform teams; Vancouver office |
| Google | [Google careers](https://www.google.com/about/careers/applications/) | [Google Research](https://research.google/), [Google Cloud blog](https://cloud.google.com/blog) | SRE, Google Cloud, infrastructure; Waterloo, Toronto and Montréal offices |
| Shopify | [shopify.com/careers](https://www.shopify.com/careers) | [Shopify Engineering](https://shopify.engineering/) | Infrastructure, production engineering, data platform. Founded in Ottawa, and hires remotely across Canada |
| Cloudflare | [cloudflare.com/careers](https://www.cloudflare.com/careers/) | [Cloudflare blog](https://blog.cloudflare.com/) | Edge, networking, storage and systems roles; filter by location |
| Datadog | [careers.datadoghq.com](https://careers.datadoghq.com/) | [Datadog engineering blog](https://www.datadoghq.com/blog/engineering/) | Distributed storage, ingestion, reliability |
| IBM | [ibm.com/careers](https://www.ibm.com/careers) | [IBM Research](https://research.ibm.com/) | Cloud, storage, systems software in IBM Canada |
| Oracle | [oracle.com/careers](https://www.oracle.com/careers/) | — | Oracle Cloud Infrastructure (OCI) teams |

### Canadian companies doing serious infrastructure

| Company | Careers | Engineering writing | Look for |
|---|---|---|---|
| 1Password (Toronto) | [1password.com/careers](https://1password.com/careers) | [1Password blog](https://1password.com/blog) | Infrastructure, security engineering, platform |
| Wealthsimple (Toronto) | [wealthsimple.com/careers](https://www.wealthsimple.com/en-ca/careers) | [Wealthsimple magazine](https://www.wealthsimple.com/en-ca/magazine) | Platform, infrastructure, reliability: payments and fintech, close to Westpay |
| Cohere (Toronto) | [cohere.com/careers](https://cohere.com/careers) | [Cohere research](https://cohere.com/research) | ML infrastructure, inference, training platform: TESSERA and Phase 7 |
| Waabi (Toronto) | [waabi.ai/careers](https://waabi.ai/careers/) | [Waabi research](https://waabi.ai/research/) | Infrastructure for simulation and ML, data platform |
| Klaviyo | [klaviyo.com/careers](https://www.klaviyo.com/careers) | [klaviyo.tech](https://klaviyo.tech/) | Infrastructure and data platform. **Correction to my old notes:** Klaviyo is headquartered in Boston, not Canada. Check each role's location |

### AI infrastructure companies

Cohere and Waabi (above) are the Canadian ones. These build the hardware, clouds and serving platforms underneath AI products; most hire remotely, so check each role's location.

| Company | Careers | Engineering writing | Look for |
|---|---|---|---|
| NVIDIA | [nvidia.com/careers](https://www.nvidia.com/en-us/about-nvidia/careers/) | [NVIDIA technical blog](https://developer.nvidia.com/blog/) | Inference software, GPU cloud and cluster infrastructure, Kubernetes for GPUs |
| AMD | [careers.amd.com](https://careers.amd.com/) | [ROCm blogs](https://rocm.blogs.amd.com/) | ROCm software, AI inference and training infrastructure; filter by Canada |
| Tenstorrent (Toronto) | [tenstorrent.com/careers](https://tenstorrent.com/careers) | — | AI accelerators: compilers, runtime and ML systems software |
| CoreWeave | [coreweave.com/careers](https://www.coreweave.com/careers) | [CoreWeave blog](https://www.coreweave.com/blog) | GPU cloud: Kubernetes, scheduling, storage, networking |
| Anyscale | [anyscale.com/careers](https://www.anyscale.com/careers) | [Anyscale blog](https://www.anyscale.com/blog) | The company behind Ray: distributed compute, serving, cluster infrastructure |
| Together AI | [together.ai/careers](https://www.together.ai/careers) | [Together AI blog](https://www.together.ai/blog) | Inference platform, GPU clusters, training infrastructure |
| Modal | [modal.com/careers](https://modal.com/careers) | [Modal blog](https://modal.com/blog) | Serverless GPU infrastructure: scheduling, containers, storage |
| Baseten | [baseten.co/careers](https://www.baseten.co/careers/) | [Baseten blog](https://www.baseten.co/blog/) | Model serving and inference performance |

### Startups and mid-size companies

Don't keep a fixed list. Find them on Wellfound, Work at a Startup and Hacker News each month (section 4). Then use the same test as for the big companies: the startup has to have an infrastructure problem worth having. A startup where I'd be the only backend engineer gives breadth, but no one to learn infrastructure from.

## 4. Job boards

| Board | Use it for |
|---|---|
| [LinkedIn Jobs](https://www.linkedin.com/jobs/) | Everything. Set alerts for the titles in section 1, located in Canada, plus remote |
| [Indeed Canada](https://ca.indeed.com/) | Canadian roles that are not on LinkedIn |
| [Job Bank](https://www.jobbank.gc.ca/) | The Government of Canada's board. Shows which employers are hiring in Canada, with wage data by occupation |
| [DevJobsScanner, Canada](https://www.devjobsscanner.com/developer-jobs-in-canada/) | An aggregator of developer roles across Canadian sources |
| [Wellfound](https://wellfound.com/) | Startups, with salary and equity on most listings |
| [Work at a Startup](https://www.workatastartup.com/) | Y Combinator companies; many hire remotely |
| [Hacker News "Who is hiring?"](https://news.ycombinator.com/submitted?id=whoishiring) | A monthly thread, posted on the first weekday. Search it for `Canada`, `remote`, `infrastructure` |
| [We Work Remotely](https://weworkremotely.com/) | Remote roles outside Canada |

"Canada Dev Jobs" from my old notes is gone: canadadevjobs.com didn't resolve on 2026-10-29.

## 5. Applying, week by week

- **Each week:** five to eight tailored applications, not thirty generic ones. Target one or two of them through a referral or a direct message to someone on the team.
- **Tailor with the gap ledger:** for each requirement in the posting, write one line: "I didn't know X; I closed it in Phase N by doing Y; here's the evidence: Z" (see [Telling your progression story](JOURNEY.md#telling-your-progression-story)). Link the exact guide section, test or report, not the repository's front page.
- **Reorder the CV per role:** for SRE and platform roles, put the Blueprint first; for distributed-systems roles, MERIDIAN; for search and data roles, LATTICE; for AI-infrastructure roles, TESSERA (and Phase 8, once it's done).
- **Keep a tracker** (a private spreadsheet, not this public file):

| Company | Role | Link | Location / sponsorship | Applied | Referral | Stage | Next step, date |
|---|---|---|---|---|---|---|---|

## 6. Interview preparation

The loop has four parts, each prepared in a different place.

| Part | Prepare with |
|---|---|
| Coding | [dsa/](dsa/README.md): the 20 patterns, about 150 problems, in Go and Python |
| System design | [system-design/](system-design/README.md): the Fundamentals track first, then the track for the role |
| Domain deep dive | The Blueprint, MERIDIAN, LATTICE and TESSERA. Be able to rebuild any part on a whiteboard |
| Behavioural | Postmortems and failure notes ([notes/failures.md](notes/failures.md), [notes/decisions.md](notes/decisions.md)), told as stories |

### Coding: enough to pass the screen

You don't need to be a competitive programmer. In [dsa/](dsa/README.md) order, cover these:

- arrays and hashing;
- two pointers;
- sliding window;
- stack;
- binary search;
- linked lists;
- trees;
- heaps;
- graphs;
- 1D dynamic programming.

Then move to the design problems (an LRU cache, a rate limiter, consistent hashing). Strings come up across all of them.

### Backend and distributed systems: where I built each topic

| Topic | Built in |
|---|---|
| HTTP, REST, validation | [Phase 0](lessons/00-request-service/README.md), [Phase 1](lessons/01-reliable-service/README.md) |
| Concurrency, contexts, graceful shutdown | [Phase 1](lessons/01-reliable-service/README.md), [Rust Bridge](lessons/rust-bridge/README.md) |
| Message queues, idempotency, retries, dead letters, circuit breakers, gRPC | [Phase 2](lessons/02-connected-services/README.md) |
| SQL, PostgreSQL, transactions, pooling, outbox, Redis caching, Kafka | [Phase 3](lessons/03-durable-auditable-data/README.md) |
| Replication, consensus, leader election, consistency, CAP, sharding, distributed locks | [Phase 4](lessons/04-replicated-state/README.md) |
| Docker, load balancing, service discovery, observability, SLOs, failure handling | [Phase 5](lessons/05-constrained-operations/README.md) |
| Authentication, authorization, rate limiting, mTLS, secrets | [Phase 6](lessons/06-safe-shared-queries/README.md) |
| Event pipelines, experiments, ML serving, drift, anomaly detection | [Phase 7](lessons/07-utility-evaluation/README.md) |

"Design a system for 10 million requests a second" is a system-design question. Practise it in the Fundamentals track: estimation first, then the crux, then partitioning, caching and load balancing.

### AI infrastructure: where each topic is built

AI-infrastructure loops add an ML system design round (the [Applied ML systems track](system-design/README.md#tracks): LLM inference gateway, model serving, training pipeline) and a deep dive on serving or GPUs.

| Topic | Built in |
|---|---|
| Model serving behind a gateway: timeouts, breaker, fallback, train/serve parity | [Phase 7](lessons/07-utility-evaluation/README.md) |
| LLM serving: KV cache, batching, prefill and decode, time to first token, inter-token latency | TESSERA (vLLM on GPU nodes); Phase 8 |
| Multi-tenant token budgets, rate limits, cost per million tokens | TESSERA; Phase 6 (rate limits); Phase 8 (cost benchmark) |
| GPU memory, CPU-to-GPU transfers, utilisation | Phase 8 (CUDA basics) |
| Distributed training: data, tensor and pipeline parallelism | Phase 8 (PyTorch Distributed, Megatron-LM) |
| Scaling Python work across a cluster | Phase 8 (Ray) |
| GPU scheduling, bin packing, fairness, SLO-driven preemption | Capstone brief 5 |
| Checkpointing large training state | Capstone brief 6 |

### Cloud: one cloud deeply, AWS first

| AWS service | Status |
|---|---|
| VPC, IAM, ECS on Fargate, RDS, S3, SQS, ALB, CloudWatch, budgets; Terraform | Built in [Phase 5](lessons/05-constrained-operations/README.md), planned offline. **Apply it once**, with the budget and the clean-up from the guide, so I can say I ran it, not just planned it |
| Lambda, DynamoDB, API Gateway | [GoCloudAuth](https://github.com/nickemma/GoCloudAuth) (CDK) |
| EC2 directly, SNS, EKS | **Gaps.** Close them by running Runway's chart on EKS, and by fanning job events out through SNS to SQS |
| Kubernetes, CI/CD, Docker | Phase 5 (kind, Helm, the pipeline) |

## 7. Certifications

Six certificates, in this order. Exam details, links and why each one matters are in [JOURNEY's certifications table](JOURNEY.md#certifications) (checked on 2026-10-29).

| # | Certificate | When | Cost | Studying left after the Blueprint |
|---|---|---|---|---|
| 1 | CKA | Now: Phase 5 is done | $445 | Speed at the command line: etcd backup and restore, cluster upgrades with kubeadm, troubleshooting nodes. Practise against the clock |
| 2 | Terraform Associate (004) | Alongside CKA | $70.50 | Terraform Cloud, workspaces, state commands |
| 3 | AWS Solutions Architect – Professional (SAP-C03) | After applying Phase 5's Terraform and closing the EKS and SNS gaps | $300 | Multi-account design, migration, hybrid networking, cost optimisation |
| 4 | CKS | After CKA | $445 | Runtime security (Falco), AppArmor and seccomp, image scanning at the command line |
| 5 | Google Cloud Professional Cloud Architect | After porting one Runway deployment to GCP | $200 | GCP's services and the exam's case studies |
| 6 | NVIDIA AI Infrastructure and Operations, Associate (NCA-AIIO); later the Professional (NCP-AII) | During Phase 8 | $125, then $400 | GPU hardware, networking and operations; the Professional expects 2–3 years with NVIDIA data-centre hardware |

That's $1,585.50 for the first six exams, plus $400 for the NVIDIA Professional. Book each one only once its phase is done, so the studying fills gaps instead of starting from zero.

---

**Nicholas Emmanuel**
Distributed Systems & Infrastructure Engineer
Lagos, Nigeria · nicholasemmanuel321@gmail.com · [github.com/nickemma](https://github.com/nickemma) · [linkedin.com/in/techieemma](https://www.linkedin.com/in/techieemma) · [techieemma.vercel.app](https://techieemma.vercel.app)

**Nicholas Engineering Blueprint**: a public systems curriculum, built and measured end to end · Go, Python, Rust, Kubernetes, Kafka · [github.com/nickemma/Nicholas-Engineering-Blueprint](https://github.com/nickemma/Nicholas-Engineering-Blueprint)
- A type-along course in which one jobs platform, Runway, grows from a single HTTP handler into a replicated, secured, observed and measured system, with every code block and every output real.
- Built from scratch along the way: Raft on a deterministic simulated network, checked with Porcupine and a TLA+ model; consistent-hash sharding; leases with fencing tokens; a Rust append-only log with its own CRC-32C.
- Operated and secured it on Kubernetes. Operations: Helm, SLOs with tested burn-rate alerts, a game day and a postmortem, Terraform for AWS. Security: my own CA with mTLS and rotation, per-Pod database logins from OpenBao, PostgreSQL row-level security, and a Merkle-tree audit log with a witness.
- Measured it: a Kafka-to-Parquet pipeline; gradient-boosted trees and PyTorch predicting job durations, served behind the Go API with a breaker and a fallback. A parity test caught a train/serve leak, and the final report re-tests every claim: two of fourteen didn't replicate, and it says so.
- CI rebuilds all the code from the guides (about 2,000 steps), and the result must match the reference exactly.
