# 09 Fence a worker that outlives its lease

> Core 07 · About 7 hours · Builds on the preceding lesson

## The problem

A worker acquires a lease and pauses. The lease expires and a new worker begins. When the old worker resumes, it tries to publish a result it computed under its old lease.

## The mental model

~~~text
grant A at log index 2 → A pauses
grant B at log index 4 → B writes token 4
A resumes → resource sees token 2 < 4 → refuses the write
~~~

A lease grants one owner time-limited access. When control moves to a new owner, issue a larger **fencing token**. The resource keeps its highest accepted token per key. Compare the token and update the resource under the same lock or transaction. The old token can still be accepted until a higher token reaches the resource.

## The pattern

The leader supplies one time value per proposed lease command. Replicas apply that same value. Clamp the state machine's observed time to its previous value when a later leader's clock runs behind. A clock jump can still affect when the cluster grants a new lease. The fencing comparison protects the resource once it has seen the newer grant, even if a worker pauses for an arbitrary duration.

A renewal extends the deadline and preserves the token. A grant uses the index of its committed entry, so replay and failover preserve the ordering of issued tokens. A durable external resource must save its highest token with the protected value. The lab's resource demonstrates the atomic check in memory.

## Build it

### Step 1. Extend the command and validate input

Add time, TTL, owner, and token fields. Complete `leader time = /* TODO */` in the driver. Reject attempts to supply that time from the HTTP API.

<details>
<summary>Hint 1</summary>

A timestamp read independently on each replica can change the result.

</details>

<details>
<summary>Hint 2</summary>

Stamp at proposal time. Raft carries the resulting command to every replica.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/raft/replication.go -->
~~~go
package raft

import "slices"

type Command struct {
	Op, Key, Value string
	Owner          string `json:",omitempty"`
	At             int64  `json:",omitempty"` // leader's time, in milliseconds
	TTL            int64  `json:",omitempty"`
	Token          int    `json:",omitempty"`
}

type Entry struct {
	Term    uint64
	Command Command
}

type progress struct {
	next, match int
}

func (n *Node) Entries() []Entry { return slices.Clone(n.log[1:]) }

func (n *Node) upToDate(m Message) bool {
	last := len(n.log) - 1
	term := n.log[last].Term
	return m.PrevTerm > term || (m.PrevTerm == term && m.Prev >= last)
}

func (n *Node) startReplication() {
	n.progress = make([]progress, n.members+1)
	for peer := 1; peer <= n.members; peer++ {
		n.progress[peer].next = len(n.log)
	}
}

func (n *Node) Propose(command Command) (index int, term uint64, ok bool) {
	if n.role != Leader {
		return 0, 0, false
	}
	n.appendLocal(command)
	n.tryCommit()
	n.broadcast()
	return len(n.log) - 1, n.term, true
}

func (n *Node) broadcast() {
	for peer := 1; peer <= n.members; peer++ {
		if peer != n.id {
			n.replicate(peer)
		}
	}
}

func (n *Node) replicate(peer int) {
	next := n.progress[peer].next
	end := min(next+16, len(n.log))
	n.send(peer, Message{
		Kind: Append, Prev: next - 1, PrevTerm: n.log[next-1].Term,
		Entries: slices.Clone(n.log[next:end]), Commit: n.commit,
	})
}

func (n *Node) acceptAppend(m Message) {
	if m.Prev < 0 || m.Prev >= len(n.log) || n.log[m.Prev].Term != m.PrevTerm {
		n.rejectAppend(m)
		return
	}
	for i, entry := range m.Entries {
		index := m.Prev + 1 + i
		if index >= len(n.log) || n.log[index].Term != entry.Term {
			n.replaceSuffix(index, m.Entries[i:])
			break
		}
	}
	last := m.Prev + len(m.Entries)
	n.commitThrough(min(m.Commit, last))
	n.send(m.From, Message{Kind: AppendReply, OK: true, Prev: m.Prev, Match: last})
}

func (n *Node) rejectAppend(m Message) {
	n.send(m.From, Message{Kind: AppendReply, Prev: m.Prev})
}

func (n *Node) appendReply(m Message) {
	p := &n.progress[m.From]
	if !m.OK {
		// Ignore a rejection for a probe that has already been superseded.
		if m.Prev == p.next-1 && p.next > p.match+1 {
			p.next--
			n.replicate(m.From)
		}
		return
	}
	if m.Match <= p.match || m.Match >= len(n.log) {
		return
	}
	p.match, p.next = m.Match, m.Match+1
	if n.tryCommit() {
		n.broadcast()
		return
	}
	if p.next < len(n.log) {
		n.replicate(m.From)
	}
}
~~~

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
				if leaseOperation(p.command.Op) {
					p.command.At = time.Now().UnixMilli()
				}
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
			value := store.apply(entry)
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
	if !decode(w, req, 8<<10, &command) || !validCommand(command) {
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

</details>

### Step 2. Grant or renew in the state machine

Store a lease per key. Decide which index to use for a grant, and what to do when the holder presents a token at the exact expiry.

<details>
<summary>Hint 1</summary>

The previous grant has expired at equality.

</details>

<details>
<summary>Hint 2</summary>

Use the index of the new committed grant. Reject a renewal at expiry.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/metad/state.go -->
~~~go
package metad

import "switchyard/metad/internal/raft"

type Result struct {
	Found   bool   `json:"found"`
	Value   string `json:"value,omitempty"`
	Granted bool   `json:"granted,omitempty"`
	Token   int    `json:"token,omitempty"`
	Expires int64  `json:"expires,omitempty"`
}

type state struct {
	values map[string]string
	leases map[string]lease
	now    int64
}

func newState() *state {
	return &state{values: make(map[string]string), leases: make(map[string]lease)}
}

func (s *state) apply(entry raft.Applied) Result {
	command := entry.Command
	switch command.Op {
	case "put":
		s.values[command.Key] = command.Value
		return Result{Found: true, Value: command.Value}
	case "get":
		value, found := s.values[command.Key]
		return Result{Found: found, Value: value}
	case "acquire", "renew":
		return s.applyLease(entry)
	default:
		return Result{} // The election no-op changes no metadata.
	}
}
~~~

<!-- file: internal/metad/lease.go -->
~~~go
package metad

import (
	"math"
	"sync"

	"switchyard/metad/internal/raft"
)

type lease struct {
	owner   string
	token   int
	expires int64
}

const maxTTL = 60_000

func leaseOperation(op string) bool { return op == "acquire" || op == "renew" }

func validCommand(c raft.Command) bool {
	if c.Key == "" || len(c.Key) > 128 || len(c.Value) > 512 || c.At != 0 {
		return false
	}
	if leaseOperation(c.Op) {
		return c.Value == "" && c.Owner != "" && len(c.Owner) <= 128 &&
			c.TTL > 0 && c.TTL <= maxTTL &&
			((c.Op == "acquire" && c.Token == 0) || (c.Op == "renew" && c.Token > 0))
	}
	return (c.Op == "get" || c.Op == "put") && c.Owner == "" && c.Token == 0 && c.TTL == 0
}

func (s *state) applyLease(entry raft.Applied) Result {
	c := entry.Command
	s.now = max(s.now, c.At) // A later leader's clock can be behind.
	old := s.leases[c.Key]
	active := old.token != 0 && s.now < old.expires
	if c.TTL <= 0 || c.TTL > maxTTL || s.now > math.MaxInt64-c.TTL {
		return Result{}
	}
	if c.Op == "renew" {
		if !active || c.Owner != old.owner || c.Token != old.token {
			return Result{}
		}
	} else {
		if active {
			return Result{}
		}
		old = lease{owner: c.Owner, token: entry.Index}
	}
	expires := s.now + c.TTL
	old.expires = max(old.expires, expires)
	s.leases[c.Key] = old
	return Result{Granted: true, Token: old.token, Expires: old.expires}
}

// Resource demonstrates the check and effect under one lock. An external
// durable resource would store the highest token alongside the value.
type Resource struct {
	mu    sync.Mutex
	items map[string]fencedValue
}

type fencedValue struct {
	token int
	value string
}

func NewResource() *Resource { return &Resource{items: make(map[string]fencedValue)} }

func (r *Resource) Write(key string, token int, value string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if token <= 0 || token < r.items[key].token {
		return false
	}
	r.items[key] = fencedValue{token: token, value: value}
	return true
}

func (r *Resource) Value(key string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.items[key].value
}
~~~

</details>

### Step 3. Pause the old worker

Use a channel to keep an old worker waiting while B writes. Make the resource enforce `token < /* TODO */` in the same critical section as the value update.

<details>
<summary>Hint 1</summary>

An earlier call to the lease service leaves a gap before the write.

</details>

<details>
<summary>Hint 2</summary>

Compare with the highest token the resource has accepted for that key.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/metad/lease_test.go -->
~~~go
package metad

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"switchyard/metad/internal/raft"
)

func leaseEntry(index int, op, owner string, at, ttl int64, token int) raft.Applied {
	return raft.Applied{Index: index, Entry: raft.Entry{Command: raft.Command{
		Op: op, Key: "job", Owner: owner, At: at, TTL: ttl, Token: token,
	}}}
}

func TestPausedWorkerIsFenced(t *testing.T) {
	entries := []raft.Applied{
		leaseEntry(2, "acquire", "worker A", 100, 20, 0),
		leaseEntry(4, "acquire", "worker B", 120, 20, 0),
	}
	state := newState()
	resource := NewResource()
	a := state.apply(entries[0])
	if !a.Granted || !resource.Write("job", a.Token, "A started") {
		t.Fatal("worker A could not start")
	}
	resume := make(chan struct{})
	done := make(chan bool, 1)
	go func() {
		<-resume
		done <- resource.Write("job", a.Token, "late A")
	}()

	b := state.apply(entries[1])
	bAccepted := resource.Write("job", b.Token, "B finished")
	close(resume)
	aAccepted := <-done
	if !b.Granted || b.Token <= a.Token || !bAccepted || aAccepted || resource.Value("job") != "B finished" {
		t.Fatalf("A=%+v B=%+v A-late=%t B-accepted=%t", a, b, aAccepted, bAccepted)
	}
	restarted := newState()
	for _, entry := range entries {
		restarted.apply(entry)
	}
	c := restarted.apply(leaseEntry(6, "acquire", "worker C", 140, 20, 0))
	if !c.Granted || c.Token <= b.Token {
		t.Fatal("replay allowed a token to go backward", c)
	}
	t.Logf("grants %d, %d, %d; resource refused resumed worker A after B wrote", a.Token, b.Token, c.Token)
}

func TestRenewAndClockSkew(t *testing.T) {
	state := newState()
	a := state.apply(leaseEntry(2, "acquire", "A", 100, 20, 0))
	renew := state.apply(leaseEntry(3, "renew", "A", 110, 20, a.Token))
	if !renew.Granted || renew.Token != a.Token || renew.Expires != 130 {
		t.Fatal("wrong renewal", renew)
	}
	backward := state.apply(leaseEntry(4, "renew", "A", 20, 30, a.Token))
	if backward.Expires != 140 {
		t.Fatal("backward clock moved the replicated time", backward)
	}
	wrong := state.apply(leaseEntry(5, "renew", "B", 130, 20, a.Token))
	late := state.apply(leaseEntry(6, "renew", "A", 140, 20, a.Token))
	if wrong.Granted || late.Granted {
		t.Fatal("accepted an invalid renewal")
	}
	t.Log("renewal kept the same token; wrong owner and deadline-equal renewal were refused")
}

func TestClientCannotSupplyLeaseTime(t *testing.T) {
	r := New(1, 3, 7, raft.Stable{}, nil)
	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/command", strings.NewReader(
		`{"Op":"acquire","Key":"job","Owner":"A","TTL":10,"At":123}`,
	))
	r.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("client could set the leader's clock: %d", w.Code)
	}
}
~~~

</details>

### Step 4. Check the client contract

Use the lease-mode harness. It submits an acquire, waits for a later acquire to grant a higher index, and tries a renewal from the old owner. Keep expiry and fencing as separate checks.

<details>
<summary>Hint 1</summary>

HTTP 200 means the acquire command was applied. Look at the granted field for the decision.

</details>

<details>
<summary>Hint 2</summary>

A renewal from the old owner is applied with granted absent or false.

</details>

## Check it

~~~bash
test -z "$(gofmt -l .)" && go vet ./... && METAD_WAL_WRITER="$PWD/klog/target/debug/metad-wal" go test -race -count=1 -v ./... && bash "$blueprint/2-core/07-distributed-systems-fundamentals/gate/run.sh" "$PWD" leases
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && METAD_WAL_WRITER="$PWD/klog/target/debug/metad-wal" go test -race -count=1 -v ./... && bash "$BLUEPRINT_ROOT/2-core/07-distributed-systems-fundamentals/gate/run.sh" "$PWD" leases -->

~~~text
lease_test.go:51: grants 2, 4, 6; resource refused resumed worker A after B wrote
lease_test.go:70: renewal kept the same token; wrong owner and deadline-equal renewal were refused
client API: expiry allowed a higher grant; the old owner could not renew
~~~

The pause and backward-clock tests use synthetic time. The API check goes through a live Raft quorum.

Full captures are in [09-lease.txt](../evidence/lessons/09-lease.txt), [09-lease-api.txt](../evidence/lessons/09-lease-api.txt).

## If it goes wrong

| Symptom | What to inspect |
|---|---|
| A late worker overwrites the result | Move the token check to the same operation that updates the protected value. |
| Two replicas report different grants | Look for clock reads inside the state machine. Apply the recorded command time on every peer. |

## Explain it

1. When does a higher token start to protect the resource?
2. What has to survive the resource's own restart?
