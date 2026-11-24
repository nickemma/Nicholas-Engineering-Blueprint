# 05 What a request and a response are

> Module: Python and the internet from zero · Time: ~3 h · Builds on: 04

## The problem

Your echo server speaks a protocol you invented: a line in, the same line out. The web speaks **HTTP**, and so do most of the services you'll build and call from here on: every API in the core is HTTP, and so is the inference gateway in the AI track. HTTP looks like magic from inside a browser or a library, but on the wire it's lines of text over a TCP connection, much like yours. Once you've seen the bytes, a `400`, a missing header or a hanging request stops being a mystery.

## The mental model

The program that asks is the **client**; the program that waits and answers is the **server**. They take turns on one TCP connection:

~~~mermaid
sequenceDiagram
    participant C as Client (curl)
    participant S as Server
    C->>S: GET /health HTTP/1.1<br/>Host: 127.0.0.1:8080
    S-->>C: HTTP/1.1 200 OK<br/>Content-Type: application/json<br/><br/>{"status":"ok"}
~~~

~~~text
 request                                   response
 ┌──────────────────────────────────┐      ┌──────────────────────────────────┐
 │ GET /health HTTP/1.1             │      │ HTTP/1.1 200 OK                  │  start line
 │ Host: 127.0.0.1:8080             │      │ Content-Type: application/json   │  headers,
 │ User-Agent: curl/8.5.0           │      │ Content-Length: 16               │  one per line
 │ Accept: */*                      │      │                                  │  a blank line
 │                                  │      │ {"status":"ok"}                  │  the body
 └──────────────────────────────────┘      └──────────────────────────────────┘
 every line ends with \r\n
~~~

- The **request** starts with a **method** (what to do: `GET` reads, `POST` creates or submits, `PUT` replaces, `DELETE` removes), a **path** (which thing, such as `/health`), and the version.
- Then **headers**: labelled extra information, one per line, such as `Host` (which site; one server can host many) or `Content-Type` (what the body is).
- A blank line ends the headers. Then, sometimes, a **body**: the data.
- The **response** starts with a **status line**: the version, a **status code** (a number saying how it went), and a short reason. Then headers, a blank line, and the body.
- `Content-Length` says how many bytes the body has, so the reader knows where it ends. That's HTTP's framing, the same job your `\n` does.

Status codes come in families:

| Code | Name | Means |
|---|---|---|
| 200 | OK | It worked |
| 301, 302 | Moved | Look at the URL in the `Location` header instead |
| 400 | Bad Request | The client sent input that breaks the rules |
| 404 | Not Found | No such path |
| 405 | Method Not Allowed | The path exists, but not for that method |
| 500 | Internal Server Error | The server failed |
| 503 | Service Unavailable | The server can't take the request right now; try later |

2xx means success, 3xx look elsewhere, 4xx the client made a mistake, 5xx the server failed. When you build an API, the family is a promise: a 4xx tells the caller not to retry the same request, and a 5xx says retrying might work.

A **URL** such as `http://127.0.0.1:8080/health` names everything the client needs:

| Part | Meaning |
|---|---|
| `http` | The **scheme**: which protocol to speak. `https` is HTTP inside an encrypted connection (TLS) |
| `127.0.0.1` | The **host**: an address, or a name to look up with DNS (lesson 02). `localhost` is a name for the loopback address |
| `8080` | The **port**. Leave it out and the scheme's default is used: 80 for `http`, 443 for `https` |
| `/health` | The **path**, sent in the request line |

## The pattern

**When an HTTP call misbehaves, look at the bytes.** `curl -v` prints the request it sends and the response headers it gets. A fake server made from `nc` shows exactly what a client sends. Between the two, you can tell whether the client or the server is wrong.

## Build it

### Step 1: See what a client sends

Make `nc` a fake server, and point `curl` at it. `nc` writes whatever arrives into a file and never answers, so `curl` gives up after a second (`-m 1`):

~~~bash
nc -l 127.0.0.1 8080 > /tmp/request.txt &
sleep 0.3; curl -s -m 1 http://127.0.0.1:8080/health; echo "curl exit: $?"
cat -A /tmp/request.txt
~~~

~~~text
curl exit: 28
GET /health HTTP/1.1^M$
Host: 127.0.0.1:8080^M$
User-Agent: curl/8.5.0^M$
Accept: */*^M$
^M$
~~~

That's an entire HTTP request: four lines and a blank line. `cat -A` shows invisible characters: `^M` is the carriage return `\r`, and `$` marks the end of each line, so every line ends with `\r\n`. `curl` exit code 28 means it timed out waiting for an answer; when it gave up and closed the connection, `nc` exited too.

### Step 2: Answer it by hand

Now give `nc` a response to send back: a status line, two headers, a blank line, and 16 bytes of body. `curl -v` shows both sides: `>` lines are what it sent, `<` lines what it received, and `*` lines are its notes. `-s` hides its progress meter.

~~~bash
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 16\r\n\r\n{"status":"ok"}\n' | nc -l 127.0.0.1 8080 > /dev/null &
sleep 0.3; curl -sv http://127.0.0.1:8080/health
~~~

~~~text
*   Trying 127.0.0.1:8080...
* Connected to 127.0.0.1 (127.0.0.1) port 8080
> GET /health HTTP/1.1
> Host: 127.0.0.1:8080
> User-Agent: curl/8.5.0
> Accept: */*
> 
< HTTP/1.1 200 OK
< Content-Type: application/json
< Content-Length: 16
< 
{ [16 bytes data]
* Connection #0 to host 127.0.0.1 left intact
{"status":"ok"}
~~~

`curl` accepted it as a real HTTP response, and printed the body. You've just written an HTTP server's output by hand. Every web framework, in every language, ends up writing these bytes.

### Step 3: A real server, by hand

Send a request to a real web server with nothing but `nc`. `Connection: close` asks the server to close the connection after answering, so `nc` exits:

~~~bash
printf 'GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n' | nc example.com 80 | head -16 | cut -c1-72
~~~

~~~text
HTTP/1.1 200 OK
Date: Thu, 19 Nov 2026 08:58:16 GMT
Content-Type: text/html; charset=utf-8
Transfer-Encoding: chunked
Connection: close
Server: cloudflare
Last-Modified: Wed, 18 Nov 2026 17:47:37 GMT
Allow: GET, HEAD
Accept-Ranges: bytes
Age: 3
cf-cache-status: HIT
CF-RAY: a5ce031e6ab6d179-AMS
alt-svc: h3=":443"; ma=86400

241
<!doctype html><html lang=en><head><meta charset=utf-8><link rel=icon hr
~~~

`head -16` keeps the first 16 lines and `cut -c1-72` the first 72 characters of each, because the page's HTML is one very long line.

- The status line and headers are the same shape as yours. `Server: cloudflare` says who's answering: example.com is served through Cloudflare.
- There's no `Content-Length`. Instead, `Transfer-Encoding: chunked` says the body comes in **chunks**, each one preceded by its size in hexadecimal: the line after the blank line, just before the HTML. A size of `0` ends the body. Servers use it when they don't know the length before they start sending.
- `cf-cache-status: HIT` and `Age` say the answer came from a cache near you, copied from the origin server some seconds ago.

### Step 4: The same with `curl`, and status codes

`curl` builds the request, follows the framing and handles TLS for you:

~~~bash
curl -v -o /dev/null http://example.com/ 2>&1 | grep -E "^[<>*]"
~~~

~~~text
* IPv6: 2606:4700:10::ac42:93f3, 2606:4700:10::6814:179a
* IPv4: 172.66.147.243, 104.20.23.154
*   Trying 172.66.147.243:80...
* Connected to example.com (172.66.147.243) port 80
> GET / HTTP/1.1
> Host: example.com
> User-Agent: curl/8.5.0
> Accept: */*
> 
< HTTP/1.1 200 OK
< Date: Thu, 19 Nov 2026 08:58:17 GMT
< Content-Type: text/html; charset=utf-8
< Transfer-Encoding: chunked
< Connection: keep-alive
< Server: cloudflare
< Last-Modified: Wed, 18 Nov 2026 17:47:37 GMT
< Allow: GET, HEAD
< Accept-Ranges: bytes
< Age: 2
< cf-cache-status: HIT
< CF-RAY: a5ce03229b6765f1-AMS
< alt-svc: h3=":443"; ma=86400
< 
* Connection #0 to host example.com left intact
~~~

`curl` first looked up the name and got two IPv6 and two IPv4 addresses. It tried one, connected, and never needed the rest. (`curl` can try an IPv6 and an IPv4 address at nearly the same moment and keep whichever connects first, a technique called "happy eyeballs". On a machine with no IPv6 route, like this one, you may also see `Immediate connect fail ... Network is unreachable` lines for the IPv6 addresses before IPv4 wins.) Then it sent its request (`>`) and read the status line and headers (`<`). `-o /dev/null` threw the body away. This time the server says `Connection: keep-alive`: since `curl` didn't ask to close, the server is willing to take more requests on the same connection.

To see just the status codes, ask for an existing path, a missing one, and a method the server doesn't allow:

~~~bash
for path in / /nope; do curl -s -o /dev/null -w "GET $path -> %{http_code}\n" http://example.com$path; done
curl -s -o /dev/null -w "POST / -> %{http_code}\n" -X POST http://example.com/
~~~

~~~text
GET / -> 200
GET /nope -> 404
POST / -> 405
~~~

`-w` prints information about the request after it finishes; `%{http_code}` is the status code.

## Break it

**Speak HTTP to your echo server.** It reads lines and sends them back, so what does `curl` make of that? Start it from lesson 04, and ask it for a page:

~~~bash
cd ~/blueprint/internet/echo
go build -o /tmp/echo . && { /tmp/echo 2>/dev/null > /dev/null & sleep 0.5; curl -sv -m 2 http://127.0.0.1:9000/hello; echo "curl exit: $?"; kill %1; }
~~~

~~~text
*   Trying 127.0.0.1:9000...
* Connected to 127.0.0.1 (127.0.0.1) port 9000
> GET /hello HTTP/1.1
> Host: 127.0.0.1:9000
> User-Agent: curl/8.5.0
> Accept: */*
> 
* Received HTTP/0.9 when not allowed
* Closing connection
curl exit: 1
~~~

`curl` sent its request, and the echo server sent the same lines straight back. So the first line `curl` received was `GET /hello HTTP/1.1`, its own request line, where it expected a status line such as `HTTP/1.1 200 OK`. A reply that doesn't start with `HTTP/` looks like HTTP/0.9, the 1991 version that had no status line and no headers, which `curl` refuses unless asked: `Received HTTP/0.9 when not allowed`, exit code 1. Same TCP connection, same bytes, the wrong protocol. Two programs only understand each other if they agree on the protocol: who speaks first, what each line means, and where each message ends.

**Encryption.** Fetch the HTTPS version and look at what happens before the request:

~~~bash
curl -sv -o /dev/null https://example.com/ 2>&1 | grep -E "^\* (Connected|SSL connection|TLS|Server certificate|.*subject:|.*issuer:)|^> GET|^< HTTP"
~~~

~~~text
* Connected to example.com (172.66.147.243) port 443
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* TLSv1.3 (OUT), TLS change cipher, Change cipher spec (1):
* TLSv1.3 (OUT), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / X25519 / id-ecPublicKey
* Server certificate:
*  subject: CN=example.com
*  issuer: C=US; O=SSL Corporation; CN=Cloudflare TLS Issuing ECC CA 3
> GET / HTTP/2
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
< HTTP/2 200 
~~~

Port 443, then a TLS handshake (`TLSv1.3`) before the first byte of HTTP. The server proved who it is with a certificate for `example.com` (`subject`), signed by an authority that `curl` trusts (`issuer`). During the handshake, the two sides also agreed to speak HTTP/2, a newer, binary form of the same requests and responses; `curl -v` still prints it as text. Inside the encryption, it's the same conversation as before; `nc` can no longer read it, and neither can anyone between you and the server. TLS gets its own lessons in the core.

## Check it

1. Use `nc -l` to capture the exact request `curl -X POST -d 'name=ada' http://127.0.0.1:8080/users` sends. Which headers did `-d` add, and how does the server know where the body ends?
2. Write by hand a `404 Not Found` response with a short text body, serve it with `nc`, and check that `curl -s -w "%{http_code}"` prints `404`.
3. Read *Computer Networking: A Top-Down Approach* (Kurose & Ross, 8th ed.), sections 2.1–2.2, on the Web and HTTP. Skim 1.1–1.5 for the bigger picture.

That proves you can read and write HTTP at the level of bytes. You haven't written an HTTP server in code yet: that's the first build of the core, in Go, with a router, input checks and tests.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (7) Failed to connect ... Connection refused` | Nothing is listening on that port (lesson 03) | Start the server; check the port in the URL |
| `curl: (28) Operation timed out` | The server accepted but never answered | Expected in step 1. Otherwise the server is stuck: check its logs |
| `curl: (1) Received HTTP/0.9 when not allowed` | The reply doesn't start with an HTTP status line | The server isn't speaking HTTP; check the port |
| Your hand-written response hangs `curl` | `Content-Length` is bigger than the body, so `curl` waits for more | Count the bytes; `printf '...' \| wc -c` helps |
| `nc example.com 80` prints nothing | Some networks block port 80, or the request is missing the blank line | Use `curl -v` to check the network; end the request with `\r\n\r\n` |
