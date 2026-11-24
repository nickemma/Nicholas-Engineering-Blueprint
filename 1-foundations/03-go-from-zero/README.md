# 03 Go from zero

> Foundations · Time: 3 weeks at 12–15 hours a week · Builds on: [02 How the machine works](../02-how-the-machine-works/README.md) · Status: ready

## What you'll learn

Go, from the first variable to running work concurrently, each idea in small drills before it's used in a build. Every lesson shows what Go does underneath: where a value lives in memory, what a slice really is, what happens when a goroutine blocks.

## What you'll build

A **command-line task engine** that stores tasks in a JSON file, and a **JSON log analyser** that streams a large log and reports on it, using several goroutines.

## Lessons

| # | Lesson | What it teaches | Time |
|---|---|---|---|
| 01 | [Values, types and variables](lessons/01-values-types-and-variables.md) | `int`, `float64`, `bool`, `string`; declarations and zero values; constants; how big each type is in memory; `go run`, `go build` and `go vet` | ~3 h |
| 02 | [Control flow and functions](lessons/02-control-flow-and-functions.md) | `if`, `for`, `switch`; functions with several results; scope | ~3 h |
| 03 | [Errors as values](lessons/03-errors-as-values.md) | The `error` type; returning and checking errors; wrapping with `%w`; why Go has no exceptions | ~3 h |
| 04 | [Slices and maps](lessons/04-slices-and-maps.md) | Arrays vs slices; the backing array, length and capacity; how `append` grows; maps, and why their order is random | ~4 h |
| 05 | [Structs, methods and pointers](lessons/05-structs-methods-and-pointers.md) | Structs; methods; value vs pointer receivers; drawing what's copied and what's shared | ~4 h |
| 06 | [Interfaces](lessons/06-interfaces.md) | Satisfying an interface without declaring it; `io.Reader` and `io.Writer`; small interfaces | ~3 h |
| 07 | [Tests](lessons/07-tests.md) | `go test`; table-driven tests; reading a failure; test coverage | ~3 h |
| 08 | [Packages, files and JSON](lessons/08-packages-files-and-json.md) | Modules and packages; command-line arguments and flags; reading and writing files; `encoding/json`. Build: the task engine (`add`, `list`, `done`) | ~5 h |
| 09 | [Goroutines and channels](lessons/09-goroutines-and-channels.md) | Starting goroutines; `sync.WaitGroup`; unbuffered and buffered channels; closing a channel | ~4 h |
| 10 | [`select`, timeouts and the race detector](lessons/10-select-timeouts-and-the-race-detector.md) | `select`; timeouts with `time.After`; a data race made on purpose, caught by `-race`, fixed with a mutex | ~4 h |
| 11 | [Streaming a large log](lessons/11-streaming-a-large-log.md) | `bufio.Scanner` instead of reading the whole file; malformed lines counted, not fatal; a pool of goroutines sharing the parsing. Build: the log analyser | ~5 h |

## The gate

`gate/run.sh` runs your two programs against inputs you haven't seen:

1. **Task engine:** a scripted session of `add`, `list` and `done` commands produces exactly the expected output, and the JSON file survives being reopened.
2. **Log analyser:** on a log with malformed lines, it reports the right counts and lists the bad lines instead of crashing. On a one-million-line log, it finishes within a memory limit that only a streaming design meets.
3. `gofmt`, `go vet` and `go test -race` are clean on both.

The [gate's page](gate/README.md) shows a pass and each kind of fail.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Write a small Go program with tests and handle every error |
| Intermediate | Explain why appending to a slice can change another slice, and find a data race with `-race` |
| Senior | Choose between a channel and a mutex for a given problem, and say what each costs |

## Practice

- [Exercises](exercises.md): `uniqcount`, a streaming `sort | uniq -c` in Go, and `urlcheck`, which checks many URLs at once with a deadline.
- [Self-check](self-check.md): explain-it questions per lesson, then a test from memory.

## Next

[04 Python and the internet from zero](../04-python-and-the-internet-from-zero/README.md): how a message crosses a network, and your second language.

---

<sub>The raw runs behind this module's outputs and its gate are in [evidence/](evidence/README.md). You don't need them to follow the lessons.</sub>
