# Self-check: Python and the internet from zero

## Explain it

Answer in your own words. Where you can, point at something you ran.

### 01 How a message crosses a network

1. What's the difference between an IP address and a port? Which one picks the machine, and which the program?
2. Why did a ping to `127.0.0.1` take a fraction of a millisecond, and one to `one.one.one.one` many milliseconds?
3. What does the `default via` line in `ip route` mean, and what happens to a packet for an address that isn't on any of your networks?
4. A ping gets no reply. Name two reasons that don't mean the server is down.

### 02 Names: DNS

1. Walk through what happens between a program asking for `example.com` and getting an address, including where `/etc/hosts` fits.
2. Why did the TTL go down between your two `dig` queries, and what does that mean for someone who has just changed a record?
3. Why did `getent hosts blueprint.test` find an address when `dig blueprint.test` didn't?

### 03 TCP and UDP

1. Name the three packets of the TCP handshake and what each one says.
2. What does `ack 7` in your `tcpdump` output promise the sender?
3. What does `connection refused` tell you about the server, and how is it different from a timeout?
4. Why did `nc` exit with 0 after sending a UDP datagram to a port where nothing listened?
5. TCP keeps your bytes and their order. What doesn't it keep?

### 04 A TCP echo server in Go

1. Why did the 200,000-byte line arrive in several reads of different sizes?
2. Why did the second client wait three seconds in step 2, and what one-word change fixed it?
3. Why does the server need a maximum line length, and what does it do when a line is longer?
4. Why did `TestLineTooLong` get `connection reset by peer` instead of the error message, and how does a lingering close fix it?
5. What does `CLOSE-WAIT` mean, and what mistake leaves connections in it?
6. Why couldn't the server use `bufio.Scanner`, when Go from zero did?

### 05 What a request and a response are

1. Write out an HTTP request and response from memory: start lines, two headers each, and a body.
2. How does a client know where a response body ends? Give both ways you saw.
3. What does a 4xx status code tell the caller to do differently from a 5xx?
4. Why did `curl` reject your echo server's reply?

### 06 Python from zero: values, collections and functions

1. Why did `2**64` work in Python, when the same number overflows a Go `int`?
2. Why is `len("café")` 4 in Python and 5 in Go?
3. Why did appending through `other` change `latencies`? How do you make a real copy?
4. What happened when you passed strings to `summarize`, and what does that tell you about type hints?

### 07 Python from zero: classes, files, errors and tests

1. What did `@dataclass` give `Timed` that the hand-written `Request` didn't have?
2. What does `with path.open() as f:` guarantee, and what's the Go equivalent?
3. What does `raise ... from err` add to an exception?
4. Why did only one of the two tests notice when the CSV switched to two decimal places?

### 08 `asyncio` basics

1. What's a coroutine, and what happens when you call an `async` function without `await`?
2. Why did `all_at_once` take 0.5 s with `asyncio.sleep` and 1.5 s with `time.sleep`?
3. Why did `read(100)` return half the reply, while `readline()` returned all of it?

### 09 1,000 requests and a latency plot

1. Why report p50 and p99 instead of the mean?
2. Where exactly does the timer start and stop for one request, and why there?
3. Why does `measure.py` save every result, when it already prints a summary?
4. What happened to p50 and p99 when you went from 10 connections to 100, and what was really being measured?
5. What does this measurement not tell you about the latency real users would see?

## From memory

Close the lessons. Without notes:

1. Using only `nc`, `ss` and `tcpdump`, start a TCP server on port 9100, connect to it, show the connection in `ss`, and capture its handshake.
2. Write a Go TCP server that reads lines up to 1 KiB and replies to each with its length (`5\n` for `hello\n`), one goroutine per connection, with a test that runs it on port 0.
3. Write a Python `asyncio` client that connects to that server 20 times at once, sends one line on each, and checks every reply.
4. Given a list of 10 numbers, compute p50 and p90 by nearest rank on paper, then check your answer with your `percentile` function.
