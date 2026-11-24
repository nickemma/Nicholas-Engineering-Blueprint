# Exercises: Python and the internet from zero

Each exercise is a different project that uses this module's ideas, so you can't just retrace the lessons. There's no solution code.

## Exercise 1: `linechat`, a chat server over TCP, in Go

1. **What you're building:** a server where every line one client sends is delivered to every other connected client. It exercises everything lesson 04 did (a goroutine per connection, line framing, closing), plus a problem the echo server never had: one connection's data has to reach the others, and a client that stops reading mustn't freeze everyone else.
2. **The finished result:**
   - `linechat [-addr 127.0.0.1:9100]` prints `listening on ADDR`, like your echo server.
   - A new client is called `guest-N` (N counts up from 1). Every line it sends reaches every *other* client as `guest-N: the line`.
   - Two commands: `/nick NAME` renames the sender and tells the others `* OLD is now NEW` (names are 1–16 letters, digits or `-`, and unique; otherwise the sender alone gets `error: ...`), and `/who` sends the sender the list of names, one per line, sorted, then `end`.
   - When a client joins or leaves, the others get `* guest-N joined` or `* NAME left`.
   - Lines longer than 4 KiB get `error: line too long` and the connection is closed, like the echo server's limit.
   - **A slow client doesn't slow anyone down.** Each client has an outgoing queue of 100 lines. If a client's queue is full, it's disconnected (`* NAME was too slow` to the others), and nobody else waits.
3. **A sample session,** with two terminals each running `nc 127.0.0.1 9100`. `A>` and `B>` are what each one types; the other lines are what arrives:

   ~~~text
   A> /nick ada
   (B connects)                    A gets: * guest-2 joined
   B> hello                        A gets: guest-2: hello
   B> /nick bo                     A gets: * guest-2 is now bo
   A> /who                         A gets: ada
                                           bo
                                           end
   B> /nick ada                    B gets: error: the name ada is taken
   (B presses Ctrl+C)              A gets: * bo left
   ~~~
4. **Done when:**
   1. Three `nc` clients can talk to each other, with joins, leaves, renames and `/who` working as described.
   2. A test (in Go) connects 50 clients, has each send 10 lines, and checks that every client received the other 49 × 10 lines, in each sender's order.
   3. A test connects a client that never reads, sends 1,000 lines from another client, and checks that the silent one is disconnected and the third client still received all 1,000 lines in under a second.
   4. `gofmt -l`, `go vet` and `go test -race ./...` are clean.
5. **Stretch goal:** `/msg NAME text`, a private message to one client.
6. **Hints:** lesson 04 (accept loop, `ReadSlice` with a limit, closing). Lesson 09 of Go from zero (channels): give each client a buffered channel of outgoing lines, and one goroutine that writes them to its connection. Sending to a full channel blocks, but `select` with a `default` case doesn't (Go from zero, lesson 10). One goroutine (or one mutex) owns the set of clients.

## Exercise 2: `httptime`, an HTTP client from bare sockets, in Python

1. **What you're building:** a script that measures how long an HTTP server takes to answer, using `asyncio` streams and the request format from lesson 05, without an HTTP library. You'll see what `curl` does for you, and you can check your numbers against it.
2. **The finished result:**
   - `uv run httptime.py [-n N] [-c C] URL` takes an `http://` URL (no `https`), sends N requests (default 20) over C connections (default 1) using `HTTP/1.1` with `Connection: keep-alive`, so each connection carries several requests.
   - For each request it records the **time to first byte** (from sending the request to receiving the first byte of the status line) and the **total time** (until the whole body has arrived).
   - It reads the response properly: the status line, the headers up to the blank line, then exactly `Content-Length` bytes of body. A response with `Transfer-Encoding: chunked` is read chunk by chunk (each chunk is its size in hex on a line, then that many bytes; a size of 0 ends it).
   - It prints the status codes seen with their counts, then p50 and p99 (nearest rank) of both times, and writes every request to a CSV.
   - A URL that isn't `http://`, a name that doesn't resolve, a refused connection, and a malformed status line each give a one-line error and exit 1, never a traceback.
3. **A sample session:**

   ~~~text
   $ uv run httptime.py -n 20 http://example.com/
   20 requests over 1 connection
   status 200: 20
   first byte  p50 31.402 ms  p99 48.113 ms
   total       p50 31.877 ms  p99 48.502 ms
   wrote httptime.csv
   $ uv run httptime.py https://example.com/
   httptime: only http:// URLs are supported
   ~~~

   Your times will differ.
4. **Done when:**
   1. On `http://example.com/`, its median total time is within a few milliseconds of what `curl -s -o /dev/null -w "%{time_total}\n"` reports for a request on an already-open connection. (Hint: curl's first request includes the DNS lookup and the TCP handshake. How do you measure that separately?)
   2. Tests run it against a local `asyncio` server that you write, with no network: a `Content-Length` response, a chunked response, a response split into several pieces with pauses (as in lesson 08), and a malformed status line.
   3. `ruff format --check`, `ruff check` and `pytest` are clean.
5. **Stretch goal:** report the time for the DNS lookup and the TCP connection separately, for the first request on each connection, and compare them with `dig` and with `curl -w "%{time_namelookup} %{time_connect}\n"`.
6. **Hints:** lesson 05 (what a request and a response look like, byte by byte), 08 (`readline` and `readexactly`, and why `read(n)` isn't enough), and 09 (timing with `perf_counter`, percentiles, CSV). `urllib.parse.urlsplit` splits a URL into its parts.
