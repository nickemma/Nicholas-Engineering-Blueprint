# 02 HTTP/1.1 by hand

> Module: Go runtime and reliable services · Time: ~5 h · Builds on: 01, and Foundations 04 lessons 04–05

## The problem

From the next lesson on, Switchyard speaks HTTP through Go's `net/http`, and so will almost every service you build or call. `net/http` is excellent, and it hides a great deal: how a request is framed on the connection, how one connection carries many requests, what happens when a client sends too much or too slowly. When you don't know what it hides, you can't tell which of its settings matter, and its defaults include a dangerous one. So, once, you'll write an HTTP/1.1 server by hand on a raw TCP connection, then the same with `net/http`, and compare.

## The mental model

~~~text
 one TCP connection, kept alive, carrying requests one after another:

 client ── GET /jobs HTTP/1.1\r\n                      ┐
           Host: 127.0.0.1:8080\r\n                    │ request 1: headers end at a blank line;
           \r\n                                          ┘ no body, because no Content-Length
 server ── HTTP/1.1 200 OK\r\n                         ┐
           Content-Length: 57\r\n                      │ response 1: the client reads exactly 57 bytes
           \r\n                                          │ of body, then knows the next bytes belong
           request 1 on this connection: ...         ┘ to response 2
 client ── POST /jobs HTTP/1.1\r\n  Content-Length: 5\r\n  \r\n  hello      request 2
 server ── HTTP/1.1 200 OK ...                                            response 2
~~~

HTTP/1.1 framing has two layers: lines for the request line and headers, ending at a blank line, then a body whose length the headers announce. Get either wrong and every request after it on the connection is misread. That's why a server must refuse anything it can't frame with certainty.

## The pattern

**Every input a client controls gets a limit.** Header size, body size, how long the client may take to send them, how long an idle connection may stay open. A server without them can be made to run out of memory or connections by one client, with no special tools: this is the **slowloris** attack, named after a slow animal.

## Build it

Everything in this lesson goes in `~/blueprint/switchyard/drills`.

### Step 1: Read one request

The parser takes a `*bufio.Reader` over the connection and returns one request, or an error saying why it can't. Create `drills/byhand/request.go`:

<!-- file: drills/byhand/request.go -->
~~~go
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Limits a server must set, or one client can make it use any amount of memory.
const (
	maxHeaderBytes = 8 << 10 // the request line and every header together
	maxBodyBytes   = 1 << 20
)

var (
	errBadRequest   = errors.New("bad request")
	errTooLarge     = errors.New("too large")
	errNotSupported = errors.New("not supported")
)

// request is what the server needs from one HTTP/1.1 request.
type request struct {
	method, path, version string
	headers               map[string]string // names in lower case
	body                  []byte
}

// readRequest reads one request from r: the request line, the headers up to
// a blank line, then exactly Content-Length bytes of body.
func readRequest(r *bufio.Reader) (*request, error) {
	used := 0
	line, err := readLine(r, &used)
	if err != nil {
		return nil, err
	}
	parts := strings.Split(line, " ")
	if len(parts) != 3 || !strings.HasPrefix(parts[2], "HTTP/1.") {
		return nil, fmt.Errorf("%w: request line %q", errBadRequest, line)
	}
	req := &request{method: parts[0], path: parts[1], version: parts[2], headers: map[string]string{}}
	for {
		line, err := readLine(r, &used)
		if err != nil {
			return nil, err
		}
		if line == "" {
			break // a blank line ends the headers
		}
		name, value, ok := strings.Cut(line, ":")
		if !ok || name == "" || strings.ContainsAny(name, " \t") {
			return nil, fmt.Errorf("%w: header %q", errBadRequest, line)
		}
		req.headers[strings.ToLower(name)] = strings.TrimSpace(value)
	}
	if _, chunked := req.headers["transfer-encoding"]; chunked {
		return nil, fmt.Errorf("%w: Transfer-Encoding", errNotSupported)
	}
	if cl, ok := req.headers["content-length"]; ok {
		n, err := strconv.Atoi(cl)
		if err != nil || n < 0 {
			return nil, fmt.Errorf("%w: Content-Length %q", errBadRequest, cl)
		}
		if n > maxBodyBytes {
			return nil, fmt.Errorf("%w: body of %d bytes", errTooLarge, n)
		}
		req.body = make([]byte, n)
		if _, err := io.ReadFull(r, req.body); err != nil {
			return nil, fmt.Errorf("%w: body: %v", errBadRequest, err)
		}
	}
	return req, nil
}

// readLine reads up to "\r\n" (or a bare "\n"), counting bytes against maxHeaderBytes.
func readLine(r *bufio.Reader, used *int) (string, error) {
	var b strings.Builder
	for {
		chunk, err := r.ReadSlice('\n')
		*used += len(chunk)
		if *used > maxHeaderBytes {
			return "", fmt.Errorf("%w: headers over %d bytes", errTooLarge, maxHeaderBytes)
		}
		b.Write(chunk)
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if err != nil {
			return "", err
		}
		return strings.TrimRight(b.String(), "\r\n"), nil
	}
}

// keepAlive says whether the connection stays open after this request.
func (req *request) keepAlive() bool {
	c := strings.ToLower(req.headers["connection"])
	if req.version == "HTTP/1.0" {
		return c == "keep-alive"
	}
	return c != "close"
}
~~~

- `readLine` reads with `ReadSlice`, as Foundations 04's echo server did, but counts every byte of the request line and headers against `maxHeaderBytes`. A client can't make the server buffer a 10 GB header.
- Header names are case-insensitive in HTTP (`Content-Length`, `content-length`), so they're stored in lower case.
- The body is read with `io.ReadFull`, exactly `Content-Length` bytes: not "whatever arrived" (Foundations 04 lesson 08). Without a `Content-Length`, a request has no body.
- `Transfer-Encoding: chunked` sends a body in pieces, each with its own length (you saw it in a response in Foundations 04 lesson 05). This parser doesn't handle it, so it refuses it outright. Accepting it while reading the body some other way is how **request smuggling** happens: two programs on the way disagree about where a request ends.
- `keepAlive` follows the rules: an HTTP/1.1 connection stays open unless the client says `Connection: close`; an HTTP/1.0 one closes unless it says `keep-alive`.

Test the edges before trusting it. Create `drills/byhand/request_test.go`:

<!-- file: drills/byhand/request_test.go -->
~~~go
package main

import (
	"bufio"
	"errors"
	"strings"
	"testing"
)

func TestReadRequest(t *testing.T) {
	tests := []struct {
		name     string
		raw      string
		wantPath string
		wantBody string
		wantErr  error
	}{
		{"get", "GET /jobs HTTP/1.1\r\nHost: x\r\n\r\n", "/jobs", "", nil},
		{"post with a body", "POST /jobs HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello", "/jobs", "hello", nil},
		{"bare newlines", "GET / HTTP/1.1\nHost: x\n\n", "/", "", nil},
		{"no version", "GET /\r\n\r\n", "", "", errBadRequest},
		{"header without a colon", "GET / HTTP/1.1\r\nHost x\r\n\r\n", "", "", errBadRequest},
		{"negative length", "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", "", "", errBadRequest},
		{"body cut short", "POST / HTTP/1.1\r\nContent-Length: 9\r\n\r\nabc", "", "", errBadRequest},
		{"huge body", "POST / HTTP/1.1\r\nContent-Length: 9999999\r\n\r\n", "", "", errTooLarge},
		{"huge headers", "GET / HTTP/1.1\r\nX: " + strings.Repeat("a", 9000) + "\r\n\r\n", "", "", errTooLarge},
		{"chunked", "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", "", "", errNotSupported},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req, err := readRequest(bufio.NewReader(strings.NewReader(tt.raw)))
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("error %v, want %v", err, tt.wantErr)
			}
			if err == nil && (req.path != tt.wantPath || string(req.body) != tt.wantBody) {
				t.Errorf("got path %q body %q", req.path, req.body)
			}
		})
	}
}

func TestKeepAlive(t *testing.T) {
	tests := []struct {
		version, connection string
		want                bool
	}{
		{"HTTP/1.1", "", true},
		{"HTTP/1.1", "close", false},
		{"HTTP/1.0", "", false},
		{"HTTP/1.0", "keep-alive", true},
	}
	for _, tt := range tests {
		req := &request{version: tt.version, headers: map[string]string{"connection": tt.connection}}
		if got := req.keepAlive(); got != tt.want {
			t.Errorf("%s with Connection %q: got %v", tt.version, tt.connection, got)
		}
	}
}
~~~

~~~bash
go test -v ./drills/byhand 2>&1 | grep -E "^(--- |ok|FAIL)"
~~~

<!-- run: go vet ./drills/byhand && go test -count=1 ./drills/byhand -->

~~~text
--- PASS: TestReadRequest (0.00s)
--- PASS: TestKeepAlive (0.00s)
ok  	switchyard/drills/byhand	0.006s
~~~

### Step 2: Serve requests on a kept-alive connection

Create `drills/byhand/main.go`:

<!-- file: drills/byhand/main.go -->
~~~go
// Lesson 02: an HTTP/1.1 server written by hand, on a raw TCP connection.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
)

func main() {
	ln, err := net.Listen("tcp", "127.0.0.1:8080")
	if err != nil {
		fmt.Fprintln(os.Stderr, "byhand:", err)
		os.Exit(1)
	}
	fmt.Println("listening on", ln.Addr())
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Println("accept:", err)
			continue
		}
		go serve(conn)
	}
}

// serve answers requests on one connection until the client closes it, asks
// to close, or sends something the server can't read.
func serve(conn net.Conn) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	for n := 1; ; n++ {
		req, err := readRequest(r)
		if errors.Is(err, io.EOF) {
			return // the client closed the connection between requests
		}
		if err != nil {
			status := "400 Bad Request"
			switch {
			case errors.Is(err, errTooLarge):
				status = "413 Content Too Large"
			case errors.Is(err, errNotSupported):
				status = "501 Not Implemented"
			}
			log.Printf("%s: %v", conn.RemoteAddr(), err)
			respond(conn, status, err.Error()+"\n", false)
			return
		}
		body := fmt.Sprintf("request %d on this connection: %s %s, %d bytes of body\n",
			n, req.method, req.path, len(req.body))
		keep := req.keepAlive()
		respond(conn, "200 OK", body, keep)
		if !keep {
			return
		}
	}
}

func respond(w io.Writer, status, body string, keepAlive bool) {
	conn := "close"
	if keepAlive {
		conn = "keep-alive"
	}
	fmt.Fprintf(w, "HTTP/1.1 %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: %s\r\n\r\n%s",
		status, len(body), conn, body)
}
~~~

<!-- run: go vet ./drills/byhand && go build -o /dev/null ./drills/byhand -->

- `serve` loops: one connection, many requests, numbered so you can see them share it.
- `io.EOF` from `readRequest` before any bytes of a new request means the client closed the connection politely between requests.
- A request it can't read gets a `400`, `413` or `501`, and the connection is closed: after a framing error, the server can't know where the next request starts.
- `respond` always sends `Content-Length`, so the client knows where the response ends.

Start it in the background, and ask `curl` for two paths in one command. `curl` reuses the connection for the second:

~~~bash
go build -o /tmp/byhand ./drills/byhand && /tmp/byhand > /dev/null 2> /tmp/byhand.log &
sleep 0.5; curl -sv http://127.0.0.1:8080/jobs http://127.0.0.1:8080/health 2>&1 | grep -E "^[<>*]|^request" | grep -v "^> \(User\|Accept\)"
~~~

~~~text
*   Trying 127.0.0.1:8080...
* Connected to 127.0.0.1 (127.0.0.1) port 8080
> GET /jobs HTTP/1.1
> Host: 127.0.0.1:8080
> 
< HTTP/1.1 200 OK
< Content-Type: text/plain
< Content-Length: 57
< Connection: keep-alive
< 
* Connection #0 to host 127.0.0.1 left intact
request 1 on this connection: GET /jobs, 0 bytes of body
* Found bundle for host: 0x6153226e68a0 [serially]
* Can not multiplex, even if we wanted to
* Re-using existing connection with host 127.0.0.1
> GET /health HTTP/1.1
> Host: 127.0.0.1:8080
> 
< HTTP/1.1 200 OK
< Content-Type: text/plain
< Content-Length: 59
< Connection: keep-alive
< 
* Connection #0 to host 127.0.0.1 left intact
request 2 on this connection: GET /health, 0 bytes of body
~~~

"Re-using existing connection", and the server counted "request 2 on this connection". One handshake, two requests. A body, garbage, and a chunked body:

~~~bash
curl -s -d 'hello' http://127.0.0.1:8080/jobs
printf 'GARBAGE\r\n\r\n' | nc -N 127.0.0.1 8080
curl -si -H 'Transfer-Encoding: chunked' -d 'x' http://127.0.0.1:8080/ | head -1
~~~

~~~text
request 1 on this connection: POST /jobs, 5 bytes of body
HTTP/1.1 400 Bad Request
Content-Type: text/plain
Content-Length: 36
Connection: close

bad request: request line "GARBAGE"
HTTP/1.1 501 Not Implemented
~~~

And a body of 2 MB, over the 1 MiB limit:

~~~bash
head -c 2000000 /dev/zero | curl -si --data-binary @- http://127.0.0.1:8080/upload
kill %1
~~~

~~~text
HTTP/1.1 413 Content Too Large
Content-Type: text/plain
Content-Length: 33
Connection: close

too large: body of 2000000 bytes
~~~

The server answered `413` without reading a byte of the body. That worked smoothly because `curl` sends large bodies politely: it adds the header `Expect: 100-continue` and waits for the server's go-ahead before sending the body. The refusal arrived first, so the body was never sent. A client that sends the body at once would have hit the reset you saw in Foundations 04, the reason for lingering closes.

### Step 3: The same with `net/http`

Create `drills/stdhttp/main.go`:

<!-- file: drills/stdhttp/main.go -->
~~~go
// Lesson 02: the same server with net/http, and the limits it doesn't set for you.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

func main() {
	safe := flag.Bool("safe", false, "set timeouts and size limits")
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusRequestEntityTooLarge)
			return
		}
		fmt.Fprintf(w, "%s %s, %d bytes of body\n", r.Method, r.URL.Path, len(body))
	})

	srv := &http.Server{Addr: "127.0.0.1:8081", Handler: mux}
	if *safe {
		srv.ReadHeaderTimeout = 2 * time.Second // a client gets 2 s to send its headers
		srv.ReadTimeout = 10 * time.Second
		srv.WriteTimeout = 10 * time.Second
		srv.IdleTimeout = 30 * time.Second
		srv.MaxHeaderBytes = 8 << 10
	}
	log.Printf("listening on %s (safe: %v)", srv.Addr, *safe)
	log.Fatal(srv.ListenAndServe())
}
~~~

<!-- run: go vet ./drills/stdhttp && go build -o /dev/null ./drills/stdhttp -->

- `http.NewServeMux()` is a **router**: it picks a handler by path. `"/"` matches everything.
- A **handler** is a function that receives an `http.ResponseWriter` to write the response to, and the parsed `*http.Request`. `net/http` did all of step 1 and 2 for you: parsing, keep-alive, chunked bodies, `Expect: 100-continue`, even HTTP/2 when there's TLS, and it runs each connection in its own goroutine.
- `http.MaxBytesReader` caps the body at 1 MiB. `net/http` doesn't cap bodies for you: without it, `io.ReadAll` would read a body of any size into memory.
- `-safe` sets the server's timeouts and header limit. Without it, `srv` uses the defaults.

~~~bash
go build -o /tmp/stdhttp ./drills/stdhttp && /tmp/stdhttp -safe 2> /dev/null &
sleep 0.5; curl -s -d 'hello' http://127.0.0.1:8081/jobs
head -c 2000000 /dev/zero | curl -si --data-binary @- http://127.0.0.1:8081/upload
kill %1
~~~

~~~text
POST /jobs, 5 bytes of body
HTTP/1.1 100 Continue

HTTP/1.1 413 Request Entity Too Large
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Fri, 20 Nov 2026 02:26:44 GMT
Content-Length: 29
Connection: close

http: request body too large
~~~

This time the server said `100 Continue`, `curl` sent the body, and `MaxBytesReader` cut it off at 1 MiB with a `413`. `net/http` also added a `Date` header and `X-Content-Type-Options: nosniff` (which tells browsers not to guess a different content type).

### Step 4: The default that isn't safe

Now the important difference. Send half a request, the request line and one header but never the blank line, and see how long each server keeps the connection open. `timeout 6` makes the client give up after 6 seconds:

~~~bash
for mode in "" "-safe"; do
  /tmp/stdhttp $mode 2> /dev/null & p=$!; sleep 0.5
  s=$(date +%s%N)
  printf 'GET / HTTP/1.1\r\nHost: x\r\n' | timeout 6 nc 127.0.0.1 8081
  echo "stdhttp $mode: the connection lasted $(( ($(date +%s%N) - s) / 1000000 )) ms"
  kill $p; wait $p 2> /dev/null
done
~~~

~~~text
stdhttp : the connection lasted 6007 ms
stdhttp -safe: the connection lasted 2007 ms
~~~

`date +%s%N` is the time in nanoseconds; the difference, divided by a million, is milliseconds. With the defaults, the server waited the full 6 seconds, until the *client* gave up, and it would have waited forever: **an `http.Server` has no timeouts unless you set them.** A few thousand clients doing this hold a few thousand goroutines and sockets, and the server runs out of file descriptors without ever seeing a complete request. With `-safe`, `ReadHeaderTimeout` closed the connection after 2 seconds.

What each setting covers:

| Setting | Limits |
|---|---|
| `ReadHeaderTimeout` | The time to send the request line and headers. The slowloris defence |
| `ReadTimeout` | The time to send the whole request, body included |
| `WriteTimeout` | The time the handler and the response may take |
| `IdleTimeout` | How long a kept-alive connection may sit between requests |
| `MaxHeaderBytes` | The size of the request line and headers |

Switchyard's server will set all of them in lesson 09.

## Break it

**Your by-hand server has the same flaw.** Run `/tmp/byhand`, then the half-request from step 4 against port 8080: it waits forever too, because `serve` never sets a deadline. Fix it the way you did in Foundations 04: `conn.SetReadDeadline(time.Now().Add(2 * time.Second))` before each `readRequest`, and check that the half-request is now cut off after 2 seconds while `curl`'s two kept-alive requests still work.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test ./drills/byhand
~~~

Then, without the lesson: write by hand, in `printf`, a `POST` with a 3-byte body followed by a `GET` on the same connection, send both to `/tmp/byhand` with one `nc`, and explain each line of what comes back.

That proves you know what's on the wire under `net/http`, and which limits it leaves to you. It doesn't build a real service: the next lesson starts Switchyard's.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `bind: address already in use` | An earlier `/tmp/byhand` or `/tmp/stdhttp` is still running | `pkill -x byhand; pkill -x stdhttp` |
| `curl` hangs after sending | The server didn't send `Content-Length`, so `curl` waits for more | Always send it (or close the connection after the body) |
| The second request on a connection is garbage | The first body was read with the wrong length | Read exactly `Content-Length` bytes with `io.ReadFull` |
| `400` for a request that looks fine | A header line without `:`, or a space before the colon | Check with `printf ... \| od -c` |
| The half-request test shows 6000 ms for `-safe` | `ReadHeaderTimeout` isn't set, or the server you're talking to is an old copy | `pkill -x stdhttp`, rebuild, rerun |
