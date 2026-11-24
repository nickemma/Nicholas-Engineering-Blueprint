# Gate: Python and the internet from zero

## What it checks

Your folder is `~/blueprint/internet`, with your Go echo server in `echo/` (lesson 04) and your uv project in `measure/` with `measure.py` (lesson 09).

**The echo server.** The gate builds it and starts it with `-addr 127.0.0.1:0 -idle 3s`, and reads the port from its `listening on` line. Then:

1. `gofmt`, `go vet` and `go test -race` are clean.
2. One client connects and says nothing. While it's connected, 100 more connect at once, each sending 5–24 lines of random lengths (up to 64 KiB) and random bytes, some ending `\r\n`, some with a last line that has no newline. Each must get back exactly the bytes it sent, within 2.5 seconds.
3. A line of exactly 65,536 bytes, newline included, comes back whole.
4. A longer line gets `error: line longer than 65536 bytes` and then the connection closes, and the message must arrive (not a reset).
5. The silent client is disconnected after the 3-second idle limit.
6. The server is still running and still echoes.

**The measurement script.**

1. `ruff format --check`, `ruff check` and `pytest` are clean.
2. `uv run measure.py --port PORT` against your server: `results.csv` has the header `request,connection,bytes,latency_ms`, requests 0 to 999 once each, the sizes 16, 256, 4096 and 16384 bytes in turn, and 10 connections. The `p50` and `p99` lines it prints must equal the gate's own nearest-rank calculation from your CSV, to the thousandth of a millisecond.
3. The plot is a PNG image.
4. Against the gate's own server, which sends each reply in two pieces 20 ms apart: 40 requests over 4 connections succeed, and no latency is under 20 ms.
5. Against a server that replies with the wrong line, and against a port where nothing listens, it exits with 1 and a one-line message on standard error, not a traceback.

Every command it runs has a time limit, so a server or script that hangs fails instead of hanging the gate.

## Run it

~~~bash
bash gate/run.sh ~/blueprint/internet
~~~

It needs Go and uv, and takes about 15 seconds.

## A pass looks like

~~~text
== echo/
PASS  gofmt
PASS  go vet
PASS  go test -race
PASS  the server starts and prints 'listening on 127.0.0.1:43019'
PASS  100 clients at once get back exactly what they sent (14,009,678 bytes)
PASS  a line of exactly 65,536 bytes (newline included) comes back whole
PASS  a longer line gets the error, then the connection closes
PASS  a quiet client is disconnected after -idle 3s
PASS  the server is still running afterwards
== measure/
PASS  ruff format
PASS  ruff check
PASS  pytest
PASS  1,000 requests over 10 connections: results.csv has every request
PASS  the p50 and p99 it prints match the CSV
PASS  the plot is a PNG image
PASS  replies that arrive in two pieces are read whole and timed to the end
PASS  a wrong reply: exit 1 with a message (measure: request 0: sent 16 bytes, got back b'not what you sent\n')
PASS  nothing listening: exit 1 with a message (measure: [Errno 111] Connect call failed ('127.0.0.1', 48091))

Gate passed: on to the core.
~~~

## A fail looks like

One connection at a time (`handle(conn)` without `go`). The lesson's own test catches it too:

~~~text
FAIL  go test -race
          main_test.go:135: client 35 line 0: got 0 bytes (read tcp 127.0.0.1:56814->127.0.0.1:41717: i/o timeout), want 1
          main_test.go:135: client 40 line 0: got 0 bytes (read tcp 127.0.0.1:56982->127.0.0.1:41717: i/o timeout), want 1
          ...
      FAIL
      FAIL	echo	2.155s
      FAIL
FAIL  100 clients at once get back exactly what they sent
      not finished after 2.5 s, while one quiet client was connected:
      does one connection hold up the others?
~~~

Closing straight after the error message, without the lingering close:

~~~text
FAIL  go test -race
      --- FAIL: TestLineTooLong (0.00s)
          main_test.go:81: read tcp 127.0.0.1:45272->127.0.0.1:41391: read: connection reset by peer
      FAIL
      FAIL	echo	0.206s
      FAIL
FAIL  a longer line gets the error, then the connection closes
      ConnectionResetError: the error message never arrived
~~~

Reading lines with `bufio.Scanner`, which drops `\r` and adds a newline the client never sent:

~~~text
FAIL  go test -race
      --- FAIL: TestEcho (0.01s)
          --- FAIL: TestEcho/windows_line_ending (0.00s)
              main_test.go:73: sent 7 bytes, got back 6: "hello\n"
          --- FAIL: TestEcho/last_line_without_newline (0.00s)
              main_test.go:73: sent 7 bytes, got back 8: "one\ntwo\n"
      FAIL
      FAIL	echo	0.197s
      FAIL
FAIL  100 clients at once get back exactly what they sent (14,009,678 bytes)
      client 0 sent 17213 bytes and got back 17205 bytes; first difference at byte 1: sent b'\r\n\x10\x17\nf\x99\xa5\x8c\t\x1a\xff', got b'\n\x10\x17\nf\x99\xa5\x8c\t\x1a\xff\xea'
~~~

The client reads with `read(65536)` instead of `readline()`. Against your own server on the loopback it passes; against replies that arrive in pieces it doesn't:

~~~text
FAIL  pytest
      ...
      E                   ValueError: request 0: sent 16 bytes, got back b'0 xxxxxx'
      ...
      1 failed, 21 passed in 0.24s
FAIL  replies that arrive in two pieces are read whole
      exit 1: measure: request 0: sent 16 bytes, got back b'0 xxxxxx'
~~~

Percentiles from `statistics.quantiles`, which interpolates, instead of nearest rank. The printed p50 and p99 may still match the CSV to the thousandth (with 1,000 values, neighbouring latencies are often a microsecond apart), so it's your own tests that catch this one:

~~~text
FAIL  pytest
      ...
      =========================== short test summary info ============================
      FAILED test_stats.py::test_percentile_nearest_rank[10-1] - assert 1.9 == 1
      FAILED test_stats.py::test_percentile_nearest_rank[50-5] - assert 5.5 == 5
      FAILED test_stats.py::test_percentile_nearest_rank[90-9] - assert 9.1 == 9
      FAILED test_stats.py::test_percentile_nearest_rank[99-10] - assert 9.91 == 10
      FAILED test_stats.py::test_percentile_is_a_value_that_occurred - assert 50.87...
      5 failed, 17 passed in 0.24s
~~~
