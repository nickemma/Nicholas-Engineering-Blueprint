# 01 Give clients a replicated key-value store

> Consensus in depth · Week 1 · Builds on lesson 00

## The problem

A worker swaps a job from queued to running, but the reply disappears. The next worker moves it to done. When the first worker retries, it still needs the result of its original swap.

## The mental model

A proposal becomes a committed entry, the state machine applies it, and the runtime replies. Within a key, each client keeps at most one operation awaiting a result. The entry carries that client’s ID, sequence number, and arguments.

## The pattern

Compare-and-swap (CAS) changes an existing value only when it matches the expected value. A retry receipt stores the latest mutation and its result per client and key. Reads continue through the replicated log. The previous anonymous `put` command still works.

## Build it

### Step 1 — Define the command and result

Add fields for the client, sequence, and expected value. Decide how to represent an absent key versus a present empty string.

<details>
<summary>Hint 1</summary>

The JSON API already reports whether a key was found.

</details>

<details>
<summary>Hint 2</summary>

A failed CAS reports the current value and has its own success flag.

</details>

<details>
<summary>Implementation</summary>

Find these blocks in `internal/raft/replication.go` in order.

<!-- edit: internal/raft/replication.go -->
~~~go

type Command struct {
	Op, Key, Value string
	Owner          string `json:",omitempty"`
	At             int64  `json:",omitempty"` // leader's time, in milliseconds
	TTL            int64  `json:",omitempty"`
~~~

Replace it with this version.

~~~go

type Command struct {
	Op, Key, Value string
	Client         string `json:",omitempty"`
	Sequence       uint64 `json:",omitempty"`
	Expect         string `json:",omitempty"`
	Owner          string `json:",omitempty"`
	At             int64  `json:",omitempty"` // leader's time, in milliseconds
	TTL            int64  `json:",omitempty"`
~~~

Find these blocks in `internal/metad/lease.go` in order.

<!-- edit: internal/metad/lease.go -->
~~~go

func validCommand(c raft.Command) bool {
	if c.Key == "" || len(c.Key) > 128 || len(c.Value) > 512 || c.At != 0 {
		return false
	}
	if leaseOperation(c.Op) {
~~~

Replace it with this version.

~~~go

func validCommand(c raft.Command) bool {
	if c.Key == "" || len(c.Key) > 128 || len(c.Value) > 512 || c.At != 0 {
		return false
	}
	if len(c.Client) > 128 || len(c.Expect) > 512 || (c.Client == "") != (c.Sequence == 0) {
		return false
	}
	if c.Op == "cas" {
		return c.Client != "" && c.Owner == "" && c.Token == 0 && c.TTL == 0
	}
	if c.Expect != "" || (c.Client != "" && c.Op != "put") {
		return false
	}
	if leaseOperation(c.Op) {
~~~

Find these blocks in `internal/metad/state.go` in order.

<!-- edit: internal/metad/state.go -->
~~~go
import "switchyard/metad/internal/raft"

type Result struct {
	Found   bool   `json:"found"`
	Value   string `json:"value,omitempty"`
	Granted bool   `json:"granted,omitempty"`
~~~

Replace it with this version.

~~~go
import "switchyard/metad/internal/raft"

type Result struct {
	Swapped bool   `json:"swapped,omitempty"`
	Error   string `json:"error,omitempty"`
	Found   bool   `json:"found"`
	Value   string `json:"value,omitempty"`
	Granted bool   `json:"granted,omitempty"`
~~~

<!-- edit: internal/metad/state.go -->
~~~go
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
~~~

Replace it with this version.

~~~go
}

type state struct {
	values  map[string]string
	retries map[string]map[string]receipt
	leases  map[string]lease
	now     int64
}

func newState() *state {
	return &state{values: make(map[string]string), leases: make(map[string]lease), retries: make(map[string]map[string]receipt)}
}

func (s *state) apply(entry raft.Applied) Result {
	command := entry.Command
	switch command.Op {
	case "put", "cas":
		return s.mutate(command)
	case "get":
		value, found := s.values[command.Key]
		return Result{Found: found, Value: value}
~~~

</details>

### Step 2 — Keep the original result

Write down the outcomes for a first mutation, an identical replay, and a lower or reused sequence. Implement them before modifying the value.

<details>
<summary>Hint 1</summary>

The store needs a receipt for both successful and unsuccessful CAS operations.

</details>

<details>
<summary>Hint 2</summary>

Indexes in the Raft log identify entries. Client sequence numbers identify logical mutations.

</details>

<details>
<summary>Implementation</summary>

Create `internal/metad/kv.go`.

<!-- file: internal/metad/kv.go -->
~~~go
package metad

import "switchyard/metad/internal/raft"

type receipt struct {
	Command raft.Command
	Result  Result
}

func (s *state) mutate(command raft.Command) Result {
	clients := s.retries[command.Key]
	if previous, exists := clients[command.Client]; exists {
		switch {
		case command == previous.Command:
			return previous.Result
		case command.Sequence <= previous.Command.Sequence:
			return Result{Error: "sequence already used"}
		}
	}

	old, found := s.values[command.Key]
	result := Result{Found: found, Value: old}
	if command.Op == "put" || (found && old == command.Expect) {
		s.values[command.Key] = command.Value
		result = Result{Found: true, Value: command.Value, Swapped: command.Op == "cas"}
	}

	if command.Client != "" {
		if clients == nil {
			clients = make(map[string]receipt)
			s.retries[command.Key] = clients
		}
		clients[command.Client] = receipt{Command: command, Result: result}
	}
	return result
}
~~~

</details>

### Step 3 — Drop a reply in the fixture

Apply the swap, advance the state with a second write, and submit the original command again.

<details>
<summary>Hint 1</summary>

Compare the entire result with the result from the first attempt.

</details>

<details>
<summary>Hint 2</summary>

Also check that the retry leaves the later value in place.

</details>

<details>
<summary>Implementation</summary>

Create `internal/metad/kv_test.go`.

<!-- file: internal/metad/kv_test.go -->
~~~go
package metad

import (
	"testing"

	"switchyard/metad/internal/raft"
)

func TestRetryAfterLostReply(t *testing.T) {
	s := newState()
	s.mutate(raft.Command{Op: "put", Key: "job", Value: "queued"})
	swap := raft.Command{Op: "cas", Key: "job", Expect: "queued", Value: "running", Client: "worker", Sequence: 1}
	original := s.mutate(swap)
	if !original.Swapped {
		t.Fatalf("first compare-and-swap: %+v", original)
	}
	s.mutate(raft.Command{Op: "put", Key: "job", Value: "done"})
	if retry := s.mutate(swap); retry != original || s.values["job"] != "done" {
		t.Fatalf("retry %+v changed the result or state", retry)
	}
	swap.Value = "different"
	if result := s.mutate(swap); result.Error == "" {
		t.Fatal("reused sequence with different input was accepted")
	}
	t.Log("lost-reply retry returned running; stored state stayed done")
}
~~~

</details>

## Check it

~~~bash
go test -race -count=1 -v ./internal/metad -run TestRetryAfterLostReply
~~~

<!-- run: go test -race -count=1 -v ./internal/metad -run TestRetryAfterLostReply -->

The reference reports `lost-reply retry returned running; stored state stayed done`. The fixture exercises command application directly. The live partition and restart arrive in lesson 05.

## If it goes wrong

If the retry returns the current value, check whether the receipt lookup happens before evaluating the CAS. If a different command gets the old result, compare the full request as well as its sequence.
