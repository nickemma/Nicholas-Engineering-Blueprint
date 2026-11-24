# Test-out: skip the Foundations

> For developers who already program · Time: 3 hours, timed by you · Status: ready

If you already write code for a living, you don't need [Foundations](../../JOURNEY.md#foundations). This one task checks the things the core takes for granted. Pass it and start at [core 01](../../2-core/01-go-runtime-and-reliable-services/README.md). If it takes much longer than 3 hours, or a check fails and you can't see why, do the Foundations module that covers it: they're quick when the ideas are familiar.

Start a timer, read the task once, and build it in a new repository of your own. Search the documentation as you would at work. Stop the timer when the gate passes.

## The task: `tally`

Build two small programs in one repository, in two folders:

~~~text
your-repo/
  tally/     a Go module; `go build .` here builds the tally command
  report/    a uv project (Python 3.14) with report.py
~~~

### 1. `tally`, a Go command-line tool

`tally` reads JSON log lines on standard input, one object per line, such as:

~~~json
{"ts":"2026-11-18T09:00:01Z","status":200,"path":"/health","ms":3}
~~~

and prints one JSON object on standard output:

~~~json
{"lines":2,"status":{"200":1,"500":1},"p50_ms":5,"p99_ms":90,"malformed":1}
~~~

- **A line is valid** if it's a JSON object whose `status` is a whole number from 100 to 599 and whose `ms` is a whole number of 0 or more. `path`, if present, is a string; if it's missing, it counts as `""`. Other fields, such as `ts`, are ignored. Anything else is **malformed**: not JSON, not an object, an empty line, `status` or `ms` missing, `null`, a string, a boolean, a fraction or out of range, or a `path` that isn't a string.
- `lines` counts the valid lines; `status` maps each status code, as a string, to how many valid lines had it; `malformed` counts the malformed lines, which are skipped, never fatal.
- `p50_ms` and `p99_ms` are percentiles of `ms` over the valid lines, by the **nearest-rank** method: sort the values and take the one at position ⌈p/100 × n⌉, counting from 1. With no valid lines, both are `null`.
- `-path PREFIX` counts only valid lines whose `path` starts with `PREFIX`; the others are left out of `lines`, `status` and the percentiles. Malformed lines are counted whatever their path.
- A line may be up to 1 MiB long. The last line may or may not end with a newline, and a line may end with `\r\n`.
- It exits 0 on success, and 2 with a message on standard error for a bad flag, a missing flag value, or any argument (it only reads standard input).
- **It streams its input:** a log much bigger than memory must work. Only the numbers it needs are kept, never the lines.
- It has table-driven tests that include malformed lines and an empty input.

### 2. `report.py`, a Python script

~~~bash
uv run report.py FOLDER --tally PATH_TO_TALLY [--png status.png]
~~~

- For each file ending in `.log` in `FOLDER`, in name order, it runs `tally` with the file as standard input (with `subprocess`), and reads its JSON.
- It prints a table: a header row, then one row per file, with columns separated by spaces:

  ~~~text
  file          lines  malformed  p50_ms  p99_ms
  a.log             2          1       5      90
  empty.log         0          0       -       -
  ~~~

  A `null` percentile is printed as `-`. The column widths are up to you.
- It saves a bar chart of the status counts for each file as a PNG, to `--png` (default `status.png`).
- If `tally` exits with anything but 0, `report.py` prints one line on standard error saying which file and why, and exits 1. Never a traceback.
- It has `pytest` tests that run without `tally` being built: they fake its output.

## The gate

~~~bash
bash gate/run.sh /path/to/your-repo
~~~

It needs Go, uv, and GNU `time` on Linux (`sudo apt install -y time`; macOS has `/usr/bin/time` already), and takes about 20 seconds. It builds and runs both programs against inputs you haven't seen:

1. `tally`'s output equals an answer worked out independently, on a log with 14 kinds of malformed line, a 200 KB line, a `\r\n` line and no final newline; on an empty input; on 5,000 random lines; and with `-path` on both.
2. On a one-million-line log (62 MiB), `tally` gives the right answer within 64 MiB of memory, which only a streaming design manages.
3. A bad flag, a missing flag value and an extra argument each exit with 2 and a message.
4. `report.py` prints the right table for three logs and a valid PNG, skips a file that isn't `.log`, and handles a failing `tally` with one line and exit code 1.
5. `gofmt`, `go vet`, `go test -race` (with at least one test), `ruff format --check`, `ruff check` and `pytest` are clean.

The [gate's page](gate/README.md) shows a pass and each kind of fail.

## What it covers, and where Foundations teaches it

| Part of the task | Foundations module |
|---|---|
| Standard input and output, exit codes, flags | [02 How the machine works](../02-how-the-machine-works/README.md) |
| Go: errors, table-driven tests, JSON, streaming a large input with `bufio.Scanner` | [03 Go from zero](../03-go-from-zero/README.md) |
| Python with uv: files, exceptions, `pytest`, percentiles, a chart | [04 Python and the internet from zero](../04-python-and-the-internet-from-zero/README.md) |
| Running another program from Python (`subprocess`) | Not taught in Foundations; see the [`subprocess` documentation](https://docs.python.org/3/library/subprocess.html) |

The test-out doesn't check networking. The core assumes you know what an IP address, a port, DNS, a TCP connection and an HTTP request are. If any of those is hazy, read lessons 01–05 of [Foundations 04](../04-python-and-the-internet-from-zero/README.md) before core 01: they take about a day.

---

<sub>The gate's runs against a reference solution and against broken versions are in [evidence/](evidence/README.md). The reference solution itself isn't published.</sub>
