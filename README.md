# The Blueprint

**Control planes in Go. Data planes in Rust.** A path to systems and infrastructure engineering roles, from your first program to a system you ship and benchmark yourself.

Everyone builds the same core: **Switchyard**, a Go control plane running a Rust data plane on Linux. You build it lesson by lesson, from a single Go service to your own Raft, a crash-safe Rust log, a zero-copy wire between the two languages, and the security and operations to ship it. Then you pick a domain and take its track:

| Track | You ship |
|---|---|
| **AI infrastructure** | An OpenAI-compatible inference gateway, benchmarked for time to first token and throughput |
| **Storage engines** | A distributed key-value store on your own LSM-tree engine, with crash-recovery proofs |
| **Cloud and network** | A programmable edge proxy with its own control plane, benchmarked against Envoy |

Every lesson is a type-along build: the code is inline and explained, every output shown was captured from a real run, and CI rebuilds the code from the lessons themselves. Every module ends with a **gate**, an automated check that breaks something and tests what must still hold. There are no solution folders: each module's exercises are separate projects you build alone, with a clear spec.

## Start here

1. Read **[JOURNEY.md](JOURNEY.md)**, the single map: what you'll build, how to study, and every module with its time, gate and status.
2. **New to programming?** Start with **[Foundations 01: set up your machine](1-foundations/01-set-up-your-machine/README.md)**. It assumes nothing.
   **Already a developer?** Take the test-out described in [JOURNEY.md](JOURNEY.md#1-who-this-is-for), then start the **[core](2-core/01-go-runtime-and-reliable-services/README.md)**.
3. Alongside the modules, start the **[DSA practice](dsa/README.md)** early, add **[system design](system-design/README.md)** from core 03, and the **[maths](math/README.md)** when a module needs it.
4. When you choose a track, read **[career.md](career.md)**: the experience you'll have, the roles to target, and where they're hiring.

## Repository map

| Folder | What it holds |
|---|---|
| [1-foundations/](1-foundations) | For beginners: your machine, how computers work, Go from zero, Python and the internet from zero |
| [2-core/](2-core) | For everyone: eight modules that build Switchyard, plus optional deep dives |
| [3-tracks/](3-tracks) | Three tracks, each ending in its capstone, and the shared units they draw on |
| [dsa/](dsa/README.md) | Algorithm patterns in Go and Python, linked to the real systems that use them |
| [system-design/](system-design/README.md) | A rubric, an interview script and designs by track, linked back to the code |
| [math/](math/README.md) | Queueing, proofs and linear algebra, each checked against something real |
| [ownership/](ownership/README.md) | Incident triage, mitigation, handoff, and postmortem practice |
| [career.md](career.md) | Roles, companies in Canada and the USA, job boards, interview preparation |
| [scripts/](scripts) | `check_all.sh` runs every check CI runs. `replay_lessons.py` rebuilds each lesson's code from the lesson itself and tests it; `check_links.py` checks every relative link |

Every module folder has the same files: a `README.md` module page, `lessons/` (one file per lesson), `gate/`, `exercises.md` and `self-check.md`. Its `evidence/` folder holds the raw runs behind the outputs the lessons show; you don't need it to learn.

## Check everything locally

~~~bash
bash scripts/check_all.sh
~~~

This needs Go 1.26+, Python 3 with `uv`, `protoc`, and Rust. The lessons that use PostgreSQL, Redis, Kafka, RabbitMQ or OpenBao expect them running, as in CI ([.github/workflows/lessons.yml](.github/workflows/lessons.yml)); RabbitMQ integration tests are skipped unless `RUNWAY_AMQP_URL` points at a broker.
