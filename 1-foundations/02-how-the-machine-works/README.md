# 02 How the machine works

> Foundations · Time: 2 weeks at 12–15 hours a week · Builds on: [01 Set up your machine](../01-set-up-your-machine/README.md) · Status: ready

## What you'll learn

- The shell: commands, paths, pipes and redirection, and how to script them.
- Files and permissions: who may read, write and run what, and why.
- How a computer stores data: bits and bytes, binary and hex, text as numbers, and how much slower each step from CPU to RAM to disk is.
- Programs and processes: the difference, process IDs, signals, exit codes, and standard input, output and error.
- Git: commits, history, branches, and undoing mistakes.

## What you'll build

A **system monitor** in shell that reports load, memory and disk use from what the kernel publishes, and a **log rotator** that rotates a log while a program is still writing to it, without losing a line.

## Lessons

| # | Lesson | What it teaches | Time |
|---|---|---|---|
| 01 | [The terminal and the shell](lessons/01-the-terminal-and-the-shell.md) | Commands, flags and arguments; absolute and relative paths; `ls`, `cd`, `mkdir`, `cat`, `less`; pipes and redirection; getting help with `man` | ~3 h |
| 02 | [Files and permissions](lessons/02-files-and-permissions.md) | Users and groups; read, write and execute bits; `chmod`, `chown`; why `sudo` exists and when not to use it; hidden files and `$HOME` | ~3 h |
| 03 | [How a computer stores data](lessons/03-how-a-computer-stores-data.md) | Bits, bytes, binary and hex; integers and their limits; text as numbers (ASCII, UTF-8); looking at raw bytes with `xxd`; CPU caches, RAM and disk, and how far apart their speeds are | ~4 h |
| 04 | [Programs and processes](lessons/04-programs-and-processes.md) | A program on disk vs a running process; `ps`, `top` and `/proc`; process IDs; signals and `kill`; exit codes; standard input, output and error | ~4 h |
| 05 | [Shell scripts](lessons/05-shell-scripts.md) | Variables, `if`, loops and functions; `set -euo pipefail`; checking exit codes; `shellcheck`. Build: the system monitor, reading `/proc/loadavg`, `/proc/meminfo` and `df` | ~4 h |
| 06 | [Git](lessons/06-git.md) | Repositories, commits, `log` and `diff`; branches and merging; `.gitignore`; undoing a commit safely. Put the monitor under version control | ~3 h |
| 07 | [Rotating a log without losing a line](lessons/07-rotating-a-log-without-losing-a-line.md) | The problem: copying a log then truncating it loses whatever the writer adds in between. The fix: rename the file, signal the writer to reopen, and compress the old file later. Build: the log rotator | ~4 h |

**Absorbs** the old Phase 0 Step 0 (the terminal) and the program-versus-process half of Step 1.

## The gate

`gate/run.sh` runs your two scripts:

1. **Monitor:** its load, memory and disk figures match what `/proc` and `df` report at the same moment, within a small tolerance.
2. **Rotator:** a test writer appends numbered lines nonstop while the rotator runs ten times. Afterwards every number appears exactly once across the live log and the archives (none lost, none duplicated), and exactly the configured number of archives is kept.
3. Both scripts pass `shellcheck` with no warnings.

The [gate's page](gate/README.md) shows a pass and each kind of fail.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Write a script that stops on the first error and says why |
| Intermediate | Explain why copy-then-truncate loses lines, and what a process sees when its file is renamed underneath it |
| Senior | Read an unfamiliar process's state from `/proc` alone, and reason about file descriptors and signals during an incident |

## Practice

- [Exercises](exercises.md): `diskwatch`, a disk-space alarm, and `whoisusing`, which finds the processes holding a file open.
- [Self-check](self-check.md): explain-it questions per lesson, then a test from memory.

## Next

[03 Go from zero](../03-go-from-zero/README.md): your first real programming language, from variables to goroutines.

---

<sub>The raw runs behind this module's outputs and its gate are in [evidence/](evidence/README.md). You don't need them to follow the lessons.</sub>
