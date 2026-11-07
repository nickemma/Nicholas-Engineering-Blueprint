# The Blueprint

**From first request to distributed systems and infrastructure.** This is a complete, beginner-to-advanced path through backend, distributed systems and infrastructure engineering, with the ML and AI infrastructure that runs on it, finishing in a research capstone of your choice.

You learn by building **Runway**, a jobs platform, one phase at a time. It starts as a single Go web service and grows workers, a message broker, durable storage, replication, Kubernetes and AWS, security, ML on its own data, and the infrastructure that serves and trains AI models. Every phase is a type-along guide: the code is inline and explained, replayable checks run in CI, and live deployment/hardware evidence is labelled separately. Steps include deliberate ways to break the system. Each phase ends with an **exercise project** you build alone, with a clear spec and no solution. After Phase 8 comes the **capstone**: one of ten research projects, taken from problem to evidence.

## Start here

1. Read **[JOURNEY.md](JOURNEY.md)**, the single map: what you'll build, the route, the gaps each phase closes, the patterns you'll use, and the roles each phase prepares you for.
2. Beginners: choose a stopping point in the **[minimum route](lessons/ownership/beginner.md)**, then begin **[Phase 0](lessons/00-request-service/README.md)**. It assumes no prior Go, Linux or HTTP.
3. Follow the parallel tracks at a pace appropriate to your route. Start the **[DSA track](dsa/README.md)** at the same time. Add the **[system-design track](system-design/README.md)** at Phase 2, and the **[maths track](math/README.md)** when each guide's phase needs it.
4. Choose your **[assessment and ownership route](lessons/ownership/README.md)**: junior delivery, intermediate service ownership or senior technical leadership. Every phase has concrete assignments and review gates. Browse the **[capstones](capstones/README.md)** when you want a research goal.

## Repository map

| Folder | What it holds |
|---|---|
| [lessons/](lessons) | One folder per phase: a syllabus, a type-along guide, an exercise project, and an answer sheet |
| [capstones/](capstones/README.md) | Ten research projects for the capstone, after Phase 8: distributed systems, networking, security, big data and AI infrastructure, each with a stack, features and a benchmark plan; a proposal template and the judging criteria |
| [lessons/ownership/](lessons/ownership/README.md) | Beginner minimum route, phase assessments, structured review, delivery/proposal templates and twelve-week lab service ownership |
| [dsa/](dsa/README.md) | Algorithm patterns in Go and Python, linked to the real systems that use them |
| [math/](math/README.md) | Queueing, proofs and linear algebra, each checked against something real: Runway, a model checker, your own CPU |
| [open-source/](open-source/README.md) | How to read a real codebase and get a first change merged, with projects next to each phase |
| [system-design/](system-design/README.md) | A rubric, an interview script and designs by track, linked back to the code |
| [scripts/](scripts) | `test_all.sh` runs every check CI runs. `check_guides.py` rebuilds each guide's code from the guide itself and tests it |
| [notes/](notes) | Self-tests for each phase (`notes/learned/`), plus the author's decisions, failures and research track |

## Check everything locally

~~~bash
bash scripts/test_all.sh
~~~

This needs Go 1.26+, Python 3 with `uv`, `protoc`, and Rust for the later phases. RabbitMQ integration tests run when `RUNWAY_AMQP_URL` points at a broker; otherwise they're skipped.
