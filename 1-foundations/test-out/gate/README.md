# Gate: the test-out

## What it checks

See [the task](../README.md#the-gate). Your repository holds `tally/` (a Go module) and `report/` (a uv project with `report.py`). The gate works out every expected answer itself, in Python, from the same rules as the task, so it doesn't trust anything your code prints about itself. Every command it runs has a time limit.

## Run it

~~~bash
bash gate/run.sh ~/your-repo
~~~

It needs Go, uv, and GNU `time` on Linux (`sudo apt install -y time`; macOS has `/usr/bin/time`), and takes about 20 seconds.

## A pass looks like

~~~text
== tally/
PASS  gofmt
PASS  go vet
PASS  go test -race
PASS  a log with 14 kinds of malformed line, a 200 KB line, \r\n and no final newline
PASS  an empty input
PASS  5,000 lines
PASS  -path /api on the log with traps
PASS  -path /api/jobs on 5,000 lines
PASS  tally -nope: exit 2 with a message
PASS  tally -path: exit 2 with a message
PASS  tally extra-argument: exit 2 with a message
PASS  a million lines counted correctly
PASS  at most 64 MiB of memory for a 62 MiB log (it used 27 MiB)
== report/
PASS  ruff format
PASS  ruff check
PASS  pytest, without tally built
PASS  report.py on three logs: the table
PASS  report.py: the chart is a PNG image
PASS  report.py when tally fails: exit 1 with a message (report: empty.log: tally exited 1: tally: something went wrong)

Gate passed: start the core.
~~~

## A fail looks like

Reading all of standard input before parsing it:

~~~text
FAIL  at most 64 MiB of memory for a 62 MiB log
      it used 258248 KiB: read standard input line by line instead of all at once
~~~

`bufio.Scanner` with its default 64 KiB limit, which stops at the 200 KB line:

~~~text
FAIL  a log with 14 kinds of malformed line, a 200 KB line, \r\n and no final newline
      exit 1: tally: bufio.Scanner: token too long
~~~

Decoding `status` and `ms` as floats, which accepts `1.5` and `200.0`:

~~~text
FAIL  a log with 14 kinds of malformed line, a 200 KB line, \r\n and no final newline
      want {"lines": 302, "malformed": 28, "p50_ms": 940, "p99_ms": 1951, "status": {"200": 101, "201": 39, "204": 25, "301": 29, "404": 50, "500": 37, "503": 21}}
      got  {"lines": 304, "malformed": 26, "p50_ms": 934, "p99_ms": 1951, "status": {"200": 103, "201": 39, "204": 25, "301": 29, "404": 50, "500": 37, "503": 21}}
~~~

Ignoring extra arguments instead of rejecting them:

~~~text
FAIL  tally extra-argument: exit 2 with a message
      exit 0; stderr: 
~~~

`report.py` letting the exception escape when `tally` fails:

~~~text
FAIL  report.py when tally fails: exit 1 with a one-line message, not a traceback
      exit 1
      ...
      RuntimeError: empty.log: tally exited 1: tally: something went wrong
~~~
