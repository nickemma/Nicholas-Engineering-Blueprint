# Careers: where the Blueprint can take you

This page shows the experience you'll have when you finish, the roles it prepares you for, the companies hiring for them in Canada and the USA, and how to search and prepare. The job-search routine is optional: use it, adapt it, or skip it.

Links were checked on 2026-10-29. Careers pages move, so if one breaks, search the company's name plus "careers".

## 1. The experience you'll have

Finishing the Blueprint doesn't equal years in production, but it gives you real, checkable evidence. Everyone who finishes the core has:

- a Go control plane and a Rust data plane talking over a wire protocol you designed, with flame graphs showing where the time goes;
- your own Raft, surviving crashes and network partitions under an automated test;
- PostgreSQL and Docker used properly: migrations, pooling, transactions, contract tests;
- Rust beyond the basics: `unsafe`, FFI to C, atomics, a hand-written async executor, all checked with Miri, sanitizers and fuzzing;
- a threat model, mTLS with your own certificate authority, a runbook, a postmortem and an architecture decision record (ADR);
- a gate passed at the end of every module: proof that the system survives failure, not just that it runs.

Each track then adds a shipped system, published with reproducible benchmarks, before-and-after flame graphs, and a design doc:

| Track | What you ship | What you can then talk about in depth |
|---|---|---|
| AI infrastructure | An OpenAI-compatible inference gateway | Model serving, KV caches, batching, time to first token, GPU memory, distributed training, MLOps, multi-tenant token budgets, securing AI agents |
| Storage engines | A distributed key-value store on your own LSM-tree engine | Write-ahead logs, compaction, MVCC, isolation levels, replication, sharding, crash recovery, linearizability |
| Cloud and network | A programmable edge proxy with its own control plane | L4/L7 proxying, HTTP/2 and HTTP/3, congestion control, Kubernetes, Terraform on AWS, mTLS rotation, eBPF |

## 2. Roles to target

Search for each of these titles. The **level** to aim for depends on you:
- If you're new to the field, aim for junior, new-grad or "Engineer I" roles.
- If you already work as a developer, aim for mid-level.
- Senior titles expect systems you've owned in production. The Blueprint's ownership levels show what that means and how to start building it at work.

| Family | Titles to search | Best prepared by |
|---|---|---|
| Backend | Backend Software Engineer; Software Engineer, Backend | The core (Go services, Docker, PostgreSQL); the storage track |
| Platform | Platform Engineer; Developer Infrastructure / Developer Productivity Engineer | Cloud and network track (Kubernetes and delivery) |
| Infrastructure and cloud | Infrastructure Engineer; Cloud Infrastructure Engineer; Cloud Engineer; Compute Infrastructure Engineer | Cloud and network track (Kubernetes, AWS and Terraform) |
| Reliability | Site Reliability Engineer; Production Engineer | The core's last module (SLOs, runbooks, postmortems), plus Kubernetes and delivery; any track |
| Distributed systems | Distributed Systems Engineer; Systems Software Engineer | The core (Raft, Rust for systems); the storage track |
| Storage and databases | Storage Engineer; Database Engineer; Data Infrastructure Engineer | Storage track; event streams |
| ML infrastructure | ML Infrastructure Engineer; ML Platform Engineer; MLOps Engineer | AI infrastructure track (ML for infrastructure, serving) |
| AI infrastructure | AI Infrastructure Engineer; Inference Engineer; LLM Serving Engineer; GPU Platform Engineer; AI Systems Engineer | AI infrastructure track |
| Networking | Network Software Engineer; Edge Engineer | Cloud and network track |
| DevOps | DevOps Engineer | Cloud and network track. Prefer roles that build systems over ticket-driven operations |

## 3. Where: Canada and the USA

- Search both countries, and remote roles in each.
- **Check work authorisation first.** For every posting, note whether the role sponsors a visa or work permit, or needs existing authorisation. Many "remote" roles are remote within one country only, so read the location line before tailoring anything.
- Both countries have public wage data by occupation: Canada's [Job Bank](https://www.jobbank.gc.ca/) and the US [Bureau of Labor Statistics](https://www.bls.gov/ooh/).

## 4. Target companies

Don't apply to "the company". On each careers page, filter by location, then search for: `infrastructure`, `platform`, `reliability`, `SRE`, `distributed systems`, `storage`, `networking`, `production engineering`, `inference`, `GPU`, `ML platform`. Read the team's engineering writing before applying, and name something specific from it in your cover note.

Locations below are the main engineering hubs; offices change, so filter on each careers page.

### Large engineering organisations

| Company | Canada | USA | Careers | Engineering writing | Look for | Tracks |
|---|---|---|---|---|---|---|
| Amazon / AWS | Vancouver, Toronto | Seattle and others | [amazon.jobs](https://www.amazon.jobs/en/), [AWS careers](https://aws.amazon.com/careers/) | [Amazon Science](https://www.amazon.science/) | AWS service teams: storage, databases, compute, networking | All |
| Microsoft | Vancouver | Redmond and others | [careers.microsoft.com](https://careers.microsoft.com/) | [Microsoft dev blogs](https://devblogs.microsoft.com/) | Azure infrastructure and platform | All |
| Google | Waterloo, Toronto, Montréal | Mountain View, New York, Seattle and others | [Google careers](https://www.google.com/about/careers/applications/) | [Google Research](https://research.google/), [Google Cloud blog](https://cloud.google.com/blog) | SRE, Google Cloud, infrastructure | All |
| Shopify | Remote across Canada | Filter by location | [shopify.com/careers](https://www.shopify.com/careers) | [Shopify Engineering](https://shopify.engineering/) | Infrastructure, production engineering, data platform | Cloud, storage |
| Cloudflare | Filter by location | San Francisco, Austin and others | [cloudflare.com/careers](https://www.cloudflare.com/careers/) | [Cloudflare blog](https://blog.cloudflare.com/) | Edge, networking, storage, systems | Cloud, storage |
| Datadog | Filter by location | New York (HQ), Boston and others | [careers.datadoghq.com](https://careers.datadoghq.com/) | [Datadog engineering blog](https://www.datadoghq.com/blog/engineering/) | Distributed storage, ingestion, reliability | Storage, cloud |
| IBM | Markham and others | Many | [ibm.com/careers](https://www.ibm.com/careers) | [IBM Research](https://research.ibm.com/) | Cloud, storage, systems software | Storage, cloud |
| Oracle | Filter by location | Seattle, Austin and others | [oracle.com/careers](https://www.oracle.com/careers/) | — | Oracle Cloud Infrastructure (OCI) | Cloud, storage |

### Infrastructure-heavy product companies

| Company | Canada | USA | Careers | Engineering writing | Look for | Tracks |
|---|---|---|---|---|---|---|
| 1Password | Toronto | Filter by location | [1password.com/careers](https://1password.com/careers) | [1Password blog](https://1password.com/blog) | Infrastructure, security engineering, platform | Cloud |
| Wealthsimple | Toronto | — | [wealthsimple.com/careers](https://www.wealthsimple.com/en-ca/careers) | [Wealthsimple magazine](https://www.wealthsimple.com/en-ca/magazine) | Platform, infrastructure, reliability in fintech | Cloud, storage |
| Klaviyo | — | Boston (HQ) | [klaviyo.com/careers](https://www.klaviyo.com/careers) | [klaviyo.tech](https://klaviyo.tech/) | Infrastructure and data platform | Storage, cloud |

### AI infrastructure companies

| Company | Canada | USA | Careers | Engineering writing | Look for |
|---|---|---|---|---|---|
| Cohere | Toronto | Filter by location | [cohere.com/careers](https://cohere.com/careers) | [Cohere research](https://cohere.com/research) | ML infrastructure, inference, training platform |
| Waabi | Toronto | Filter by location | [waabi.ai/careers](https://waabi.ai/careers/) | [Waabi research](https://waabi.ai/research/) | Infrastructure for simulation and ML, data platform |
| Tenstorrent | Toronto | Filter by location | [tenstorrent.com/careers](https://tenstorrent.com/careers) | — | AI accelerators: compilers, runtime, ML systems software |
| NVIDIA | Toronto | Santa Clara and others | [nvidia.com/careers](https://www.nvidia.com/en-us/about-nvidia/careers/) | [NVIDIA technical blog](https://developer.nvidia.com/blog/) | Inference software, GPU cloud and cluster infrastructure, Kubernetes for GPUs |
| AMD | Markham | Santa Clara, Austin and others | [careers.amd.com](https://careers.amd.com/) | [ROCm blogs](https://rocm.blogs.amd.com/) | ROCm software, AI inference and training infrastructure |
| CoreWeave | — | Filter by location | [coreweave.com/careers](https://www.coreweave.com/careers) | [CoreWeave blog](https://www.coreweave.com/blog) | GPU cloud: Kubernetes, scheduling, storage, networking |
| Anyscale | — | San Francisco | [anyscale.com/careers](https://www.anyscale.com/careers) | [Anyscale blog](https://www.anyscale.com/blog) | Ray: distributed compute, serving, cluster infrastructure |
| Together AI | — | San Francisco | [together.ai/careers](https://www.together.ai/careers) | [Together AI blog](https://www.together.ai/blog) | Inference platform, GPU clusters, training infrastructure |
| Modal | — | New York | [modal.com/careers](https://modal.com/careers) | [Modal blog](https://modal.com/blog) | Serverless GPU infrastructure: scheduling, containers, storage |
| Baseten | — | San Francisco | [baseten.co/careers](https://www.baseten.co/careers/) | [Baseten blog](https://www.baseten.co/blog/) | Model serving and inference performance |

### Startups and mid-size companies

Don't keep a fixed list. Look each month on Wellfound, Work at a Startup and Hacker News (section 5). Use one test: does the startup have an infrastructure problem worth having? Being the only backend engineer gives breadth, but nobody to learn infrastructure from.

## 5. Job boards

| Board | Country | Use it for |
|---|---|---|
| [LinkedIn Jobs](https://www.linkedin.com/jobs/) | Both | Everything. Set alerts for the titles in section 2, in your country, plus remote |
| [Indeed Canada](https://ca.indeed.com/) | Canada | Canadian roles not on LinkedIn |
| [Indeed](https://www.indeed.com/) | USA | US roles not on LinkedIn |
| [Job Bank](https://www.jobbank.gc.ca/) | Canada | The Government of Canada's board, with wage data by occupation |
| [DevJobsScanner, Canada](https://www.devjobsscanner.com/developer-jobs-in-canada/) | Canada | An aggregator of developer roles across Canadian sources |
| [Built In](https://builtin.com/jobs) | USA | Tech roles by US city and hub |
| [Wellfound](https://wellfound.com/) | Both | Startups, with salary and equity on most listings |
| [Work at a Startup](https://www.workatastartup.com/) | Both | Y Combinator companies; many hire remotely |
| [Hacker News "Who is hiring?"](https://news.ycombinator.com/submitted?id=whoishiring) | Both | A monthly thread, posted on the first weekday. Search it for your country, `remote`, `infrastructure` |
| [We Work Remotely](https://weworkremotely.com/) | Both | Remote roles |

## 6. Applying, week by week (optional)

A routine that works. Use it, change it, or skip it.

- **Each week:** five to eight tailored applications, not thirty generic ones. Aim to reach one or two of them through a referral or a direct message to someone on the team.
- **Tailor with evidence:** for each requirement in the posting, write one line: "I didn't know X; I closed it in module N by doing Y; here's the evidence: Z". Link the exact lesson, gate result or benchmark, not your repository's front page.
- **Lead with the right project:** your track's capstone first for roles in that domain; the core's Raft and Rust work for distributed-systems roles; your postmortem and SLO work for reliability roles.
- **Keep a private tracker:** a spreadsheet, not a public file.

| Company | Role | Link | Location / work authorisation | Applied | Referral | Stage | Next step, date |
|---|---|---|---|---|---|---|---|

## 7. Interview preparation

The loop has four parts, each prepared in a different place.

| Part | Prepare with |
|---|---|
| Coding | [dsa/](dsa/README.md): the pattern guides, worked problems and practice sets |
| System design | [system-design/](system-design/README.md): the fundamentals first, then the designs for your track |
| Domain deep dive | Your track and its capstone. Be able to rebuild any part of it on a whiteboard |
| Behavioural | Your postmortems, ADRs and gate failures, told as stories: what broke, how you found it, what you changed |

For upcoming interviews, use the [timed interview rehearsal](system-design/interview-rehearsal.md) to practise decisions, tradeoffs, and failure reasoning across DSA, design, and maths.

### Coding: enough to pass the screen

You don't need to be a competitive programmer. In [dsa/](dsa/README.md) order, cover:
- arrays and hashing, two pointers, sliding window, stack, binary search;
- linked lists, trees, heaps, graphs;
- 1D dynamic programming.

Then the design problems (an LRU cache, a rate limiter, consistent hashing). Strings come up across all of them.

### Where each interview topic is built

| Topic | Built in |
|---|---|
| HTTP, APIs, validation, concurrency, contexts, graceful shutdown | Core: Go runtime and reliable services |
| Load testing, percentiles, measuring honestly | Core: Python runtime and honest measurement |
| SQL, PostgreSQL, transactions, pooling, Docker | Core: Docker and Postgres |
| Memory, ownership, `unsafe`, atomics, async internals | Core: Rust foundations; Rust for systems |
| Linux internals, TCP, profiling with `perf`, flame graphs and eBPF | Core: Linux, networking and profiling |
| Replication, consensus, leader election, leases, consistent hashing | Core: distributed-systems fundamentals |
| Containers, TLS and mTLS, threat models, SLOs, incident response | Core: shipping safely |
| Queues, retries, dead letters, circuit breakers | Shared unit: messaging and resilience |
| Kafka, the outbox, Redis caching | Shared units: event streams; caching |
| Kubernetes, CI/CD, Helm; Terraform on AWS | Shared units: Kubernetes and delivery; AWS and Terraform |
| Authentication, authorisation, tenant isolation, rate limiting | Shared unit: tenancy and abuse control |
| Isolation levels, storage engines, MVCC, sharding, linearizability | Storage engines track |
| Congestion control, HTTP/3, CDNs, proxies, eBPF/XDP | Cloud and network track |
| Model serving, KV caches, batching, GPU memory, distributed training, agent security | AI infrastructure track |
| Queueing theory, tail latency, capacity planning | [math/](math/README.md) |

"Design a system for 10 million requests a second" is a system-design question: estimate first, find the crux, then partition, cache and balance.

AI-infrastructure loops often add an ML system design round. Practise it with the [AI infrastructure designs](system-design/ai-infrastructure/README.md): an LLM inference gateway, a GPU scheduler, a training platform, model serving.

### Cloud: learn one deeply

The AWS and Terraform unit covers VPC, IAM, ECS on Fargate, RDS, S3, SQS, ALB, CloudWatch and budgets. It's planned offline, so **apply it once** (with the budget and clean-up in the guide) so you can say you ran it, not just planned it.

It doesn't cover EC2 directly, EKS, Lambda, DynamoDB or SNS. If your target roles ask for them, close the gap with a small project: for example, run your Kubernetes chart on EKS, or fan events out through SNS to SQS.

## 8. Certifications (optional)

Certificates don't replace the evidence above, but some postings filter on them. Book one only after the module or track that covers it, so the studying fills gaps rather than starting from zero. These were current on 2026-10-29; check the vendor's page for the current exam version and price before booking.

| Certificate | Fits | What to study beyond the Blueprint |
|---|---|---|
| Certified Kubernetes Administrator (CKA) | Cloud, AI | Speed at the command line: etcd backup and restore, kubeadm upgrades, node troubleshooting |
| Certified Kubernetes Security Specialist (CKS), after CKA | Cloud | Runtime security (Falco), AppArmor and seccomp, image scanning |
| HashiCorp Terraform Associate (004) | Cloud | Terraform Cloud, workspaces, state commands |
| AWS Solutions Architect – Professional (SAP-C03) | Cloud | Multi-account design, migration, hybrid networking, cost optimisation |
| Google Cloud Professional Cloud Architect | Cloud | GCP's services and the exam's case studies |
| NVIDIA AI Infrastructure and Operations, Associate (NCA-AIIO); later the Professional (NCP-AII) | AI | GPU hardware, networking and operations. The Professional expects hands-on data-centre experience |
