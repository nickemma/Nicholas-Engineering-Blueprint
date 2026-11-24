# 07 Run three real processes

> Core 07 · About 8 hours · Builds on the preceding lesson

## The problem

The simulator calls the core in order. A live peer receives ticks, HTTP requests, and client proposals concurrently. A slow or unavailable peer must not stall unrelated peers.

## The mental model

~~~text
HTTP peer requests --> bounded inbox
HTTP proposals      --> bounded inbox --> one Raft owner --> Rust WAL
ticker              ----------------->                 --> per-peer sender queues
                                                        --> metadata map / client reply
~~~

Each Go process owns one core and one Rust child. The core itself still reads no clocks or sockets. Peer messages use HTTP over Unix sockets. Each destination has a separate bounded sender queue and a deadline. The sender drops over-capacity messages. The core can recover through retries.

## The pattern

On every event, read the effects and save the batch before publishing them. Park a client proposal under its index and term. The applied result goes to the waiting client for that exact entry. An overwritten index, leadership change, or deadline can require a retry. A 504 leaves the outcome unknown in the general case. A get is a replicated command too, so an old leader needs a live quorum to answer it. The service rebuilds its map from the committed log on restart.

## Build it

### Step 1. Keep socket waits off the Raft loop

Create a bounded queue and one sender per destination. Finish `select { case queue <- message: default: /* TODO */ }` using the omission model.

<details>
<summary>Hint 1</summary>

A heartbeat or election round can produce another message.

</details>

<details>
<summary>Hint 2</summary>

Drop the send when the queue is full. Give each HTTP request its own bounded wait.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/metad/transport.go -->
~~~go
package metad

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"sync"
	"time"

	"switchyard/metad/internal/raft"
)

// Each destination has its own bounded queue and sender. Raft retries
// lost messages through subsequent heartbeats and election rounds.
type transport struct {
	queues []chan raft.Message
	stop   context.CancelFunc
	group  sync.WaitGroup
}

func newTransport(ctx context.Context, id int, routes []string) *transport {
	ctx, cancel := context.WithCancel(ctx)
	t := &transport{queues: make([]chan raft.Message, len(routes)+1), stop: cancel}
	for offset, path := range routes {
		peer := offset + 1
		if peer == id {
			continue
		}
		queue := make(chan raft.Message, 16)
		t.queues[peer] = queue
		t.group.Go(func() { sendLoop(ctx, path, queue) })
	}
	return t
}

func (t *transport) send(message raft.Message) {
	select {
	case t.queues[message.To] <- message:
	default:
	}
}

func (t *transport) close() {
	t.stop()
	t.group.Wait()
}

func sendLoop(ctx context.Context, path string, queue <-chan raft.Message) {
	wire := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", path)
		},
		MaxIdleConnsPerHost: 1,
	}
	defer wire.CloseIdleConnections()
	client := &http.Client{Transport: wire, Timeout: 200 * time.Millisecond}
	for ctx.Err() == nil {
		select {
		case <-ctx.Done():
			return
		case message := <-queue:
			payload, err := json.Marshal(message)
			if err != nil {
				continue
			}
			req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://peer/raft", bytes.NewReader(payload))
			if err != nil {
				continue
			}
			req.Header.Set("Content-Type", "application/json")
			response, err := client.Do(req)
			if err == nil {
				io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
				response.Body.Close()
			}
		}
	}
}
~~~

</details>

### Step 2. Apply commands in order

Build the metadata map and a return value that distinguishes an absent key from an empty value. Decide what to do with an election no-op.

<details>
<summary>Hint 1</summary>

The same committed input must yield the same result on every replica.

</details>

<details>
<summary>Hint 2</summary>

Only put changes the map. Get returns both the value and whether a key exists.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/metad/state.go -->
~~~go
package metad

import "switchyard/metad/internal/raft"

type Result struct {
	Found bool   `json:"found"`
	Value string `json:"value,omitempty"`
}

type state struct {
	values map[string]string
}

func newState() *state { return &state{values: make(map[string]string)} }

func (s *state) apply(command raft.Command) Result {
	switch command.Op {
	case "put":
		s.values[command.Key] = command.Value
		return Result{Found: true, Value: command.Value}
	case "get":
		value, found := s.values[command.Key]
		return Result{Found: found, Value: value}
	default:
		return Result{} // The election no-op changes no metadata.
	}
}
~~~

</details>

### Step 3. Own the loop

Add the runtime's single owner and the three input paths. Fill in `pending[index] = /* TODO */` so an entry from another term can't complete the wait.

<details>
<summary>Hint 1</summary>

The same index can hold a different term after conflict repair.

</details>

<details>
<summary>Hint 2</summary>

Save the originating term with the proposal. After saving, send messages and apply the entries. Complete only the matching waiter.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/metad/runtime.go -->
~~~go
// Package metad joins the Raft core to a writer, peers, and the client API.
package metad

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"switchyard/metad/internal/raft"
)

type Status struct {
	ID, Leader, Applied int
	Term                uint64
	Role                raft.Role
}

type outcome struct {
	result Result
	leader int
	code   int
}

type proposal struct {
	ctx     context.Context
	command raft.Command
	reply   chan outcome
}

type waiting struct {
	proposal
	term uint64
}

type Runtime struct {
	id       int
	members  int
	node     *raft.Node
	disk     interface{ Save(raft.Batch) error }
	messages chan raft.Message
	propose  chan proposal
	status   chan chan Status
}

func New(id, members int, seed int64, stable raft.Stable, disk interface{ Save(raft.Batch) error }) *Runtime {
	return &Runtime{
		id: id, members: members, node: raft.Restore(id, members, seed, stable), disk: disk,
		messages: make(chan raft.Message, 128), propose: make(chan proposal, 128),
		status: make(chan chan Status),
	}
}

func (r *Runtime) Run(ctx context.Context, routes []string) error {
	wire := newTransport(ctx, r.id, routes)
	defer wire.close()
	tick := time.NewTicker(25 * time.Millisecond)
	defer tick.Stop()
	pending := make(map[int]waiting)
	store := newState()
	status := Status{ID: r.id}

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-tick.C:
			r.node.Tick()
		case message := <-r.messages:
			r.node.Step(message)
		case answer := <-r.status:
			answer <- status
		case p := <-r.propose:
			switch {
			case p.ctx.Err() != nil:
			case len(pending) >= 128:
				p.reply <- outcome{code: 503}
			default:
				index, term, ok := r.node.Propose(p.command)
				if ok {
					pending[index] = waiting{proposal: p, term: term}
				} else {
					p.reply <- outcome{code: 409, leader: r.node.Leader()}
				}
			}
		}

		ready := r.node.Take()
		if err := r.disk.Save(ready.Save); err != nil {
			return fmt.Errorf("persist before sending: %w", err)
		}
		role, term := r.node.Role(), r.node.Term()
		if role == raft.Leader && (role != status.Role || term != status.Term) {
			log.Printf("elected peer=%d term=%d", r.id, term)
		}
		status.Role, status.Term, status.Leader = role, term, r.node.Leader()
		for _, message := range ready.Messages {
			wire.send(message)
		}
		for _, entry := range ready.Applied {
			value := store.apply(entry.Command)
			status.Applied = entry.Index
			payload, _ := json.Marshal(entry.Entry) // Entry has only JSON scalar fields.
			log.Printf("applied peer=%d index=%d term=%d digest=%x", r.id, entry.Index, entry.Term, sha256.Sum256(payload))
			if p, exists := pending[entry.Index]; exists && p.term == entry.Term {
				p.reply <- outcome{result: value, code: 200}
				delete(pending, entry.Index)
			}
		}
		for index, p := range pending {
			switch {
			case p.ctx.Err() != nil:
				delete(pending, index)
			case role != raft.Leader || p.term != term:
				p.reply <- outcome{code: 409, leader: status.Leader}
				delete(pending, index)
			}
		}
	}
}
~~~

</details>

### Step 4. Expose HTTP on a local socket

Use `POST /raft` for enqueueing a peer message and `POST /command` for proposing. Limit body lengths and reject unknown fields. Wire the executable to a Unix socket and its own log path.

<details>
<summary>Hint 1</summary>

A 204 from the HTTP peer handler says the inbox took the message.

</details>

<details>
<summary>Hint 2</summary>

The actual Raft reply is a separate message after the save. Keep `/status` for observing the lab.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/metad/http.go -->
~~~go
package metad

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"time"

	"switchyard/metad/internal/raft"
)

func (r *Runtime) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /raft", r.receive)
	mux.HandleFunc("POST /command", r.command)
	mux.HandleFunc("GET /status", r.getStatus)
	return mux
}

func decode(w http.ResponseWriter, req *http.Request, limit int64, target any) bool {
	d := json.NewDecoder(http.MaxBytesReader(w, req.Body, limit))
	d.DisallowUnknownFields()
	return d.Decode(target) == nil && d.Decode(&struct{}{}) == io.EOF
}

func reply(w http.ResponseWriter, code int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(value)
}

func (r *Runtime) receive(w http.ResponseWriter, req *http.Request) {
	var message raft.Message
	if !decode(w, req, 256<<10, &message) || message.To != r.id ||
		message.From < 1 || message.From > r.members || message.From == r.id ||
		message.Term == 0 || len(message.Entries) > 16 {
		http.Error(w, "invalid peer message", http.StatusBadRequest)
		return
	}
	switch message.Kind {
	case raft.RequestVote, raft.VoteReply, raft.Append, raft.AppendReply:
	default:
		http.Error(w, "unknown message", http.StatusBadRequest)
		return
	}
	select {
	case r.messages <- message:
		w.WriteHeader(http.StatusNoContent)
	default:
		w.WriteHeader(http.StatusServiceUnavailable)
	}
}

func (r *Runtime) command(w http.ResponseWriter, req *http.Request) {
	var command raft.Command
	if !decode(w, req, 8<<10, &command) || len(command.Key) == 0 || len(command.Key) > 128 ||
		len(command.Value) > 512 || (command.Op != "get" && command.Op != "put") {
		http.Error(w, "invalid command", http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(req.Context(), 900*time.Millisecond)
	defer cancel()
	p := proposal{ctx: ctx, command: command, reply: make(chan outcome, 1)}
	select {
	case r.propose <- p:
	case <-ctx.Done():
		w.WriteHeader(http.StatusGatewayTimeout)
		return
	}
	select {
	case result := <-p.reply:
		if result.code == http.StatusOK {
			reply(w, result.code, result.result)
		} else {
			reply(w, result.code, map[string]int{"leader": result.leader})
		}
	case <-ctx.Done():
		w.WriteHeader(http.StatusGatewayTimeout)
	}
}

func (r *Runtime) getStatus(w http.ResponseWriter, req *http.Request) {
	ctx, cancel := context.WithTimeout(req.Context(), 250*time.Millisecond)
	defer cancel()
	answer := make(chan Status, 1)
	select {
	case r.status <- answer:
	case <-ctx.Done():
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	select {
	case status := <-answer:
		reply(w, http.StatusOK, status)
	case <-ctx.Done():
		w.WriteHeader(http.StatusServiceUnavailable)
	}
}
~~~

<!-- file: cmd/metad/main.go -->
~~~go
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"slices"
	"strings"
	"syscall"
	"time"

	"switchyard/metad/internal/metad"
	"switchyard/metad/internal/wal"
)

func run() error {
	id := flag.Int("id", 0, "peer ID from 1 to 3")
	listen := flag.String("listen", "", "local Unix socket path")
	routes := flag.String("peers", "", "comma-separated Unix socket paths in ID order")
	path := flag.String("wal", "", "path to this peer's klog")
	writer := flag.String("writer", "", "path to the metad-wal executable")
	flag.Parse()

	peers := strings.Split(*routes, ",")
	if len(peers) != 3 || slices.Contains(peers, "") || *id < 1 || *id > len(peers) ||
		*listen == "" || *path == "" || *writer == "" {
		return errors.New("supply -id, -listen, -peers (three paths), -wal, and -writer")
	}
	if peers[0] == peers[1] || peers[0] == peers[2] || peers[1] == peers[2] {
		return errors.New("peer routes must be distinct")
	}
	disk, stable, recovered, err := wal.Open(*writer, *path, len(peers))
	if err != nil {
		return err
	}
	defer disk.Close()
	log.Printf("recovered peer=%d bytes=%d", *id, recovered)
	listener, err := net.Listen("unix", *listen)
	if err != nil {
		return err
	}
	defer listener.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	node := metad.New(*id, len(peers), time.Now().UnixNano(), stable, disk)
	server := &http.Server{
		Handler: node.Handler(), ReadTimeout: time.Second, WriteTimeout: 2 * time.Second,
		IdleTimeout: 3 * time.Second,
	}
	defer server.Close()
	serve := make(chan error, 1)
	go func() {
		serve <- server.Serve(listener)
		stop()
	}()
	log.Printf("listening peer=%d", *id)
	if err := node.Run(ctx, peers); err != nil {
		return err
	}
	select {
	case err := <-serve:
		if !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("serve: %w", err)
		}
	default:
	}
	return nil
}

func main() {
	log.SetFlags(0)
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
~~~

</details>

### Step 5. Kill the leader after a completed write

Run the smoke check. It sends a baseline write, waits for application, sends SIGKILL, reads through the successor, and restarts the killed peer.

<details>
<summary>Hint 1</summary>

All peers use separate log files and share the same fixed list of routes.

</details>

<details>
<summary>Hint 2</summary>

A fresh peer process uses the previous file path. It should catch up to the quorum-confirmed prefix.

</details>

## Check it

~~~bash
test -z "$(gofmt -l .)" && go vet ./... && METAD_WAL_WRITER="$PWD/klog/target/debug/metad-wal" go test -race -count=1 -v ./... && bash "$blueprint/2-core/07-distributed-systems-fundamentals/gate/run.sh" "$PWD" smoke
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && METAD_WAL_WRITER="$PWD/klog/target/debug/metad-wal" go test -race -count=1 -v ./... && bash "$BLUEPRINT_ROOT/2-core/07-distributed-systems-fundamentals/gate/run.sh" "$PWD" smoke -->

~~~text
three Unix-socket peers applied the write
SIGKILL stopped the leader; a higher-term leader read the value
the restarted peer caught up
~~~

The smoke check uses three real Go peers plus their Rust writers. The client gets the committed value from a higher-term leader.

Full captures are in [07-smoke.txt](../evidence/lessons/07-smoke.txt).

## If it goes wrong

| Symptom | What to inspect |
|---|---|
| A peer cannot listen | Check Unix-socket bind permissions and path length. Use three distinct paths. |
| The isolated old leader reaches the request deadline | Check whether any peer can receive and durably acknowledge the Append. |

## Explain it

1. What is the difference between HTTP admission and a Raft acknowledgment?
2. Why do reads enter the replicated log?
