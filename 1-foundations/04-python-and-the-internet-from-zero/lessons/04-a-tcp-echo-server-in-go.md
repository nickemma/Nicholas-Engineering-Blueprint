# 04 A TCP echo server in Go

> Module: Python and the internet from zero · Time: ~4 h · Builds on: 03, and Go from zero

## The problem

In the last lesson, `nc` was the server. Now you'll write one: a program that listens on a port, accepts connections, and sends every line back. An **echo server** does nothing useful with the data, which is the point: everything that's left is the part every server has to get right. It must serve many clients at once, cope with TCP handing it bytes in arbitrary pieces, refuse input that's too big, hang up on clients that go quiet, and close every connection it opens. Lesson 09 measures this server from Python, and the gate tests it with clients you haven't seen.

## The mental model

~~~text
 net.Listen("tcp", "127.0.0.1:9000")      the listening socket (the LISTEN line in ss)
        │
        │  Accept() waits for the next connection, and returns it
        ▼
 for { conn := Accept(); go handle(conn) }
                              │
             one goroutine per connection, each with its own net.Conn:
             Read() returns whatever bytes have arrived (1 byte, or 65,536)
             Write() sends bytes back
             Close() ends the connection (FIN), and frees the socket
~~~

A `net.Conn` is a stream of bytes in each direction, exactly as TCP is. A single `Read` returns *some* of the bytes that have arrived so far, not "one message". If your program has messages, it has to find where each one ends. That's called **framing**, and here a message is a line: it ends at `\n`.

## The pattern

**Frame, limit, time out, close.** Every server that reads from a network does these four things: it finds where each message ends, refuses messages that are too big, stops waiting for clients that send nothing, and closes every connection it accepts. Leave any one out and a single client can exhaust the server. You'll leave each one out on purpose and see what happens.

## Build it

The code lives in `~/blueprint/internet`, the folder for this module: the Go server in `echo/`, and from lesson 06 the Python code in `measure/`.

~~~bash
mkdir -p ~/blueprint/internet && cd ~/blueprint/internet
mkdir echo && cd echo && go mod init echo && cat go.mod
~~~

<!-- run: mkdir -p echo && cd echo && go mod init echo -->

~~~text
go: creating new go.mod: module echo
module echo

go 1.27.4
~~~

### Step 1: Listen, accept, read, write

Create `echo/main.go`:

<!-- file: echo/main.go -->
~~~go
// echo sends back whatever it receives. This first version serves one
// connection at a time, and logs the size of every read.
package main

import (
	"fmt"
	"log"
	"net"
	"os"
)

func main() {
	ln, err := net.Listen("tcp", "127.0.0.1:9000")
	if err != nil {
		fmt.Fprintln(os.Stderr, "echo:", err)
		os.Exit(1)
	}
	fmt.Println("listening on", ln.Addr())
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Println("accept:", err)
			continue
		}
		handle(conn)
	}
}

// handle copies everything that arrives on conn back to it, until the
// client closes the connection.
func handle(conn net.Conn) {
	defer conn.Close()
	log.Println("open", conn.RemoteAddr())
	buf := make([]byte, 64*1024)
	for {
		n, err := conn.Read(buf)
		if n > 0 {
			log.Printf("read %d bytes", n)
			if _, werr := conn.Write(buf[:n]); werr != nil {
				log.Println("write:", werr)
				return
			}
		}
		if err != nil {
			log.Println("closed", conn.RemoteAddr(), err)
			return
		}
	}
}
~~~

<!-- run: cd echo && [ -z "$(gofmt -l .)" ] && go vet ./... && go build -o /dev/null . -->

- `net.Listen("tcp", "127.0.0.1:9000")` creates the listening socket. If the port is taken, it returns an error, and the server stops with a message.
- `ln.Accept()` waits until a client connects, and returns a `net.Conn` for that one connection.
- `conn.Read(buf)` waits until some bytes arrive, copies them into `buf`, and returns how many (`n`). It returns `io.EOF` when the client has closed its side and nothing is left.
- Handle `n > 0` *before* checking `err`: a `Read` can return the last bytes and an error together.
- `log` writes to standard error with a timestamp; the server's real output, `listening on`, goes to standard output.

Build it and try it, with the server in the background and `nc` as the client:

~~~bash
cd ~/blueprint/internet/echo
go build -o /tmp/echo . && { /tmp/echo & sleep 0.5; printf "hello\n" | nc -N 127.0.0.1 9000; sleep 0.3; kill %1; }
~~~

~~~text
listening on 127.0.0.1:9000
2026/11/19 08:57:31 open 127.0.0.1:44138
2026/11/19 08:57:31 read 6 bytes
hello
2026/11/19 08:57:31 closed 127.0.0.1:44138 EOF
~~~

The server read 6 bytes and wrote them back, and `nc` printed them (`hello`). When `nc` closed the connection, `Read` returned `EOF`.

Now send one line of 200,000 bytes, and count what comes back:

~~~bash
/tmp/echo & sleep 0.5; head -c 200000 /dev/zero | tr "\0" x | nc -N 127.0.0.1 9000 | wc -c; sleep 0.3; kill %1
~~~

~~~text
listening on 127.0.0.1:9000
2026/11/19 08:57:32 open 127.0.0.1:44152
2026/11/19 08:57:32 read 65536 bytes
2026/11/19 08:57:32 read 29696 bytes
2026/11/19 08:57:32 read 65536 bytes
2026/11/19 08:57:32 read 26624 bytes
2026/11/19 08:57:32 read 12608 bytes
2026/11/19 08:57:32 closed 127.0.0.1:44152 EOF
200000
~~~

`head -c 200000 /dev/zero | tr "\0" x` makes 200,000 `x` characters. All 200,000 came back, but the server never saw them as one piece: each `Read` returned whatever had arrived, in pieces whose sizes depend on buffers and timing, and they'll differ when you run it. **A TCP read can return half a message.** This version doesn't care, because it sends every piece straight back. A server that needs whole messages does, and step 3 deals with it.

### Step 2: One client blocks everyone

Keep one client connected for three seconds (`sleep 3 |` gives it nothing to send until then), and meanwhile try a second:

~~~bash
/tmp/echo & sleep 0.5
sleep 3 | nc -N 127.0.0.1 9000 &
sleep 0.3; date +%T; printf "second\n" | nc -N 127.0.0.1 9000; date +%T
wait $!; kill %1
~~~

~~~text
listening on 127.0.0.1:9000
2026/11/19 08:57:33 open 127.0.0.1:44166
08:57:34
2026/11/19 08:57:36 closed 127.0.0.1:44166 EOF
2026/11/19 08:57:36 open 127.0.0.1:44176
2026/11/19 08:57:36 read 7 bytes
2026/11/19 08:57:36 closed 127.0.0.1:44176 EOF
second
08:57:36
~~~

The second client sent `second` at once, but its connection wasn't even opened by the server (`open`) until the first client left, three seconds after it connected. The server was inside `handle` for the first client, and didn't call `Accept` again until then. (The second connection was still made: the kernel completes the handshake and queues new connections until the program accepts them. In `ss`, the `LISTEN` line's `Recv-Q` is how many are waiting in that queue, and `Send-Q` is how many it can hold.)

The fix is one word. Run each connection in its own goroutine:

<!-- edit: echo/main.go -->
~~~go
		handle(conn)
	}
~~~

~~~go
		go handle(conn)
	}
~~~

and update the comment at the top of the file to say so:

<!-- edit: echo/main.go -->
~~~go
// echo sends back whatever it receives. This first version serves one
// connection at a time, and logs the size of every read.
~~~

~~~go
// echo sends back whatever it receives. Each connection gets its own
// goroutine, and every read is logged with its size.
~~~

<!-- run: cd echo && [ -z "$(gofmt -l .)" ] && go vet ./... && go build -o /dev/null . -->

~~~bash
go build -o /tmp/echo . && { /tmp/echo & sleep 0.5; sleep 3 | nc -N 127.0.0.1 9000 & sleep 0.3; date +%T; printf "second\n" | nc -N 127.0.0.1 9000; date +%T; wait $!; kill %1; }
~~~

~~~text
listening on 127.0.0.1:9000
2026/11/19 08:57:38 open 127.0.0.1:44192
08:57:38
2026/11/19 08:57:38 open 127.0.0.1:44206
2026/11/19 08:57:38 read 7 bytes
second
2026/11/19 08:57:38 closed 127.0.0.1:44206 EOF
08:57:38
2026/11/19 08:57:41 closed 127.0.0.1:44192 EOF
~~~

Both clients are served at once; the second gets its answer in the same second. A goroutine costs a few kilobytes, so a Go server can hold tens of thousands of connections like this. Each goroutine spends most of its time blocked in `Read`, and the Go runtime parks it until data arrives, without tying up a CPU.

### Step 3: Lines, with a limit

Now make it a line server: read one line at a time, send it back whole, and refuse lines that are too long. Without a limit, a client that sends gigabytes with no newline makes the server keep growing its buffer until it runs out of memory.

`bufio.Reader` does the framing. `bufio.NewReaderSize(conn, maxLine)` gives it a buffer of `maxLine` bytes, and `ReadSlice('\n')` returns the bytes up to and including the next newline. If the buffer fills up with no newline in it, `ReadSlice` returns `bufio.ErrBufferFull`: the line is too long. You'll also take the address from a flag, so the gate (and your tests) can ask for port `0`, which means "any free port".

Replace `echo/main.go` with:

<!-- file: echo/main.go -->
~~~go
// echo is a TCP server that sends every line it receives straight back.
//
// Each connection gets its own goroutine. A line may be up to maxLine bytes,
// newline included; a longer one gets an error and the connection is closed.
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
)

const maxLine = 64 * 1024

func main() {
	addr := flag.String("addr", "127.0.0.1:9000", "address to listen on (port 0 picks a free port)")
	flag.Parse()

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "echo:", err)
		os.Exit(1)
	}
	fmt.Println("listening on", ln.Addr())
	serve(ln)
}

// serve accepts connections until the listener is closed, and hands each
// one to its own goroutine.
func serve(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if errors.Is(err, net.ErrClosed) {
			return
		}
		if err != nil {
			log.Println("accept:", err)
			continue
		}
		go handle(conn)
	}
}

// handle echoes lines on one connection until the client closes it or sends
// a line longer than maxLine.
func handle(conn net.Conn) {
	defer conn.Close()
	peer := conn.RemoteAddr()
	r := bufio.NewReaderSize(conn, maxLine)
	lines, bytes := 0, 0
	for {
		line, err := r.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			fmt.Fprintf(conn, "error: line longer than %d bytes\n", maxLine)
			log.Printf("%s: line too long, closing", peer)
			return
		}
		if len(line) > 0 {
			if _, werr := conn.Write(line); werr != nil {
				log.Printf("%s: write: %v", peer, werr)
				return
			}
			lines++
			bytes += len(line)
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("%s: %v", peer, err)
			}
			log.Printf("%s: closed after %d lines, %d bytes", peer, lines, bytes)
			return
		}
	}
}
~~~

<!-- run: cd echo && [ -z "$(gofmt -l .)" ] && go vet ./... && go build -o /dev/null . -->

- `serve` is the accept loop, moved out of `main` so a test can run it on a listener of its own. It returns when the listener is closed (`net.ErrClosed`), which is how a test will stop it.
- `ReadSlice` returns a slice of the reader's own buffer, which the next read overwrites. That's the same trap as `scanner.Bytes()` in Go from zero lesson 11, and it's safe here because the line is written out before the next `ReadSlice`. Keeping it for later would need a copy.
- When the connection ends, `ReadSlice` returns whatever was left (a last line with no newline) together with `io.EOF`. Writing `line` before checking `err` sends that back too, so the client gets back exactly the bytes it sent.
- The limit is 65,536 bytes, newline included. A longer line gets one error line, and the connection is closed: after a line that's too long, there's no telling where the next one starts.

Start it on any free port, and send two lines and a piece without a newline. `od -c` shows exactly which bytes come back, `\n` included:

~~~bash
go build -o /tmp/echo . && { /tmp/echo -addr 127.0.0.1:0 > /tmp/echo.out & sleep 0.5; cat /tmp/echo.out; port=$(sed "s/.*://" /tmp/echo.out); printf "one\ntwo\nno newline" | nc -N 127.0.0.1 $port | od -c; sleep 0.3; kill %1; }
~~~

~~~text
listening on 127.0.0.1:46861
2026/11/19 08:57:42 127.0.0.1:60630: closed after 3 lines, 18 bytes
0000000   o   n   e  \n   t   w   o  \n   n   o       n   e   w   l   i
0000020   n   e
0000022
~~~

Port `0` got a free port from the system, and the server printed which. Every byte came back, including the last piece with no newline, and the log counts three lines.

### Step 4: Hang up on quiet clients

A client that connects and then sends nothing holds a goroutine and a socket for as long as it likes. Enough of them and the server runs out of file descriptors (Foundations 02: every socket is one). A **read deadline** fixes that: `conn.SetReadDeadline(t)` makes any `Read` still waiting at time `t` fail with a timeout error. Setting it again before every read turns it into an idle limit: "close the connection if nothing arrives for this long".

Add an `-idle` flag, and pass it down to `handle`:

<!-- edit: echo/main.go -->
~~~go
// newline included; a longer one gets an error and the connection is closed.
package main
~~~

~~~go
// newline included; a longer one gets an error and the connection is closed.
// A connection that sends nothing for -idle is closed too.
package main
~~~

<!-- edit: echo/main.go -->
~~~go
	"os"
)
~~~

~~~go
	"os"
	"time"
)
~~~

<!-- edit: echo/main.go -->
~~~go
	addr := flag.String("addr", "127.0.0.1:9000", "address to listen on (port 0 picks a free port)")
	flag.Parse()
~~~

~~~go
	addr := flag.String("addr", "127.0.0.1:9000", "address to listen on (port 0 picks a free port)")
	idle := flag.Duration("idle", 30*time.Second, "close a connection that sends nothing for this long")
	flag.Parse()
~~~

<!-- edit: echo/main.go -->
~~~go
	serve(ln)
}
~~~

~~~go
	serve(ln, *idle)
}
~~~

<!-- edit: echo/main.go -->
~~~go
func serve(ln net.Listener) {
~~~

~~~go
func serve(ln net.Listener, idle time.Duration) {
~~~

<!-- edit: echo/main.go -->
~~~go
		go handle(conn)
~~~

~~~go
		go handle(conn, idle)
~~~

Then `handle` takes the limit, and sets the deadline before every read:

<!-- edit: echo/main.go -->
~~~go
// handle echoes lines on one connection until the client closes it or sends
// a line longer than maxLine.
func handle(conn net.Conn) {
~~~

~~~go
// handle echoes lines on one connection until the client closes it, goes
// quiet for too long, or sends a line longer than maxLine.
func handle(conn net.Conn, idle time.Duration) {
~~~

<!-- edit: echo/main.go -->
~~~go
	for {
		line, err := r.ReadSlice('\n')
~~~

~~~go
	for {
		conn.SetReadDeadline(time.Now().Add(idle))
		line, err := r.ReadSlice('\n')
~~~

<!-- run: cd echo && [ -z "$(gofmt -l .)" ] && go vet ./... && go build -o /dev/null . -->

`flag.Duration` reads values such as `30s`, `2s` or `500ms`. Try it with a two-second limit and a client that says nothing:

~~~bash
go build -o /tmp/echo . && { /tmp/echo -idle 2s > /dev/null & sleep 0.5; date +%T; nc 127.0.0.1 9000; date +%T; kill %1; }
~~~

~~~text
08:57:43
2026/11/19 08:57:45 127.0.0.1:50112: read tcp 127.0.0.1:9000->127.0.0.1:50112: i/o timeout
2026/11/19 08:57:45 127.0.0.1:50112: closed after 0 lines, 0 bytes
08:57:45
~~~

After two seconds of silence, `ReadSlice` returned the timeout (`i/o timeout`), `handle` logged it and returned, and the deferred `Close` hung up. `nc` saw the connection close and exited.

### Step 5: Tests, and a bug they find

Testing a server means being its client. Create `echo/main_test.go`:

<!-- file: echo/main_test.go -->
~~~go
package main

import (
	"bufio"
	"bytes"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestMain runs before the tests. The server logs every connection, and
// those lines would bury the test results, so they're thrown away.
func TestMain(m *testing.M) {
	log.SetOutput(io.Discard)
	m.Run()
}

// start runs the server on a free port and returns its address. The
// listener is closed when the test ends.
func start(t *testing.T, idle time.Duration) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go serve(ln, idle)
	return ln.Addr().String()
}

// roundTrip sends data, closes the sending half, and returns everything the
// server sends back before it closes the connection.
func roundTrip(t *testing.T, addr string, data []byte) []byte {
	t.Helper()
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	go func() {
		conn.Write(data)
		conn.(*net.TCPConn).CloseWrite()
	}()
	got, err := io.ReadAll(conn)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestEcho(t *testing.T) {
	addr := start(t, time.Second)
	tests := []struct {
		name string
		data string
	}{
		{"one line", "hello\n"},
		{"several lines", "one\ntwo\nthree\n"},
		{"windows line ending", "hello\r\n"},
		{"empty line", "\n"},
		{"last line without newline", "one\ntwo"},
		{"longest line allowed", strings.Repeat("x", maxLine-1) + "\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := roundTrip(t, addr, []byte(tt.data))
			if !bytes.Equal(got, []byte(tt.data)) {
				t.Errorf("sent %d bytes, got back %d: %.40q", len(tt.data), len(got), got)
			}
		})
	}
}

func TestLineTooLong(t *testing.T) {
	addr := start(t, time.Second)
	got := roundTrip(t, addr, []byte(strings.Repeat("x", maxLine)+"\n"))
	want := "error: line longer than 65536 bytes\n"
	if string(got) != want {
		t.Errorf("got %.60q, want %q", got, want)
	}
}

func TestIdleConnectionIsClosed(t *testing.T) {
	addr := start(t, 100*time.Millisecond)
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	began := time.Now()
	if _, err := conn.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("got %v, want the server to close the connection (EOF)", err)
	}
	if waited := time.Since(began); waited < 100*time.Millisecond {
		t.Errorf("closed after %v, before the idle time", waited)
	}
}

func TestManyClientsAtOnce(t *testing.T) {
	addr := start(t, 10*time.Second)
	// A client that connects and says nothing must not hold up the others.
	quiet, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer quiet.Close()

	var wg sync.WaitGroup
	for i := range 50 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := net.Dial("tcp", addr)
			if err != nil {
				t.Error(err)
				return
			}
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(2 * time.Second))
			r := bufio.NewReader(conn)
			for j := range 20 {
				line := strings.Repeat("ab", i*j) + "\n"
				if _, err := io.WriteString(conn, line); err != nil {
					t.Error(err)
					return
				}
				got, err := r.ReadString('\n')
				if err != nil || got != line {
					t.Errorf("client %d line %d: got %d bytes (%v), want %d", i, j, len(got), err, len(line))
					return
				}
			}
		}()
	}
	wg.Wait()
}
~~~

- `TestMain`, if a test file has one, runs instead of the tests and calls `m.Run()` to run them. This one first sends the server's `log` output to `io.Discard`, which throws everything away: otherwise every connection's log line would be printed between the test results.
- `start` runs the real `serve` on port 0, in a goroutine, and `t.Cleanup` closes the listener when the test ends, which stops `serve`.
- `roundTrip` writes in a goroutine while it reads. If it wrote everything first, then read, a large enough message could fill both directions' buffers: the server blocked writing back to a client that isn't reading yet, and the client blocked writing to a server that's stopped reading. Neither would move.
- `CloseWrite` sends `FIN`: "I'm done sending", while still reading. The server sees `EOF`, sends back the rest, and closes. TCP calls this a **half-close**.
- `TestManyClientsAtOnce` opens a quiet connection first. If the server served connections one at a time, every other client would wait on it and hit its two-second deadline.

Run them:

~~~bash
go test ./...
~~~

~~~text
--- FAIL: TestLineTooLong (0.00s)
    main_test.go:81: read tcp 127.0.0.1:54804->127.0.0.1:44423: read: connection reset by peer
FAIL
FAIL	echo	0.173s
FAIL
~~~

<!-- run: cd echo && ! go test -count=1 -run TestLineTooLong ./... > /dev/null 2>&1 -->

Three pass, and `TestLineTooLong` fails. The client never got the error line; it got `connection reset by peer`. Here's why. The test sent 65,537 bytes. The server read 65,536 of them, found no newline, wrote the error, and returned, so the deferred `Close` ran **with one byte still unread**. When a program closes a TCP socket that has unread data, the kernel doesn't send the polite `FIN`; it sends `RST`, a reset, which tells the other side "this connection is broken, throw it away". The client's kernel did just that, and threw away the error message waiting to be read with it.

### Step 6: Close so the message arrives

The fix is to stop sending, then read and discard whatever the client still sends, for a short while, before closing. Web servers call it a **lingering close**. Add `lingeringClose` at the end of `echo/main.go`:

<!-- append: echo/main.go -->
~~~go
// lingeringClose gets an error message to the client before closing. Closing
// a connection that still has unread bytes makes the kernel reset it, and a
// reset can throw away the message before the client reads it. So stop
// sending (the client sees the end of the stream), then read and discard
// whatever is left, for up to a second, before handle closes it.
func lingeringClose(conn net.Conn) {
	if tc, ok := conn.(*net.TCPConn); ok {
		tc.CloseWrite()
	}
	conn.SetReadDeadline(time.Now().Add(time.Second))
	io.Copy(io.Discard, conn)
}
~~~

and call it after writing the error:

<!-- edit: echo/main.go -->
~~~go
			log.Printf("%s: line too long, closing", peer)
			return
~~~

~~~go
			log.Printf("%s: line too long, closing", peer)
			lingeringClose(conn)
			return
~~~

- `conn.(*net.TCPConn)` is a **type assertion**: `conn` is a `net.Conn` interface, and this asks whether the value inside is really a `*net.TCPConn`, which has `CloseWrite`. `ok` is false for any other kind of connection.
- `io.Copy(io.Discard, conn)` reads until the client closes or the one-second deadline passes, and throws the bytes away. Either way, `handle`'s deferred `Close` runs next, now with nothing unread, so it sends `FIN`, and the error line arrives.

~~~bash
go test -race ./...
~~~

~~~text
ok  	echo	1.198s
~~~

<!-- run: cd echo && [ -z "$(gofmt -l .)" ] && go vet ./... && go test -race -count=1 ./... -->

## Break it

**Use `bufio.Scanner`.** Go from zero used `bufio.Scanner` to read lines, so why not here? Copy `main.go` somewhere safe, and replace `handle` with a scanner version:

~~~go
func handle(conn net.Conn, idle time.Duration) {
	defer conn.Close()
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 4096), maxLine)
	for sc.Scan() {
		fmt.Fprintf(conn, "%s\n", sc.Bytes())
	}
}
~~~

It ignores `idle`, which Go allows for a parameter. Rebuild and start it (`go build -o /tmp/echo . && /tmp/echo > /dev/null &`), then send a Windows line ending and a last line without one:

~~~bash
printf "windows\r\nlast" | nc -N 127.0.0.1 9000 | od -c
~~~

~~~text
0000000   w   i   n   d   o   w   s  \n   l   a   s   t  \n
0000015
~~~

Sent: `windows\r\nlast`, 14 bytes. Back: `windows\nlast\n`. The scanner removes the line ending, *including* a `\r` before it, and the server adds `\n` to every line, including the last one, which didn't have one. Fine for reading a log; wrong for a server that promises to return exactly what it received. `TestEcho`'s Windows and no-newline rows catch it. Stop the server (`kill %1`) and put your saved `main.go` back.

**Forget to close.** Delete `defer conn.Close()` from `handle`, rebuild, and connect three clients that each send a line and leave:

~~~bash
go build -o /tmp/echo . && { /tmp/echo 2>/dev/null > /dev/null & p=$!; sleep 0.5; for i in 1 2 3; do printf "hi\n" | nc -N 127.0.0.1 9000 > /dev/null; done; sleep 0.3; ss -tn state close-wait; ls /proc/$p/fd | wc -l; kill $p; }
~~~

~~~text
Recv-Q Send-Q Local Address:Port Peer Address:Port Process
0      0          127.0.0.1:9000    127.0.0.1:44014       
0      0          127.0.0.1:9000    127.0.0.1:35706       
0      0          127.0.0.1:9000    127.0.0.1:44000       
10
~~~

All three clients have gone, but their connections haven't: they're stuck in `CLOSE-WAIT`, the state of a connection whose other side has closed and whose own side hasn't. Each one holds a file descriptor (`ls /proc/PID/fd` counts them; the rest are standard input, output and error, the listener, and Go's own). With the `defer` back:

~~~text
Recv-Q Send-Q Local Address:Port Peer Address:PortProcess
7
~~~

None left. A server with a growing pile of `CLOSE-WAIT` connections has a missing `Close`, and it'll eventually fail with `too many open files`. (Go closes forgotten sockets when the garbage collector finds them, which hides the leak in a short test and not in production.)

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race -v ./... 2>&1 | grep -E "^(=== RUN|--- |ok|FAIL|PASS)"
~~~

~~~text
=== RUN   TestEcho
=== RUN   TestEcho/one_line
=== RUN   TestEcho/several_lines
=== RUN   TestEcho/windows_line_ending
=== RUN   TestEcho/empty_line
=== RUN   TestEcho/last_line_without_newline
=== RUN   TestEcho/longest_line_allowed
--- PASS: TestEcho (0.02s)
=== RUN   TestLineTooLong
--- PASS: TestLineTooLong (0.00s)
=== RUN   TestIdleConnectionIsClosed
--- PASS: TestIdleConnectionIsClosed (0.10s)
=== RUN   TestManyClientsAtOnce
--- PASS: TestManyClientsAtOnce (0.07s)
PASS
ok  	echo	1.216s
~~~

That proves the server echoes exactly, refuses long lines and still delivers the error, hangs up on quiet clients, and serves many clients at once. It doesn't prove how fast it is, which lesson 09 measures, or that it shuts down cleanly when stopped: Core 01 builds a server that finishes its work before it exits.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `echo: listen tcp 127.0.0.1:9000: bind: address already in use` | Another copy is still running | `ss -tlnp \| grep 9000` (or `lsof -i :9000`) shows it; stop it, or use `-addr 127.0.0.1:0` |
| The second client waits for the first | `handle(conn)` without `go` | Start a goroutine per connection |
| Lines come back without `\r`, or with an extra `\n` | Reading with `bufio.Scanner` | Use `ReadSlice('\n')` and write back exactly what it returns |
| `connection reset by peer` instead of the error message | The server closed with unread bytes | `lingeringClose` before returning |
| A quiet client is never disconnected | No read deadline, or it was set once instead of before every read | `conn.SetReadDeadline(time.Now().Add(idle))` inside the loop |
| `ss` shows connections in `CLOSE-WAIT` piling up | A connection is never closed | `defer conn.Close()` at the top of `handle` |
| A test hangs | A client is waiting for data that never comes | Set deadlines on test connections, as these tests do |
