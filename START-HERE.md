# Start here

**A 49-week apprenticeship in distributed systems and AI infrastructure — taught from zero, built in public, and documented including the parts that broke.**

Nineteen stages. Roughly 196 lessons. Twenty hours a week. Everything published.

The goal is not completed courses. It's this: by the end, be able to **design, implement, secure, operate, and explain** a production-grade distributed AI infrastructure system.

---

## What this repository actually is

Not a tutorial series, and not a code dump. It's the working record of one engineer learning this properly — with the failures left in.

Every lesson here follows the same shape: the idea in plain English first, then the mental model, then the real terminology, then a tiny Go example, then something you build, then something that breaks it deliberately, then an explanation in my own words. That last part is the gate. If the "explaining it back" section of a lesson is thin, the lesson wasn't finished.

Most learning repos show you what someone was exposed to. This one is designed to show what was actually understood — which is a much harder thing to fake, and a much more useful thing to read.

---

## If you want to…

| | Go to |
|---|---|
| See where I am right now | [`PROGRESS.md`](PROGRESS.md) |
| See the whole plan | [`docs/curriculum-tree.md`](docs/curriculum-tree.md) |
| Understand how it's taught | [`docs/how-this-works.md`](docs/how-this-works.md) |
| Learn one specific thing | [`stages/`](stages) — every stage folder is self-contained |
| See what went wrong | any stage's `breaks/` folder |
| See the numbers | any stage's `experiments/` folder — hardware always named |
| Know why I'm doing this | [`docs/part-1-vision.md`](docs/vision.md) |

**If you're starting from scratch:** open [`stages/s01-how-a-computer-runs-your-code/README.md`](stages/s01-how-a-computer-runs-your-code). It assumes nothing — not Go, not Linux, not systems knowledge. Lesson 1 begins with what a program actually is.

---

## The nineteen stages

Each stage is a question. You don't leave a stage until you can answer its question in your own words and point at something running.

```
ONE MACHINE
  S1  How does a computer run your code?
  S2  How does an operating system keep programs from destroying each other?
  S3  How do two machines talk?
  S4  How does one machine serve many users reliably?

RUNNING THINGS
  S5  How do you package and place software on machines?
  S6  What is a model, and what does serving one actually require?

DATA THAT SURVIVES
  S7  How does a database not lose your data when the power cuts?
  S8  What breaks when one machine becomes many?
  S9  How do machines that disagree reach a decision?
  S10 How do you split data across machines and still be correct?

OPERATING AT SCALE
  S11 How do you run a stateful distributed system in production?
  S12 How do you know it's healthy, and what do you do at 3am?
  S13 How do you keep attackers out of all of it?

AI INFRASTRUCTURE
  S14 What is actually happening inside a model?
  S15 Why is serving an LLM different from serving an API?
  S16 What changes when the model doesn't fit on one GPU?
  S17 How do you turn that into a multi-tenant platform with an economy?
  S18 How do you secure a platform whose workload can be manipulated by input?

PROVING IT
  S19 Can you design one from scratch and defend it?
```

---

## Following along and building it yourself

Every lesson contains the exact commands and the full code. You can do this alongside me.

```bash
git clone https://github.com/nickemma/Nicholas-Engineering-Blueprint
cd Nicholas-Engineering-Blueprint/stages/s01-how-a-computer-runs-your-code
open README.md
```

**What you need:** a terminal, Go installed, git. That's the whole prerequisite list for Stage 1. Later stages add Docker, a Kubernetes cluster you can run locally with `kind`, and — from Stage 15 — a few hours of rented GPU time.

**A suggestion if you're following seriously:** don't skip the `breaks/` files. Reading how something failed teaches more than reading how it was built. That's true here and it's true of the field.

---

## What "done" means here

A lesson is done when it can be explained back. A stage is done when its exit assessment is answered honestly and its project has survived a failure day. Nothing advances because time passed.

That means progress here is slower than a course and slower than a tutorial playlist. It's supposed to be.

---

## Some ground rules I hold myself to

- **Every benchmark names its hardware.** A number without a machine is a rumour.
- **Every root cause is a decision, not an event.** "Disk filled" is an event. "No log rotation and no disk alert" is a cause.
- **Failures get published.** Especially the embarrassing ones.
- **Nothing is claimed as production that isn't.** The systems built here are production-*shaped*. Where something is genuinely running for real users, it's labelled as such.

---

## Questions, corrections, and disagreement

Open an issue. If I've explained something wrong, I'd rather find out from you than from an interviewer. Corrections get credited in the lesson file.

---

[Website](https://techieemma.vercel.app) · [GitHub](https://github.com/nickemma) · [LinkedIn](https://linkedin.com/in/techieemma) · [Medium](https://techieemma.medium.com) · [X](https://twitter.com/techieemma)
