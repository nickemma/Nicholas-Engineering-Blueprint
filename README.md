# The Blueprint

**From first request to distributed systems and infrastructure.** This is a complete, beginner-to-advanced path through backend, distributed systems and infrastructure engineering, with the ML and AI infrastructure that runs on it, finishing in a research capstone of your choice.

You learn by building **Runway**, a jobs platform, one phase at a time. It starts as a single Go web service and grows workers, a message broker, durable storage, replication, Kubernetes and AWS, security, ML on its own data, and the infrastructure that serves and trains AI models. Every phase is a type-along guide: the code is inline and explained, every step is checked in CI, and each step has a deliberate way to break it. Each phase ends with an **exercise project** you build alone, with a clear spec and no solution. After Phase 8 comes the **capstone**: one of ten research projects, taken from problem to evidence.

## Start here

1. Read **[JOURNEY.md](JOURNEY.md)**, the single map: what you'll build, the route, the gaps each phase closes, the patterns you'll use, and the roles each phase prepares you for.
2. Begin **[Phase 0](lessons/00-request-service/README.md)**. It assumes no prior Go, Linux or HTTP.
3. Start the **[DSA track](dsa/README.md)** at the same time. Add the **[system-design track](system-design/README.md)** at Phase 2.
4. Browse the **[capstones](capstones/README.md)** early, so you know where you're heading.

## Repository map

| Folder | What it holds |
|---|---|
| [lessons/](lessons) | One folder per phase: a syllabus, a type-along guide, an exercise project, and an answer sheet |
| [capstones/](capstones/README.md) | Ten research projects for the capstone, after Phase 8: distributed systems, networking, security, big data and AI infrastructure, each with a stack, features and a benchmark plan; a proposal template and the judging criteria |
| [dsa/](dsa/README.md) | Algorithm patterns in Go and Python, linked to the real systems that use them |
| [system-design/](system-design/README.md) | A rubric, an interview script and designs by track, linked back to the code |
| [scripts/](scripts) | `test_all.sh` runs every check CI runs. `check_guides.py` rebuilds each guide's code from the guide itself and tests it |
| [notes/](notes) | Self-tests for each phase (`notes/learned/`), plus the author's decisions, failures and research track |

## Check everything locally

~~~bash
bash scripts/test_all.sh
~~~

This needs Go 1.26+, Python 3 with `uv`, `protoc`, and Rust for the later phases. RabbitMQ integration tests run when `RUNWAY_AMQP_URL` points at a broker; otherwise they're skipped.
