# Test-out · Self-check

## Before you start the clock

If you can't answer one of these without looking it up, read the lesson next to it first. It's quicker than discovering the gap at hour two.

| Question | Where Foundations teaches it |
|---|---|
| What are standard input, output and error, and what does an exit code of 2 conventionally mean? | [Foundations 02](../02-how-the-machine-works/README.md) |
| Why does reading a whole file into memory fail on a log bigger than RAM, and what does `bufio.Scanner` do instead? What happens to a line longer than its buffer? | [Foundations 03, lesson 11](../03-go-from-zero/lessons/11-streaming-a-large-log.md) |
| How does Go's `encoding/json` tell a missing field from a zero, and what does it do with `1.5` for an `int` field? | [Foundations 03, lessons 08 and 11](../03-go-from-zero/lessons/11-streaming-a-large-log.md) |
| What is a table-driven test, and how do you add a case for empty input? | [Foundations 03, lesson 07](../03-go-from-zero/lessons/07-tests.md) |
| What is the nearest-rank percentile of `[5, 1, 90]` at p50 and at p99? | [Foundations 04, lesson 09](../04-python-and-the-internet-from-zero/lessons/09-1000-requests-and-a-latency-plot.md) |
| How do you create a uv project, add a dependency, and run `pytest`? | [Foundations 04](../04-python-and-the-internet-from-zero/README.md) |
| How do you run a program from Python, give it standard input, and read its exit code and standard error? | Not in Foundations: [Exercise 1](exercises.md#exercise-1-runall-run-a-command-over-many-files-from-python) |

## After the gate

Answer these whether you passed or not. They're what core 01 builds on.

1. Which check failed first, or which part took longest? What did you not know, and where is it taught?
2. How much memory did `tally` use on the million-line log, and why does that number not grow with the file?
3. Name three kinds of malformed line you handled only because the specification listed them. Which one would you have missed?
4. What does `report.py` do when `tally` fails, and why is one line on standard error better than a traceback for whoever runs it?
5. If you took much longer than 3 hours, which Foundations module would have saved the most time? Do it before core 01.
