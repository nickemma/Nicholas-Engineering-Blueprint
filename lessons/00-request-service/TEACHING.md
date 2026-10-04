# Phase 0 teaching: from a Go program to one HTTP request

This guide assumes you have never used Go, Bash, Linux, or HTTP. Every idea is explained before you use it. You do not need to read a book first.

**The goal:** make a small program answer an HTTP request, inspect the answer, change the program on purpose, test it, and explain how a request reaches your code and how the answer gets back.

**Time:** about two weeks at 12–15 hours a week. Going faster is fine if you can pass the checkpoint at the end.

**What you will have at the end:** a Go web service with three routes, input validation, three levels of tests, your own GitHub repository with CI, and a written explanation in your own words.

## How this guide works

The guide is split into steps. Each step has the same parts:

| Part | What it gives you |
|---|---|
| **The problem** | Why this step exists: what is missing or broken without it |
| **New ideas** | Each new word or concept, defined before you need it |
| **The code** | The code for this step, explained line by line. You type it yourself. (CI builds the code from this guide on every change, so every step is known to work.) |
| **Run it** | The exact commands and the output you should see |
| **Break it** | A deliberate mistake. Predict what will happen, then run it. This is where most of the learning happens |
| **Explain it** | Questions to answer in your own words in [learned.md](learned.md) |
| **Read** | A specific chapter, and why now is the right time to read it |

The steps build one program, a little at a time:

| Step | What you add |
|---|---|
| 1 | A program that prints and exits |
| 3 | A server with one route |
| 4 | A JSON response and a method check |
| 5 | A router, a greeting, and input validation |
| 6 | Tests at three levels: the finished Phase 0 service |

You type everything yourself, in a `practice/` folder, as you read. There's no finished version to copy. When something doesn't work, read the error message carefully, compare it with the explanation, and check [If it goes wrong](#if-it-goes-wrong). Working that out is a large part of the learning.

If something goes wrong at any point, check [If it goes wrong](#if-it-goes-wrong) at the end.

## Before you start: install the tools

You need four things:

| Tool | Why | Install | Check it works |
|---|---|---|---|
| Go 1.26 or newer | The language the service is written in | [go.dev/doc/install](https://go.dev/doc/install) | `go version` prints `go version go1.26...` |
| Git | Saves versions of your work and talks to GitHub | [git-scm.com/downloads](https://git-scm.com/downloads) | `git --version` |
| curl | Sends HTTP requests from the terminal | Built into macOS and most Linux; on Windows use WSL | `curl --version` |
| An editor | Where you write code | [VS Code](https://code.visualstudio.com/) with the official Go extension | It opens `.go` files with colors |

On Windows, install [WSL](https://learn.microsoft.com/windows/wsl/install) and do everything inside its Ubuntu terminal. Every later phase assumes a Linux shell.

Get this repository onto your computer:

~~~bash
git clone https://github.com/nickemma/Nicholas-Engineering-Blueprint.git
cd Nicholas-Engineering-Blueprint
~~~

**git clone** downloads a repository and its history. **cd** moves into the folder it created. All paths in this guide start from this folder, which we call the *repository root*.

---

## Step 0: The terminal

**The problem.** Everything in this program is started, inspected and stopped from a terminal. You need a handful of commands before writing any code.

**New ideas.**

- A **terminal** is a window where you type commands. **Bash** (or zsh on macOS, which behaves the same here) is the program that reads what you type and runs it.
- A command has a **name**, optional **flags** that change its behaviour, and optional **arguments** it acts on. In `mkdir -p practice`, `mkdir` is the name, `-p` is a flag and `practice` is the argument.
- A **path** names a file or folder. A path that begins with `/` is *absolute* (it starts from the top of the disk). Any other path is *relative* to the folder you're in now, the *current directory*.
- `.` means the current directory and `..` means its parent.

Run these one at a time from the repository root:

~~~bash
pwd
ls
cd lessons/00-request-service
ls
mkdir -p practice
cd practice
pwd
~~~

| Command | What it does |
|---|---|
| `pwd` | Prints the current directory ("print working directory"). Use it whenever you're unsure where you are |
| `ls` | Lists what is in the current directory. In `lessons/00-request-service` you should see `README.md`, `TEACHING.md`, `learned.md` and `exercises.md` |
| `cd path` | Changes the current directory |
| `mkdir -p practice` | Makes a folder called `practice`. `-p` means "don't complain if it already exists" |

Your last `pwd` should end with `lessons/00-request-service/practice`. This folder is listed in the repository's `.gitignore`, so Git ignores it: it's your scratch space.

Now create a Go **module**, which is Go's name for a project:

~~~bash
go mod init kestrel-phase0
~~~

This writes one file, `go.mod`, which names the module and records the Go version. Run `ls` to see it. It doesn't create any code yet.

---

## Step 1: A program and a process
<!-- run: go mod init kestrel-phase0 -->


**The problem.** Before a program can answer requests, you need to know how Go source code becomes something that runs.

<!-- file: main.go -->
~~~go
package main

import "fmt"

func main() {
	fmt.Println("Hello, Kestrel!")
}
~~~

Create `main.go` in your `practice` folder with exactly this content. In VS Code, use File → New File and save it as `main.go` inside `practice`. In a terminal you can use `nano main.go`, then Ctrl+O, Enter to save and Ctrl+X to exit.

**New ideas.** Read the program from the outside in:

- `package main`: Go code is organised into packages. The name `main` is special: it means "this builds into a program you can run".
- `import "fmt"` makes the standard `fmt` (format) package available. A package is a named collection of ready-made functions.
- `func main() { ... }` defines a **function** named `main`. A function is a named block of work. When the program starts, Go runs `main`, and when `main` ends, the program ends.
- `fmt.Println("Hello, Kestrel!")` **calls** the `Println` function from `fmt`: run it now, with this input. The text in quotes is a **string**, a piece of text. `Println` prints it followed by a newline.
- Braces `{ }` mark where a block starts and ends. Parentheses `( )` hold a function's inputs.
- Go is **case-sensitive**: `Println` and `PrintLn` are different names.

**Run it.**

~~~bash
go run .
~~~

~~~text
Hello, Kestrel!
~~~

`go run .` compiles the module in the current directory (`.`) and starts it. **Compiling** means translating the source code into machine instructions the computer runs directly.

Now do the two halves separately, which shows what `go run` hides:

~~~bash
go build -o hello .
ls -l hello
./hello
~~~

`go build -o hello .` compiles into a file called `hello` and stops. `ls -l` shows that `hello` is a real file of a few megabytes: the **program**, sitting on disk doing nothing. `./hello` starts it. While it runs, the operating system treats it as a **process**: a running instance of a program, with its own memory and an ID number. You can start the same program many times and get many processes. This one prints and exits so quickly that you can't see the process. In step 3 you'll see one that stays alive.

Delete the binary so it doesn't clutter your folder: `rm hello`.

**Break it.** Change `Println` to `PrintLn`, predict what happens, then run `go run .`:

~~~text
# kestrel-phase0
./main.go:6:6: undefined: fmt.PrintLn (but have Println)
~~~

`./main.go:6:6` means "file main.go, line 6, column 6". The compiler checks names before it builds anything, so the program never starts. Get into the habit of reading the first error line carefully: it nearly always tells you the file, the position and the cause. Change it back.


**Explain it** in learned.md: what is the difference between a program and a process? What did `go run .` do that `go build` didn't?

<!-- run: go vet ./... && go run . | grep -qx "Hello, Kestrel!" -->

---

## Step 2: What a request and a response are

**The problem.** A program that prints and exits can't serve anyone. A *server* stays running and waits for other programs to contact it. Before writing one, you need the vocabulary.

**New ideas.**

- The program that asks is the **client**. The program that waits and answers is the **server**. In this phase the client is `curl` and the server is your Go program.
- **HTTP** is the agreed format they use. The client sends a **request**: a **method** (what action, such as `GET` to read), a **path** (which thing, such as `/health`), some **headers** (extra labelled information) and sometimes a **body** (data).
- The server sends back a **response**: a **status code** (a number saying how it went), headers, and a body.

~~~mermaid
sequenceDiagram
    participant C as Client (curl)
    participant S as Server (your Go process)
    C->>S: GET /health HTTP/1.1<br/>Host: 127.0.0.1:8080
    S-->>C: HTTP/1.1 200 OK<br/>Content-Type: application/json<br/><br/>{"status":"ok"}
~~~

Status codes come in families. You'll use these:

| Code | Name | Meaning in this phase |
|---|---|---|
| 200 | OK | It worked |
| 400 | Bad Request | The client sent input that breaks the rules |
| 404 | Not Found | No such path |
| 405 | Method Not Allowed | The path exists but not for that method |

Codes in the 2xx range mean success, 4xx means the client made a mistake, and 5xx means the server failed.

A URL such as `http://127.0.0.1:8080/health` has four parts:

| Part | Meaning |
|---|---|
| `http` | The **scheme**: which protocol to speak |
| `127.0.0.1` | The **address**. This one is special: the *loopback* address, meaning "this same computer". Requests to it never leave your machine |
| `8080` | The **port**. One computer runs many servers, and each listens on its own port number. The operating system uses the port to decide which process receives a connection |
| `/health` | The **path** |

You'll write `localhost` sometimes: it's a name that resolves to the loopback address.

**Read.** Now that you have the vocabulary, read *Computer Networking: A Top-Down Approach* (Kurose & Ross, 8th ed.), sections 2.1–2.2, on the Web and HTTP. Skim 1.1–1.5 if you want the bigger picture. You don't need sockets or TCP yet: those come in Phase 2.

---

## Step 3: Turn the program into a server

**The problem.** You need a program that stays running, accepts connections on a port, and runs your code for each request.

Replace `main.go` with:

<!-- file: main.go -->
~~~go
package main

import (
	"fmt"
	"log"
	"net/http"
)

func health(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "healthy")
}

func main() {
	http.HandleFunc("/health", health)

	log.Println("server listening on http://127.0.0.1:8080")
	if err := http.ListenAndServe("127.0.0.1:8080", nil); err != nil {
		log.Fatal(err)
	}
}
~~~

**New ideas.**

- `import ( ... )` imports several packages at once. `net/http` is Go's HTTP package, and `log` prints messages with a timestamp.
- `func health(w http.ResponseWriter, r *http.Request)` is a **handler**: a function that handles one request. The names in parentheses are its **parameters**, the inputs it receives, each followed by its **type**:
  - `w` is where you write the response. Anything written to `w` goes back to the client.
  - `r` holds the request: its method, path, headers and body. The `*` means `r` is a **pointer**, a reference to the request data rather than a copy of it. For now, read `*http.Request` as "the request".
- `fmt.Fprintln(w, "healthy")` prints into `w` instead of into the terminal. The `F` stands for "file", meaning any destination you name.
- `http.HandleFunc("/health", health)` **registers** the handler: "when a request for `/health` arrives, call `health`". This does not call `health` now. Notice there are no parentheses after `health`: you pass the function itself, not its result.
- `http.ListenAndServe("127.0.0.1:8080", nil)`:
  - starts **listening** on port 8080 of the loopback address;
  - then, forever, accepts each connection, reads the request and calls the matching handler.
  - `nil` means "no value". Here it means "use the default router", which is where `http.HandleFunc` registered the route.
- `if err := ...; err != nil { ... }` is Go's error pattern. Functions that can fail return an **error**. If it isn't `nil`, something went wrong. `log.Fatal(err)` prints the error and exits. `ListenAndServe` only returns if it can't start, or the server stops.

**Run it.**

~~~bash
go run .
~~~

~~~text
2026/10/04 10:46:51 server listening on http://127.0.0.1:8080
~~~

The terminal does **not** return to a prompt. That's correct: the process is alive and waiting. **Open a second terminal**, `cd` into the same `practice` folder, and send a request:

~~~bash
curl -i http://127.0.0.1:8080/health
~~~

~~~text
HTTP/1.1 200 OK
Date: Sun, 04 Oct 2026 17:47:15 GMT
Content-Length: 8
Content-Type: text/plain; charset=utf-8

healthy
~~~

`-i` tells curl to show the status line and headers, not just the body. Your date will differ. Go filled in the status `200`, `Content-Length` (8 bytes: `healthy` plus a newline) and `Content-Type` automatically, because the handler wrote a body without choosing otherwise.

**See the process.** While the server runs, in the second terminal:

~~~bash
ss -ltnp | grep 8080
~~~

~~~text
LISTEN 0  4096  127.0.0.1:8080  0.0.0.0:*  users:(("kestrel-phase0",pid=186900,fd=4))
~~~

`ss` lists network sockets. `-l` shows only listening ones, `-t` TCP, `-n` numbers instead of names and `-p` the owning process. The `|` (a **pipe**) sends the output of `ss` into `grep`, which keeps only lines containing `8080`. You can see your process name (from the module name), its process ID and the port it holds. On macOS, use `lsof -iTCP:8080 -sTCP:LISTEN` instead.

The whole path of one request:

~~~mermaid
flowchart LR
    A[curl sends<br/>GET /health] --> B[OS delivers the connection<br/>to the process on port 8080]
    B --> C[Go's HTTP server<br/>reads the request]
    C --> D[Router matches /health]
    D --> E["health(w, r) writes<br/>'healthy' to w"]
    E --> F[Go sends status, headers<br/>and body back]
    F --> G[curl prints them]
~~~

Stop the server with **Ctrl+C** in its terminal. Ctrl+C sends the process an *interrupt signal*, and by default it exits. Phase 1 handles that signal properly. Run the curl again: it now fails with `Failed to connect`, because nothing is listening.

**Break it**, one at a time. Predict first, then run. Restore the code after each one.

1. **Print to the wrong place.** Change `fmt.Fprintln(w, "healthy")` to `fmt.Println("healthy")`. curl gets `200 OK` with `Content-Length: 0` and an empty body, and `healthy` appears in the *server's* terminal instead. The client only receives what is written to `w`.
2. **Try another method.** With the original code, run `curl -i -X POST http://127.0.0.1:8080/health`. It returns `200 OK`. This handler never looks at the method, so it answers `POST`, `DELETE`, anything. Step 4 fixes that.
3. **Start a second server.** Leave one running and run `go run .` in another terminal. It fails with `listen tcp 127.0.0.1:8080: bind: address already in use`. Only one process can listen on a port at a time.

**Explain it:** walk through the request path diagram in your own words. Which line in `main` registers the route, and which line starts the server? When does `health` actually run?

**Read.** You've now watched a process stay alive and stopped it. Read *Operating Systems: Three Easy Pieces* (OSTEP, free at [ostep.org](https://pages.cs.wisc.edu/~remzi/OSTEP/)): Chapter 2, *Introduction*, Chapter 4, *The Process*, and the first half of Chapter 5, *Process API*. Read with these questions: what is a process, how does it differ from the program file, and what does the OS keep track of for each one? Skip system-call details you don't follow yet.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Step 4: Give the response a contract

**The problem.** Callers can't rely on a response that is plain text and accepts any method. Programs that call a health check expect structured data. A **contract** is a promise about what a caller sends and what it gets back. The contract for this route is:

| Request | Response |
|---|---|
| `GET /health` | `200`, `Content-Type: application/json`, body `{"status":"ok"}` |
| Any other method on `/health` | `405`, with an `Allow: GET` header saying which method is accepted |

Replace `main.go` with:

<!-- file: main.go -->
~~~go
package main

import (
	"encoding/json"
	"log"
	"net/http"
)

type healthResponse struct {
	Status string `json:"status"`
}

func health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(healthResponse{Status: "ok"}); err != nil {
		log.Printf("write health response: %v", err)
	}
}

func main() {
	http.HandleFunc("/health", health)

	log.Println("server listening on http://127.0.0.1:8080")
	if err := http.ListenAndServe("127.0.0.1:8080", nil); err != nil {
		log.Fatal(err)
	}
}
~~~

**New ideas.**

- **JSON** is a text format for structured data, `{"status":"ok"}`, which almost every language can read.
- `type healthResponse struct { ... }` defines a **struct**, a data shape with named **fields**. This one has one field, `Status`, of type `string`.
- `` `json:"status"` `` is a **struct tag**: a label read by the JSON encoder, saying "call this field `status` in JSON".
- The field is `Status` with a capital S because, in Go, a capital first letter means **exported**: visible outside this package. The `encoding/json` package is outside your package, so it can only see exported fields. A lowercase `status` field would be silently skipped and you'd get `{}`.
- `r.Method != http.MethodGet`: `!=` means "is not equal to". `http.MethodGet` is a named **constant** for the text `"GET"`. Named constants catch typos that a plain string would hide.
- `w.Header().Set("Allow", http.MethodGet)` sets a response header. The HTTP standard says a 405 response should tell the client which methods *are* allowed.
- `http.Error(w, message, code)` writes a status code and a short plain-text body.
- `return` leaves the function **immediately**. Without it, the code below would run too and write the success response after the error. *Break it* proves this.
- `json.NewEncoder(w).Encode(...)` turns the struct into JSON and writes it to `w`.
- **Order matters**: headers must be set before the first byte of the body is written, because headers travel first. Once the body starts, the headers have already been sent.

**Run it.** Restart the server: Ctrl+C, then `go run .`. Then:

~~~bash
curl -i http://127.0.0.1:8080/health
curl -i -X POST http://127.0.0.1:8080/health
~~~

~~~text
HTTP/1.1 200 OK
Content-Type: application/json
Date: Sun, 04 Oct 2026 17:46:52 GMT
Content-Length: 16

{"status":"ok"}
~~~

~~~text
HTTP/1.1 405 Method Not Allowed
Allow: GET
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Sun, 04 Oct 2026 17:47:13 GMT
Content-Length: 19

method not allowed
~~~

`-X POST` tells curl which method to use. `http.Error` also added `X-Content-Type-Options: nosniff`, which tells browsers not to guess the content type: a small safety default.

**Break it.**

1. **Delete the `return`** after `http.Error`, then send the POST again:

   ~~~text
   HTTP/1.1 405 Method Not Allowed
   ...
   Content-Length: 35

   method not allowed
   {"status":"ok"}
   ~~~

   The function kept going after writing the error, so the client got *both* answers in one body: an error status with a success message attached. That's why every error branch ends with `return`. It isn't about retrying: it stops the handler from writing anything else.
2. **Move the header line** `w.Header().Set("Content-Type", ...)` to *after* the `Encode` block. GET now returns `Content-Type: text/plain; charset=utf-8`. The body went out first, so the headers had already been sent, and Go guessed the type from the body. Restore it.
3. **Lowercase the field**: rename `Status` to `status` in both places. Predict the body, then check it. The program still compiles, but the body is `{}`: the encoder can't see an unexported field. Now run `go vet .`, which catches it: `struct field status has json tag but is not exported`. That's why `go vet` is part of the everyday checks in step 6.


**Explain it:** why is the status code part of the contract, not a decoration? What exactly happened when you deleted `return`?

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Step 5: A router, a greeting, and input validation

**The problem.** The service now needs routes that take input from the caller. Input from outside is **untrusted**: it might be missing, empty, huge or strange. You also need to understand exactly how Go picks the handler for a request, because that will be wrong in subtle ways if you guess.

The contract for this step:

| Request | Response |
|---|---|
| `GET /` | `200`, `Hello from the request service!` |
| `GET /greet?name=Ada` | `200`, `Hello, Ada!` |
| `GET /greet` with a missing or blank name, or a name over 40 characters | `400`, `name must be between 1 and 40 characters` |
| `GET /health` | As in step 4 |
| Any path not listed | `404` |
| A non-GET method on any route | `405` with `Allow: GET` |

Replace `main.go` with:

<!-- file: main.go -->
~~~go
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"unicode/utf8"
)

const listenAddress = "127.0.0.1:8080"

const maxNameLength = 40

type healthResponse struct {
	Status string `json:"status"`
}

func methodNotAllowed(w http.ResponseWriter, allowed string) {
	w.Header().Set("Allow", allowed)
	http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
}

func health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(healthResponse{Status: "ok"}); err != nil {
		log.Printf("write health response: %v", err)
	}
}

func greet(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}

	fmt.Fprintln(w, "Hello from the request service!")
}

func greetName(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}

	name := strings.TrimSpace(r.URL.Query().Get("name"))
	if name == "" || utf8.RuneCountInString(name) > maxNameLength {
		http.Error(w, "name must be between 1 and 40 characters", http.StatusBadRequest)
		return
	}

	fmt.Fprintf(w, "Hello, %s!\n", name)
}

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/", greet)
	mux.HandleFunc("/greet", greetName)
	mux.HandleFunc("/health", health)
	return mux
}

func main() {
	log.Printf("server listening on http://%s", listenAddress)
	if err := http.ListenAndServe(listenAddress, newMux()); err != nil {
		log.Fatal(err)
	}
}
~~~

**New ideas: structure.**

- `const listenAddress = ...` and `const maxNameLength = 40` name values that would otherwise be "magic numbers" scattered through the code. Change one line and every use follows.
- `methodNotAllowed` is a small **helper function**. Three handlers need the same two lines, and if they were copied three times, one copy would eventually drift. A helper keeps them identical. That's refactoring: improving the structure without changing behaviour.
- `newMux()` builds and **returns** a router. `*http.ServeMux` after the parentheses is the **return type**: what the function hands back. Two reasons to build the router this way instead of using the default one from step 3:
  1. The default router is a **global**: any code in the program, including libraries, can register routes on it. An explicit router contains only what you put there.
  2. A function that returns the router can be called from a **test**, so you can test routing without starting a real server. You'll do exactly that in step 6.

**New ideas: how a request picks its handler.** This is the part most people guess at. A `ServeMux` (Go's router, "multiplexer") follows two rules for patterns like these:

1. A pattern **without** a trailing slash, like `/greet` or `/health`, matches **only that exact path**.
2. A pattern **ending in** `/` matches that path **and everything under it**. `/` ends in a slash, so it matches *every* path. It's the catch-all.

When several patterns match, the **longest, most specific one wins**.

| Request path | Patterns that match | Winner | Why |
|---|---|---|---|
| `/health` | `/health`, `/` | `health` | The exact match is more specific |
| `/greet?name=Ada` | `/greet`, `/` | `greetName` | The query (`?name=Ada`) is not part of the path |
| `/` | `/` | `greet` | Only match |
| `/unknown` | `/` | `greet` | The catch-all. That's why `greet` checks `r.URL.Path != "/"` and returns a 404 itself |

The router chooses a handler by **path**. The **method** is checked inside each handler, which is why every handler starts with a method check. (Phase 1 uses Go's newer patterns, like `GET /jobs/{id}`, which put the method into the route. You'll appreciate them more for having done it by hand first.)

**New ideas: validation.**

- `r.URL.Query().Get("name")` reads the **query string**, the part after `?`, and returns the value of `name`. If there is no `name`, it returns the empty string `""`. It doesn't fail.
- `strings.TrimSpace(...)` removes spaces at both ends, so `"  Ada "` becomes `"Ada"` and `"   "` becomes `""`.
- `name == "" || ...`: `||` means "or". If either condition is true, the input is rejected.
- `utf8.RuneCountInString(name)` counts **characters**, not **bytes**. Text is stored as bytes, and `a` is 1 byte but `é` is 2 bytes and some emoji are 4. `len(name)` would count bytes, so a 40-character name in another alphabet could be rejected as "too long". The tests check this case.
- `http.StatusBadRequest` is 400: "your input broke the rules". It tells the caller the fix is on their side.
- `fmt.Fprintf(w, "Hello, %s!\n", name)` is *formatted* printing: `%s` is replaced by `name`, and `\n` is a newline.

**Validation is a contract, not a guarantee of safety.** It rejects input the handler isn't designed for and gives the caller a clear reason. It doesn't make every input harmless. Here the name is echoed back as plain text, which is fine. If it were echoed into an HTML page, it could become an injection attack (a "cross-site scripting" bug). Every "the caller's text goes into my output" path deserves that question. Phases 1, 6 and 8 come back to it.

**Run it.** Restart the server, then:

~~~bash
curl -i http://127.0.0.1:8080/
curl -i 'http://127.0.0.1:8080/greet?name=Ada'
curl -i 'http://127.0.0.1:8080/greet'
curl -i 'http://127.0.0.1:8080/greet?name=%20%20'
curl -i http://127.0.0.1:8080/unknown
~~~

The single quotes stop the shell from treating `?` and `&` as special characters. `%20` is how a URL writes a space. Expected status lines and bodies:

| Request | Status | Body |
|---|---|---|
| `/` | `200 OK` | `Hello from the request service!` |
| `/greet?name=Ada` | `200 OK` | `Hello, Ada!` |
| `/greet` | `400 Bad Request` | `name must be between 1 and 40 characters` |
| `/greet?name=%20%20` | `400 Bad Request` | `name must be between 1 and 40 characters` |
| `/unknown` | `404 Not Found` | `404 page not found` |

**Break it.** Delete the four lines that check `r.URL.Path != "/"` in `greet`, restart, and request `/unknown`. You get `200 OK` with the greeting: the catch-all answered a path it was never meant to. A wrong 200 is worse than a 404, because the caller believes it worked. Restore the check.


**Explain it:** for `GET /greet?name=Ada`, which patterns match, which handler runs, and why? Why does `greet` need its own path check?

**Read.** Now that you've rejected hostile input yourself, skim the [OWASP API Security Top 10](https://owasp.org/API-Security/editions/2023/en/0x11-t10/) introduction and *API8: Security Misconfiguration*. If you have *The Web Application Hacker's Handbook* (2nd ed.), skim Chapter 3, on how applications receive client-controlled input.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Step 6: Tests at three levels

**The problem.** Checking by hand with curl is slow, easy to forget, and runs only on your machine. A **test** is code that checks your code automatically, in seconds, every time.

### 6a. A first test: call the handler directly

Create `main_test.go` next to `main.go`. Go treats any file ending in `_test.go` as test code. Start with one test:

<!-- file: main_test.go -->
~~~go
package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthReturnsOK(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	response := httptest.NewRecorder()

	health(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if body := response.Body.String(); body != "{\"status\":\"ok\"}\n" {
		t.Fatalf("body = %q, want health JSON", body)
	}
}
~~~

<!-- run: go test ./... -->

**New ideas.**

- A test function's name starts with `Test` and it takes `t *testing.T`, the tool for reporting failures.
- `httptest.NewRequest` builds a request **in memory**: no network, no server.
- `httptest.NewRecorder` builds a fake `w` that records what the handler writes.
- `health(response, request)` calls the handler directly, exactly as the server would.
- `t.Fatalf(...)` marks the test as failed, prints the message and stops this test. `%d` formats a number and `%q` formats a string with quotes, so invisible characters like `\n` show up.
- `"{\"status\":\"ok\"}\n"`: inside a Go string, `\"` is a literal quote and `\n` is a newline (the encoder adds one).

~~~bash
go test
~~~

~~~text
PASS
ok  	kestrel-phase0	0.004s
~~~

**Break it: watch a test catch a change.** In `main.go`, change `Status: "ok"` to `Status: "ready"`, then run `go test`:

~~~text
--- FAIL: TestHealthReturnsOK (0.00s)
    main_test.go:22: body = "{\"status\":\"ready\"}\n", want health JSON
FAIL
~~~

The test names the file and line, what it got and what it wanted. **When a test fails, read the actual value first.** Never edit a test just to make it pass, unless the contract itself changed on purpose. Restore `"ok"`.

### 6b. Test the routing with a table

The 6a test proves `health` works, but not that `/health` reaches it. If you misspelled the route in `newMux`, it would still pass. So the next level sends requests through the router.

Write one test per behaviour in a **table**: a list of cases, each with an input and an expected output, run in a loop. First add `net/url` and `strings` to the imports. Change:

<!-- edit: main_test.go -->
~~~go
import (
	"net/http"
	"net/http/httptest"
	"testing"
)
~~~

to:

~~~go
import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)
~~~

Then add this test at the end of the file:

<!-- append: main_test.go -->
~~~go
func TestRoutes(t *testing.T) {
	fortyAccents := url.QueryEscape(strings.Repeat("é", 40))

	tests := []struct {
		name       string
		method     string
		target     string
		wantStatus int
		wantBody   string
	}{
		{"root greeting", http.MethodGet, "/", http.StatusOK, "Hello from the request service!"},
		{"root rejects POST", http.MethodPost, "/", http.StatusMethodNotAllowed, "method not allowed"},
		{"unknown path", http.MethodGet, "/unknown", http.StatusNotFound, "404 page not found"},
		{"health", http.MethodGet, "/health", http.StatusOK, `{"status":"ok"}`},
		{"health rejects POST", http.MethodPost, "/health", http.StatusMethodNotAllowed, "method not allowed"},
		{"greet with name", http.MethodGet, "/greet?name=Ada", http.StatusOK, "Hello, Ada!"},
		{"greet trims spaces", http.MethodGet, "/greet?name=%20Ada%20", http.StatusOK, "Hello, Ada!"},
		{"greet missing name", http.MethodGet, "/greet", http.StatusBadRequest, "name must be between 1 and 40 characters"},
		{"greet blank name", http.MethodGet, "/greet?name=%20%20", http.StatusBadRequest, "name must be between 1 and 40 characters"},
		{"greet accepts 40 characters", http.MethodGet, "/greet?name=" + strings.Repeat("a", 40), http.StatusOK, "Hello, "},
		{"greet rejects 41 characters", http.MethodGet, "/greet?name=" + strings.Repeat("a", 41), http.StatusBadRequest, "name must be between 1 and 40 characters"},
		{"greet counts characters, not bytes", http.MethodGet, "/greet?name=" + fortyAccents, http.StatusOK, "Hello, "},
		{"greet rejects POST", http.MethodPost, "/greet?name=Ada", http.StatusMethodNotAllowed, "method not allowed"},
	}

	mux := newMux()
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			request := httptest.NewRequest(tt.method, tt.target, nil)
			response := httptest.NewRecorder()

			mux.ServeHTTP(response, request)

			if response.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d", response.Code, tt.wantStatus)
			}
			if body := response.Body.String(); !strings.Contains(body, tt.wantBody) {
				t.Fatalf("body = %q, want it to contain %q", body, tt.wantBody)
			}
		})
	}
}
~~~

**New ideas.**

- `[]struct{ ... }{ ... }` is a **slice** (a list) of an unnamed struct type, filled in with one line per case. Adding a new case is now one line.
- `for _, tt := range tests` loops over the cases. `range` gives an index and a value, and `_` throws the index away.
- `t.Run(tt.name, ...)` runs each case as a **subtest** with its own name, so a failure tells you exactly which case broke.
- `mux.ServeHTTP(response, request)` hands the request to the **router**, which picks the handler just as the real server would.
- **Boundary cases**: the table tests 40 characters (allowed) *and* 41 (rejected). Bugs hide at edges: `>` vs `>=` is a one-character mistake that only a boundary test catches.
- `url.QueryEscape` encodes `é` safely for a URL. Forty `é` characters are 80 bytes, so this case proves the rule counts characters.

Run them with names shown:

~~~bash
go test -v -run TestRoutes
~~~

`-v` (verbose) lists every subtest, and `-run` picks tests by name. Spaces in subtest names become underscores: `TestRoutes/greet_with_name`. To run only the cases whose names *start* with "greet", use `go test -v -run 'TestRoutes/^greet'`. `^` means "starts with", and without it `root_greeting` would match too.

### 6c. Test over a real connection

Add this test at the end of `main_test.go`:

<!-- append: main_test.go -->
~~~go
func TestServerOverRealConnection(t *testing.T) {
	server := httptest.NewServer(newMux())
	defer server.Close()

	response, err := http.Get(server.URL + "/health")
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusOK)
	}
	if string(body) != "{\"status\":\"ok\"}\n" {
		t.Fatalf("body = %q, want health JSON", body)
	}
}
~~~

`httptest.NewServer` starts a real HTTP server on a random free port on the loopback address. `http.Get` is a real HTTP client: this request goes through the operating system's networking, like curl's does. `defer` means "run this when the function ends, however it ends", which guarantees the server is shut down and the body closed. It reads the body with `io.ReadAll`, so add `io` to the imports:

<!-- edit: main_test.go -->
~~~go
import (
	"net/http"
~~~

becomes:

~~~go
import (
	"io"
	"net/http"
~~~

<!-- run: go test ./... -->

### What each level proves

| Check | Proves | Does **not** prove |
|---|---|---|
| Handler test (6a) | The handler's logic gives the right status and body | That any route reaches it |
| Router table (6b) | Paths reach the right handlers; every rule and edge case | That bytes cross a real connection |
| Real connection (6c) | The service works over real HTTP | That *your* `main` starts on port 8080 |
| curl against `go run .` | The actual program starts, listens and answers | Anything about cases you didn't try |

No single check proves everything, so you use several. Phase 1 adds a fifth: checking what happens when many requests arrive at once.

**Your turn.** Write two more tests yourself, using the ones above as a pattern:

- `TestHealthSetsJSONContentType`: `GET /health` has the header `Content-Type: application/json`. (Read a response header with `response.Header().Get("Content-Type")`.)
- `TestHealthRejectsPost`: `POST /health` returns 405, **and** its `Allow` header is `GET`.

Run `go test -v` and check that both appear and pass. Then break `health` on purpose (delete the `Allow` line) and confirm your second test catches it.

### The everyday checks

~~~bash
gofmt -l .
go vet ./...
go test -race -cover ./...
~~~

| Command | What it does | Good output |
|---|---|---|
| `gofmt -l .` | Lists files not in Go's standard layout. `gofmt -w .` fixes them | Nothing |
| `go vet ./...` | Finds suspicious code that compiles but is probably wrong | Nothing |
| `go test -race -cover ./...` | Runs every test, watches for unsafe memory sharing (Phase 1 explains this), and reports how much code the tests ran | `ok  kestrel-phase0  ...  coverage: 87.1% of statements` |

`./...` means "this folder and every folder below it". Coverage isn't 100% because `main()` itself and the JSON-write error branch never run in tests. That's acceptable: coverage shows what *wasn't* exercised, and is not a target to maximise.

### Test-driven development (TDD)

You wrote code first and tests second. **TDD** flips the order, in a three-beat loop:

1. **Red:** write a test for behaviour that doesn't exist yet, and watch it fail. That failure proves the test can catch a problem.
2. **Green:** write the smallest code that makes it pass.
3. **Refactor:** clean up the code with the test as a safety net.

From Phase 1 on, every feature is built this way. Practise now with the first two exercises in [exercises.md](exercises.md).


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

---

## Step 7: Your own repository and CI

**The problem.** Work that exists only on your laptop can be lost. Nobody else can see it, and it may secretly depend on something only your machine has. You'll now rebuild Phase 0 in **your own** GitHub repository and have GitHub test it on every push.

This is also the **rebuild rule** used at the end of every phase: close the guide, and build it again from the contract tables and your notes. Looking up Go documentation is allowed, but copying the lesson code is not. If you can rebuild it, you understand it. If you can't, the spot where you got stuck is exactly what to review.

> **Run locally.** These steps need your GitHub account, so CI can't check them for you. The expected results are described for each one.

1. On GitHub, create a new **empty** repository named `kestrel`: no README, no licence.
2. On your computer, *outside* the Blueprint folder:

   ~~~bash
   mkdir -p ~/code/kestrel
   cd ~/code/kestrel
   git init
   go mod init github.com/YOUR-USERNAME/kestrel
   ~~~

   `git init` makes this folder a Git repository. The module name now matches where the code will live, which is the convention for real projects.

3. Rebuild `main.go` and `main_test.go` from memory. Run `go test ./...` until it passes.

4. Create `.github/workflows/test.yml`:

   ~~~yaml
   name: Test

   on:
     push:
     pull_request:

   jobs:
     test:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v6
         - uses: actions/setup-go@v7
           with:
             go-version-file: go.mod
         - run: test -z "$(gofmt -l .)"
         - run: go vet ./...
         - run: go test -race ./...
   ~~~

   **CI** (continuous integration) runs your checks on a fresh machine every time you push code. Line by line:
   - `on` lists the events that start the workflow: every push and pull request.
   - `runs-on` asks for a temporary Ubuntu machine.
   - `steps` run in order. `checkout` downloads your code. `setup-go` installs the Go version from your `go.mod`. Each `run` is a terminal command, and if any command fails, the run fails.
   - `test -z "$(gofmt -l .)"` fails if `gofmt` lists any unformatted file.

5. Save and publish:

   ~~~bash
   git status
   git add main.go main_test.go go.mod .github/workflows/test.yml
   git commit -m "Phase 0: request service with tests and CI"
   git branch -M main
   git remote add origin git@github.com:YOUR-USERNAME/kestrel.git
   git push -u origin main
   ~~~

   | Command | What it does |
   |---|---|
   | `git status` | Shows which files are new or changed. Run it before every `add` |
   | `git add files` | Selects exactly these files for the next save. Name them explicitly so you never commit something by accident |
   | `git commit -m "..."` | Saves a snapshot of the selected files with a message saying *why* |
   | `git branch -M main` | Names the branch `main` |
   | `git remote add origin URL` | Records where GitHub keeps your repository |
   | `git push -u origin main` | Uploads your commits |

   If the push is rejected for permissions, set up an SSH key: follow GitHub's guide, [Connecting to GitHub with SSH](https://docs.github.com/en/authentication/connecting-to-github-with-ssh).

6. **Expected result:** open your repository on GitHub, then the **Actions** tab. Within a minute or two, the "Test" run shows a green check. Open it to see each step's output.
7. **Break it.** Change `"ok"` to `"ready"`, then commit and push. The run turns red. Open the failing step and find the same failure message you saw locally. Fix it, push, and see green again. That red-then-green record is evidence a reviewer can see.

---

## Checkpoint: are you ready for Phase 1?

You're ready when you can do all of these **without looking at this guide**:

1. Start the service and use curl to show one successful request and three rejected ones (400, 404 and 405), pointing out the status, headers and body.
2. Explain the full request path, from curl to the handler and back, including how the router picked the handler and where the method is checked.
3. Explain what each test level proves and what it doesn't.
4. Show your CI history with one red run and the green fix.
5. Answer every question in [learned.md](learned.md) in your own words, each with the command or test output that backs it up.

If one is shaky, go back to its step, rerun its *Break it*, and write down what's still unclear. Advance when the evidence is there, not when the calendar says so.

## If it goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `go: command not found` | Go isn't installed or isn't on your PATH | Reinstall from go.dev and open a new terminal |
| `go: go.mod file not found` | You're in the wrong folder | Run `pwd`, then `cd` to the folder with `go.mod` |
| `curl: (7) Failed to connect ... Couldn't connect to server` | The server isn't running, or it's on another port | Check that the first terminal shows the "listening" line |
| `bind: address already in use` | Another server is already on 8080 | Stop it with Ctrl+C in its terminal, or find it with `ss -ltnp \| grep 8080` |
| curl gets `404` for a route you wrote | A typo in the pattern, or you didn't restart after editing | Edits only take effect after you stop and restart the server |
| `"fmt" imported and not used` | Go refuses unused imports | Remove the import, or use it |
| `declared and not used: x` | Go refuses unused variables | Remove the variable, or use it |
| Body is `{}` | The struct field is lowercase | Capitalise the field name |
| Test passes but curl disagrees | The test and the running code differ | Restart the server, and check you're testing the same file |

## Reading list for this phase

| When | Reading | Question to carry in |
|---|---|---|
| After step 2 | Kurose & Ross, *Computer Networking* (8th ed.), §2.1–2.2 (skim §1.1–1.5) | What exactly is in a request and a response? |
| After step 3 | OSTEP Ch. 2, Ch. 4 and the first half of Ch. 5 | What is a process, and what does the OS track for it? |
| After step 5 | OWASP API Security Top 10 introduction; *Web Application Hacker's Handbook* Ch. 3 (skim) | Which inputs come from the client, and what should be done with them? |
| After the phase | *Computer Systems: A Programmer's Perspective* (CSAPP, 3rd ed.), Ch. 1 | How does source code become a running program? |
| Reference, anytime | [A Tour of Go](https://go.dev/tour/), [Go by Example](https://gobyexample.com/), William Shotts' [*The Linux Command Line*](https://linuxcommand.org/tlcl.php) (free) | Use these to look things up, not to read cover to cover |
