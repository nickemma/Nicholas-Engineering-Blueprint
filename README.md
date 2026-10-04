# Nicholas Engineering Blueprint

A complete, beginner-to-advanced path through systems engineering. You learn it by building one real system: **KESTREL**, a research prototype that lets small health organisations share approved summaries while keeping their records local and working through unreliable networks.

Every phase is taught end to end. Each lesson gives you the full code, the exact commands, real expected output, a deliberate way to break it, and tests. Interview practice runs alongside: data structures and algorithms, and system design for infrastructure, distributed systems, platform and ML roles.

## Start here

1. Read **[JOURNEY.md](JOURNEY.md)**, the single map: what you'll build, the route, the gaps each phase closes, the patterns you'll use, and which roles each phase prepares you for.
2. Begin **[Phase 0](lessons/00-request-service/README.md)**. It assumes no prior Go, Linux or HTTP.
3. Start the **[DSA track](dsa/README.md)** at the same time. Add the **[system-design track](system-design/README.md)** at Phase 2.

## Repository map

| Folder | What it holds |
|---|---|
| [lessons/](lessons) | One folder per phase: a syllabus, a type-along guide, an exercise project and an answer sheet |
| [dsa/](dsa/README.md) | Algorithm patterns in Go and Python, linked to the real systems that use them |
| [system-design/](system-design/README.md) | A rubric, an interview script and designs by track, linked back to the code |
| [scripts/](scripts) | `test_all.sh` runs every check CI runs. `check_guides.py` rebuilds each guide's code from the guide itself and tests it |
| [notes/](notes) | Self-tests for each phase (`notes/learned/`), plus the author's decisions, failures and research track |

## Check everything locally

~~~bash
bash scripts/test_all.sh
~~~

This needs Go 1.26+ and Python 3. It verifies that every code block in the lessons matches its step files, then formats, vets and tests every step.

## Scope

KESTREL uses **synthetic or public data only**. It is a learning and research prototype, not a clinical system. It makes no diagnoses and claims no legal compliance. See [JOURNEY.md §2](JOURNEY.md#2-what-were-building-and-why).
