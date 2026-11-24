# Evidence: Python and the internet from zero

Real outputs behind the lessons and the gate, captured on 2026-11-19 with Go 1.27.4, uv 0.12.7 and Python 3.14.7.

## How they were captured

All runs used [Dockerfile](Dockerfile): a fresh Ubuntu 24.04 with the Foundations tools and an ordinary user, `ada`, on a 16-CPU x86-64 machine running WSL2. Each script installs Go from go.dev, as Foundations 01 does; lesson 06's capture installs uv from its GitHub release and checks the checksum, as the lesson does.

- **`lessons/`** comes from [capture-lessons.sh](capture-lessons.sh). It runs every command the lessons show, in order, in `~/blueprint/internet`, putting each step's code in place as the lessons build it. Each deliberate mistake from [mistakes/](mistakes/) is laid over the code, run, and undone. Every capture has a two-minute limit, and anything it left running is stopped before the next. `0304-refused.txt` was recaptured with [capture-extra.sh](capture-extra.sh) after `nc -v` was added, so that `Connection refused` is printed. `latency-1.png` is the one-connection plot from lesson 09; the 10- and 100-connection plots are in the module's [images/](../images/).
- Each text file holds the command, its output and its exit status. Times, ports, sequence numbers, addresses, TTLs and latencies differ on every run.
- The network lessons ran inside the container, so they show a container's network (`eth0` at `172.17.0.2`) behind WSL's (`172.28.240.1`) and a home router (`192.168.0.1`). `traceroute` was stopped after three hops on purpose: the later hops are the author's internet provider.

## Findings while building the module

- **Closing with unread bytes resets the connection.** The first server wrote its "line too long" error and closed with one byte still unread. Linux then sends `RST` instead of `FIN`, and the client got `connection reset by peer` instead of the message, every time. A lingering close (stop sending, read and discard for up to a second, then close) fixed it. Lesson 04 builds the bug first and lets the test find it.
- **A load generator measures itself.** 1,000 requests over 1, 10 and 100 connections: 0.388 s, 0.141 s and 0.159 s; p50 0.362, 1.296 and 11.661 ms. Throughput stopped growing after 10 connections while the median grew ninefold, consistent with Little's law (100 in flight ÷ about 6,300 a second ≈ 16 ms each). On the host, outside the container, two copies of the client with 50 connections each did about 11,400 requests a second together, against about 6,000 for one copy with 100 connections, with lower latencies: much of the waiting is inside the single-threaded Python client.
- **The p99 at 100 connections is start-up.** The slowest requests were the first ones on the last connections to open (requests 80–99 in a repeat run on the host); no later request went over 19 ms.
- **Request size barely matters on the loopback.** 16 bytes to 16 KiB: p50 0.343 to 0.384 ms with one connection, and the same within 0.05 ms with 100.
- **WSL's resolver can't start a `dig +trace`.** `10.255.255.254` times out on the query for the root servers ([0209-trace-wsl.txt](lessons/0209-trace-wsl.txt)); `dig +trace @1.1.1.1` works.
- **Python's bytecode cache can run old code.** While capturing, a deliberate mistake that changed `.3f` to `.2f` in `results.py` (same file size) was undone within the same second it was made; Python's `__pycache__`, which checks a source file's modification time to the second and its size, kept running the mistake. The gate caught it: the printed p50 was `1.258` against `1.260` from the CSV. The capture script now clears `__pycache__` after each mistake.
- **`nc -N` waits for the server to close.** A client that has finished sending still waits for the server's `FIN`, so against a server that never closes (the `CLOSE-WAIT` mistake), it hung until given `-w 1`.

## Gate

[gate/](gate/) holds the gate run against the finished module and eight broken versions, from [capture-gate.sh](capture-gate.sh); [gate/broken/](gate/broken/) has each one as a diff against the finished code.

| Run | Broken how | Fails |
|---|---|---|
| `gate-good.txt` | Not broken | Nothing: 18 of 18 pass |
| `gate-serial.txt` | `handle(conn, idle)` without `go` | 100 clients don't finish in 2.5 s while one sits silent; the module's own test |
| `gate-copy.txt` | `io.Copy` instead of lines: no limit | The long line comes back instead of the error; the module's own test |
| `gate-scanner.txt` | `bufio.Scanner` | `\r` dropped and a newline added, at byte 1; the module's own test |
| `gate-nolinger.txt` | No lingering close | `ConnectionResetError`: the error message never arrives; the module's own test |
| `gate-noidle.txt` | No read deadline | The silent client is still connected after 8 s; the module's own test |
| `gate-readn.txt` | `read(65536)` instead of `readline()` | Replies in two pieces; the module's own test. It passes against the real server |
| `gate-quantiles.txt` | Percentiles from `statistics.quantiles` | The module's own tests. The printed p50 and p99 happened to match the CSV in this run; on the host they differed by 0.001 ms |
| `gate-traceback.txt` | No `try`/`except` in `main` | A traceback instead of a one-line message, for a wrong reply and for a refused connection |
