# Repository Structure

**Where every artifact of this apprenticeship lives, and why.**

*Companion to [The Flagship Charter Standard](charter-standard.md)*

*Destination: the root of [The Nicholas Emmanuel Engineering Blueprint](../../README.md)*

---

## Design rules

Four rules decided this structure. Everything else follows from them.

1. **A stage is a folder.** Nineteen stages, nineteen folders. Anyone can open one and get the whole unit — what it teaches, the lessons, the code, the measurements, the failures, the reflection.
2. **Thinking lives here, flagship code lives elsewhere.** Stage labs are small and stay in this repo. `tessera` and `lattice` get their own repos; this repo holds their design artifacts and links out.
3. **A follower must be able to repeat a lesson.** Every lesson file contains enough to redo it independently: the explanation, the exact commands, the code, what broke, what fixed it. If a lesson can't be repeated by a stranger, it isn't finished.
4. **Nothing is written in advance.** Stage folders are created when the stage begins. Nineteen folders of empty stubs is noise; it also lies about progress.

---

## Top level

```text
Nicholas-Engineering-Blueprint/
├─ README.md                  # front door: identity, progress dashboard, navigation
├─ START-HERE.md              # for followers: what this is, how to follow, where to begin
├─ PROGRESS.md                # the POSITION block + stage bars + failure log
├─ DEBT.md                    # skipped, deferred, half-understood — reviewed at stage exit
├─ CHANGELOG.md               # this handbook's own version history
│
├─ docs/
│   ├─ vision.md            # identity, why this path, outcomes, metrics
│   ├─ learning-system.md   # the cycle, cadence, standards, writing, reading
│   ├─ curriculum-tree.md          # the 19 stages, the full map
│   └─ how-this-works.md           # the teaching contract
│
├─ stages/
│   ├─ s01-how-a-computer-runs-your-code/
│   ├─ s02-how-the-os-keeps-programs-apart/
│   └─ …  s19-design-defence/
│
├─ flagships/                 # design artifacts only — code is in its own repo
│   ├─ tessera/
│   └─ lattice/
│   └─ synapse-ai/
│
├─ interview-track/
│   ├─ dsa/                   # one file per pattern, not per problem
│   └─ system-design/         # one file per written design, timed
│
├─ weekly-reviews/            # week-01.md … week-49.md — the Sunday audit trail
├─ reading-list/               # one per paper, one per book, one per blog post
```

---

## Inside a stage — the important part

Using Stage 1 as the worked example. Every stage folder has the same seven children, so followers learn the shape once.

```text
stages/s01-how-a-computer-runs-your-code/
│
├─ README.md              # the stage front door — standalone, readable by a stranger
├─ PROGRESS.md            # this stage's bar, lesson checklist, and log
│
├─ lessons/               # one file per lesson — the teaching, written up
│   ├─ l01-what-a-program-is.md
│   ├─ l02-memory.md
│   ├─ l03-cpu-and-cache.md
│   ├─ l04-the-kernel.md
│   ├─ l05-processes-and-signals.md
│   ├─ l06-files-and-descriptors.md
│   ├─ l07-go-shape-of-a-program.md
│   ├─ l08-go-data-and-pointers.md
│   ├─ l09-go-interfaces.md
│   ├─ l10-goroutines-and-scheduler.md
│   ├─ l11-channels-select-context.md
│   ├─ l12-mutexes-races-atomics.md
│   ├─ l13-memory-and-gc.md
│   ├─ l14-debugging.md
│   ├─ l15-stage-project.md
│   └─ l16-failure-day.md
│
├─ labs/                  # code written during a lesson — one dir per lesson
│   ├─ l05-signals/
│   │   ├─ go.mod
│   │   ├─ main.go
│   │   └─ NOTES.md       # what this proves, how to run it
│   ├─ l08-pointers/
│   └─ l12-races/
│
├─ experiments/           # measurements — the run, the raw output, the conclusion
│   ├─ l03-cache-locality/
│   │   ├─ run.sh
│   │   ├─ raw-output.txt
│   │   └─ results.md     # hardware named, numbers, what it means
│   └─ l13-goroutine-leak/
│
├─ breaks/                # failure days — what was injected, diagnosis, fix
│   └─ l16-failure-day.md
│
├─ project/               # the stage deliverable, buildable on its own
│   ├─ README.md
│   ├─ cmd/ internal/ deploy/
│   └─ BENCHMARKS.md
│
├─ reflections/           # the four questions
│   └─ stage-01-reflection.md
│
└─ assessment.md          # the exit questions + my answers, scored honestly
```

### What each child is for

| Folder | Holds | Test for "is it done" |
|---|---|---|
| `README.md` | What you'll learn · what it's for · prerequisites · the lesson list · what you build · done-when | A stranger reads it and knows whether this stage is for them |
| `lessons/` | The teaching, written up after each session | Someone could learn the lesson from the file alone |
| `labs/` | Small code from individual lessons | `go run .` works from a clean clone |
| `experiments/` | Things you measured | Hardware named, command included, result reproducible |
| `breaks/` | Failures injected and diagnosed | Root cause is a decision, not an event |
| `project/` | The stage deliverable | Runs, has a README, survived the failure day |
| `reflections/` | The four questions | Question 4 is specific enough to build from |
| `assessment.md` | Exit questions and your answers | Any shaky answer names the lesson being re-taught |

---

## The lesson file — anatomy

This is the artifact followers will actually read. Same nine sections every time, mapping to the teaching cycle.

```markdown
---
stage: 1
lesson: 4
title: The kernel — the referee
type: [concept, experiment]
duration: 3h
date: 2026-08-18
status: complete
prev: l03-cpu-and-cache
next: l05-processes-and-signals
---

# S1 · L4 — The kernel, the referee

> **Position** — Stage 1 of 19 · Lesson 4 of 16
> Previous: the CPU and cache · Next: processes and signals

## The question
<The one question this lesson answers. One sentence.>

## In plain English
<No jargon. The idea as you'd explain it to someone who has never
programmed. This section is the one that makes the rest land.>

## The mental model
<The analogy, and a diagram if it helps. Something you can hold.>

## The real terminology
<Now the words: user space, kernel space, system call, ring 0.
Each attached to something from the two sections above.>

## The tiny example
<10–30 lines of Go. Runnable. What to notice, not line-by-line.>

## What I built
<Exact files and commands. Expected output. What went wrong first.>

## How we broke it
<The failure injected, what it looked like, how I diagnosed it.>

## Explaining it back
<My own words, unedited. This is the gate — if this section is thin,
the lesson isn't finished.>

## Links
<Lab dir · experiment dir · the paper or chapter · the real system
this maps to (Docker, etcd, vLLM…)>
```

The `Explaining it back` section is why the whole file exists. It's also the section that makes this repo different from every other "my learning journey" repo — it's evidence of understanding rather than evidence of exposure.

---

## Naming conventions

| Thing | Convention | Example |
|---|---|---|
| Stage folder | `sNN-<the question, kebab-case>` | `s09-machines-that-disagree` |
| Lesson file | `lNN-<topic>.md` | `l12-mutexes-races-atomics.md` |
| Lab dir | `lNN-<topic>/` | `l12-races/` |
| Experiment dir | `lNN-<what-was-measured>/` | `l03-cache-locality/` |
| Weekly review | `week-NN.md` | `week-07.md` |
| Reading log | `YYYY-<author>-<short-title>.md` | `2026-lamport-time-clocks.md` |
| Commit | `sNN/lNN: <what changed>` | `s01/l12: fix race in worker pool` |

Zero-pad everything. `s01` sorts correctly, `s1` does not. Dates live in frontmatter, never in filenames — a file named for its date is unreadable a year later.

---

## Flagship folders

Copy `templates/repo-skeleton/` at every kickoff.

```text
flagships/tessera/
├─ README.md            # what it is + link to the code repo
├─ RPD.md               # problem, goal, users, stories, acceptance criteria
├─ DESIGN_DOC.md
├─ ADR/                 # 0001-….md — one decision each
├─ THREAT_MODEL.md
├─ BENCHMARKS.md        # every number, with the hardware
├─ RUNBOOK.md
├─ INCIDENTS.md         # from S6 onward — it's running continuously
└─ diagrams/
```

Bidirectional linking: the flagship repo's README links back to this folder; this folder links out to the code. The link graph is what makes the repos read as one story.

---

## What followers see

You have an audience, so the repo has to work for two readers at once — you, mid-stage, and a stranger arriving at week 30.

**`START-HERE.md`** is the stranger's entry point:

```markdown
# Start here

What this is: a 49-week apprenticeship in distributed systems and AI
infrastructure, taught from zero and built in public. 19 stages, ~196
lessons, everything published — including what broke.

If you want to…
- see where I am now          → PROGRESS.md
- see the whole plan          → docs/curriculum-tree.md
- understand how it's taught  → docs/how-this-works.md
- learn something specific    → stages/ — each folder is self-contained
- follow along and build too  → each lesson has the exact commands. Fork it.
- see what went wrong         → every stage's breaks/ folder

Start at stages/s01-…/README.md. It assumes nothing.
```

**The README dashboard** shows the six layers with live status, so a returning follower sees movement without reading anything.

**One rule for the public repo:** publish the failures. Every `breaks/` file and every honest assessment answer is worth more to a follower — and to a hiring manager — than a clean commit history. The repos that get shared are the ones that admit what didn't work.

---

## Cadence — what gets committed, when

| When | What lands |
|---|---|
| End of each lesson | `lessons/lNN-*.md`, its lab dir, its experiment dir |
| End of each failure day | `breaks/lNN-*.md`, a row in `PROGRESS.md`'s failure table |
| End of each stage | `reflections/`, `assessment.md`, updated stage `README.md` and `PROGRESS.md`, `DEBT.md` reviewed |
| Every Sunday | `weekly-reviews/week-NN.md` |
| Every month | one published piece, linked from the README |

Forty-nine consecutive Sunday commits is a contribution graph that shows consistency instead of claiming it.

---

## Bootstrapping Stage 1

```bash
cd ~/dev/blueprint
mkdir -p stages/s01-how-a-computer-runs-your-code/{lessons,labs,experiments,breaks,project,reflections}
mkdir -p docs templates weekly-reviews interview-track/{dsa,system-design} flagships
touch PROGRESS.md DEBT.md START-HERE.md CHANGELOG.md
touch stages/s01-how-a-computer-runs-your-code/{README.md,PROGRESS.md,assessment.md}
```

Nothing for stages 2–19 yet. They get created the week they start.
