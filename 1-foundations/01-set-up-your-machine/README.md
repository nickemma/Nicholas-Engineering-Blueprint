# 01 Set up your machine

> Foundations · Time: about 45 minutes · Builds on: nothing, start here · Status: ready

## What you'll learn

- Why real servers run Linux, and how to get a Linux shell on Windows (WSL2 with Ubuntu), macOS or Linux.
- What Git is for, and how to configure it once.
- How to install Go and check that it works.
- How to set up VS Code so it edits and runs code inside Linux.

## What you'll build

Your first program: it prints your operating system, CPU architecture and number of CPUs. You'll understand every line of it by the end of [Go from zero](../03-go-from-zero/README.md); today it proves your machine is ready.

## Lessons

| # | Lesson | What it teaches | Time |
|---|---|---|---|
| 01 | [From a new laptop to a running program](lessons/01-from-a-new-laptop-to-a-running-program.md) | Five steps, each with tabs for Windows, macOS and Linux: a Linux environment, Git, Go, the editor, and the first program. Each step ends with one command that proves it worked | ~45 min |

Every install step is **Run locally**: CI can't install an operating system. The Linux and WSL2 outputs are captured from real runs; the macOS steps are written from Apple's and Homebrew's own instructions, with the output you should see.

## The gate

`gate/run.sh` checks your machine, not your knowledge:

1. `go version` reports Go 1.26 or newer.
2. `git config user.name` and `user.email` are set.
3. Your first program builds and prints `OS: <os> | Arch: <arch> | CPUs: <n>`, and the values match what the machine reports (`uname -s`, `uname -m`, `nproc`).
4. On Windows, the program runs inside WSL2, not in a Windows folder (`/mnt/c/...`), which would make every later module slow.

The [gate's page](gate/README.md) shows a pass and each kind of fail.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Follow the steps and pass the gate |
| Intermediate | Explain why the course runs on Linux, and why code lives inside WSL's file system rather than `C:\` |
| Senior | Set up a second machine from memory, and fix a broken `PATH` without the lesson |

## Practice

- [Exercises](exercises.md): set up a second machine from your own notes.
- [Self-check](self-check.md): explain-it questions, then a test from memory.

## Next

[02 How the machine works](../02-how-the-machine-works/README.md): what the shell, the files and the processes you just used really are.

---

<sub>The raw runs behind this module's outputs and its gate are in [evidence/](evidence/README.md). You don't need them to follow the lessons.</sub>
