# 04 Python and the internet from zero

> Foundations · Time: 3 weeks at 12–15 hours a week · Builds on: [03 Go from zero](../03-go-from-zero/README.md) · Status: ready

## What you'll learn

- How a message crosses a network: IP addresses, ports, packets, names (DNS), and the difference between TCP and UDP.
- What an HTTP request and response are, byte by byte.
- Python from zero: running it with `uv`, values and types, collections, functions, classes, files, errors, tests, `asyncio` basics and plotting.

## What you'll build

A **TCP echo server in Go**, and a **Python script** that sends it 1,000 requests, records how long each one took, and plots the latencies.

## Lessons

| # | Lesson | What it teaches | Time |
|---|---|---|---|
| 01 | [How a message crosses a network](lessons/01-how-a-message-crosses-a-network.md) | IP addresses and the loopback address; ports; packets and routers; `ip addr`, `ip route`, `ping` and `traceroute` | ~3 h |
| 02 | [Names: DNS](lessons/02-names-dns.md) | From a name to an address; `/etc/hosts`; resolvers; `dig` and `dig +trace`; caching and time to live | ~3 h |
| 03 | [TCP and UDP](lessons/03-tcp-and-udp.md) | Connections, the three-way handshake, sequence numbers and acknowledgements vs single datagrams; `connection refused`; trying both with `nc`, watching with `ss` and `tcpdump` | ~4 h |
| 04 | [A TCP echo server in Go](lessons/04-a-tcp-echo-server-in-go.md) | `net.Listen` and `Accept`; one goroutine per connection; reading until a newline, with a limit; an idle deadline; tests that are clients; why closing with unread data resets the connection | ~4 h |
| 05 | [What a request and a response are](lessons/05-what-a-request-and-a-response-are.md) | HTTP as text over TCP: method, path, headers, body, status codes, URLs; requests and responses by hand with `nc`, then with `curl -v`; a glimpse of TLS | ~3 h |
| 06 | [Python from zero: values, collections and functions](lessons/06-python-from-zero-values-collections-and-functions.md) | Installing `uv`; running Python; numbers, strings and booleans; lists, dictionaries, sets and tuples; functions and type hints | ~5 h |
| 07 | [Python from zero: classes, files, errors and tests](lessons/07-python-from-zero-classes-files-errors-and-tests.md) | Classes and dataclasses; reading and writing files, CSV; exceptions; `pytest` fixtures and tables | ~5 h |
| 08 | [`asyncio` basics](lessons/08-asyncio-basics.md) | Coroutines and the event loop; `await`; running many connections with `asyncio.gather`; talking to the echo server; a reply that arrives in pieces | ~5 h |
| 09 | [1,000 requests and a latency plot](lessons/09-1000-requests-and-a-latency-plot.md) | Timing with `time.perf_counter`; percentiles by nearest rank; saving raw results to CSV; a histogram with matplotlib; what the numbers do and don't show. Build: the measurement script | ~5 h |

## The gate

`gate/run.sh` builds and starts your echo server, and runs your script against it and against servers of its own:

1. **Server:** 100 clients at once, while one more stays connected and silent, each send lines of many lengths and bytes (Windows line endings and a last line without a newline included), and get back exactly the bytes they sent. A line of exactly 64 KiB comes back whole; a longer one gets the error message, then the connection closes. The silent client is disconnected after `-idle`, and the server is still running at the end.
2. **Script:** 1,000 requests over 10 connections: every request is in your CSV once, with the right sizes, and the p50 and p99 you print match the gate's own nearest-rank calculation from your CSV. The plot is a PNG. Against a server that sends each reply in two pieces, every latency includes the wait for the second piece. A wrong reply and a refused connection each give a one-line error and exit code 1.
3. `gofmt`, `go vet`, `go test -race`, `ruff format`, `ruff check` and `pytest` are clean.

The [gate's page](gate/README.md) shows a pass and each kind of fail.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Explain what happens between typing a URL and the first byte arriving |
| Intermediate | Say why a TCP read can return half a message, and handle it |
| Senior | Debug a connection problem from `dig`, `nc` and `ss` alone, and say what a latency plot does and doesn't show |

## Practice

- [Exercises](exercises.md): `linechat`, a chat server over TCP in Go where a slow client mustn't hold up the others, and `httptime`, an HTTP client from bare sockets in Python.
- [Self-check](self-check.md): explain-it questions per lesson, then a test from memory.

## Next

The core: [01 Go runtime and reliable services](../../2-core/01-go-runtime-and-reliable-services/README.md), where your Go turns into Switchyard's control plane.

---

<sub>The raw runs behind this module's outputs and its gate are in [evidence/](evidence/README.md). You don't need them to follow the lessons.</sub>
