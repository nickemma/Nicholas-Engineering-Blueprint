# System design

System-design interviews decide the level you're hired at. This track prepares you for them in the five areas this program leads to: **cloud and infrastructure, distributed systems, platform, ML system design, and applied ML systems**. Every design links back to code you built in the lessons, so you can say "I've built this part" rather than "I've read about it".

Start in Phase 2, with one session a week.

## What the interviewer is judging

Interviewers score four dimensions. Know what each looks like at each level:

| Dimension | Weak | Mid | Strong |
|---|---|---|---|
| **Problem navigation** | Starts drawing boxes straight away; never finds the hard part | Gathers requirements but treats them all as equally important | Turns a vague prompt into numbered requirements with numbers, then **names the crux** and spends the interview on it |
| **Solution design** | A generic diagram that would fit any problem | A sensible design, but the hard part is hand-waved | Every component exists because a requirement needs it; the crux gets a concrete mechanism |
| **Technical excellence** | Buzzwords ("add Kafka, add a cache") with no reason | Correct choices, shallow trade-offs | Numbers, failure modes and trade-offs: what breaks, what it costs, what you'd pick instead and when |
| **Communication and collaboration** | A monologue, or silence; defensive when challenged | Clear, but doesn't check in | Says the plan out loud, checks in at milestones, treats hints as collaboration, adapts |

## The crux-first rule

> They spent all their time on the User table, never touching the most important part.

This is the most common way strong engineers fail design interviews. Every problem has one or two parts that make it **hard**:

- the fan-out in a news feed;
- the consistency of a distributed lock;
- the hot keys in a cache;
- the latency budget of a model-serving path.

The users table, the login flow and the CRUD endpoints are almost never the hard part.

**The rule:**

1. Within the first 8–10 minutes, say out loud: *"The hard part of this problem is X, because Y. I'd like to spend most of our time there. Does that match what you want to explore?"*
2. Spend **no more than 3 minutes** on core entities and CRUD APIs. List them, don't design them.
3. Your first deep dive is the crux. Everything else comes after.

Every design in this folder starts with a **"The crux"** section, written before anything else.

## The 45-minute script

| Minutes | Do | Checkpoint to say out loud |
|---|---|---|
| 0–5 | **Requirements.** Functional (3–5 numbered features). Non-functional, with numbers: users, requests per second, data size, latency, availability, consistency. What's out of scope | "Here's what I'll design and what I'm leaving out. Anything you'd change?" |
| 5–8 | **Estimates**, only the ones that change a decision: read/write ratio, storage per year, peak requests per second | "This tells me reads dominate, so..." |
| 8–10 | **Name the crux** | "The hard part is X. I'll focus there." |
| 10–13 | **API and core entities.** A list, not a design | — |
| 13–23 | **High-level design** aimed at the crux. Draw the request path end to end | "Here's the end-to-end flow. Before I go deeper, any questions?" |
| 23–38 | **Deep dives**, crux first: data model and partitioning, consistency, the hot path, failure handling | "I see two options here. A gives..., B gives... I'd pick A because..." |
| 38–45 | **Trade-offs and failures.** What breaks first at 10× load? What happens when a node or region dies? What would you build next? | "If I had more time, I'd..." |

**ML system design follows a different shape.** Spend the first 10 minutes on framing:

1. the business goal and the ML objective (and how they differ);
2. the success metrics, offline and online;
3. the data and labels.

The deep dives then cover features, the model (baseline first), evaluation, serving, monitoring and feedback loops. Use [_template-ml.md](_template-ml.md).

## Tracks

| Track | Prepares you for | Designs | Built in |
|---|---|---|---|
| **Fundamentals** | Every track | Estimation; latency numbers; load balancing; caching; queues; replication; partitioning; consistency models; consensus; rate limiting; idempotency; storage types; observability | Phases 0–5 |
| **Cloud and infrastructure** | Cloud/Infra, DevOps, SRE | Multi-region web service; object storage (like S3); DNS service; metrics and alerting system; CI/CD system; secrets distribution | Phase 5 |
| **Distributed systems** | Distributed Systems, Storage, SRE | Distributed key-value store; distributed lock service; Kafka-style log; job scheduler; unique ID generator; distributed cache; rate limiter | Phases 2–4 |
| **Platform** | Platform, DevOps | Internal developer platform; deployment orchestrator; feature-flag service; configuration management; multi-tenant Kubernetes; service mesh control plane | Phase 5 |
| **ML system design** | Applied ML / ML Engineer | Recommendation system; search ranking; ads click-through prediction; fraud detection; content moderation; feed ranking | Phase 7 |
| **Applied ML systems** | ML Infrastructure, MLOps, AI Infrastructure | LLM inference gateway; model-serving platform; feature store; training pipeline; RAG system; vector search; model monitoring | Phase 7 |
| **Classic warm-ups** | Generalist loops | URL shortener; chat; news feed; ride matching; ticket booking | Phases 1–3 |

## Folder layout

~~~text
system-design/
  README.md               this page: rubric, crux rule, script, tracks
  _template.md            the design template for every non-ML track
  _template-ml.md         the ML design template
  scorecard.md            self-scoring after each practice session
  fundamentals/           one short page per building block
  cloud-infra/
  distributed-systems/
  platform/
  ml-system-design/
  applied-ml-systems/
  classic/
~~~

## How to practise

1. **Pick a design for your track.** Set a 45-minute timer. Talk out loud. Draw in [Excalidraw](https://excalidraw.com/) or on paper.
2. **Write it up** with the template **after** the timer. Do this before reading any reference design.
3. **Score yourself** with [scorecard.md](scorecard.md). Note the single biggest thing to improve.
4. **Then read** the reference design in this folder and write down what you missed.
5. **Every fourth session, do a mock with a person.** Ask them to push on your crux.
