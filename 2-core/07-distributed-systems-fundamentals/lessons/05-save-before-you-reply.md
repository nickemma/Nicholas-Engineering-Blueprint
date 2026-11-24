# 05 Save before you reply

> Core 07 · About 7 hours · Builds on the preceding lesson

## The problem

A peer grants a vote, then reboots. If it forgot the vote, it can give another candidate the decisive vote in the same term. Forgetting an acknowledged entry can similarly invalidate a majority that a leader relied on.

## The mental model

~~~text
Tick or Step
      |
     Take
      |
 save term, vote and log changes together
      |
 send replies and requests
      |
 apply committed entries to the local state machine
~~~

Each input produces one set of effects. The driver calls `Take` after that input. It stores the batch before releasing any message. If the save fails, it drops the effects and stops the peer. A crash before a save can still be safe if nothing else learned of the change. A crash after a save can cause a retry, which the peer handles using its persisted state.

## The pattern

Persist the term, the vote in that term, and changes to the log. A replacement carries a 1-based starting index and the whole new suffix from there. Validate the entire update before mutating the recovered state. A restarted peer begins as a follower with new timers. Replay into a fresh state machine as the peer learns the commit boundary again.

## Build it

### Step 1. Record hard state

Collect term and vote changes in one batch. Fill in `ready.Save.Hard = /* TODO */` and decide which state the receiver needs after restart.

<details>
<summary>Hint 1</summary>

The newer term can clear an old vote. The subsequent grant can be in the same input event.

</details>

<details>
<summary>Hint 2</summary>

Replace the pending hard state with the final term and vote of the event.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- edit: internal/raft/node.go -->
~~~go
}

type Ready struct {
	Messages []Message
	Applied  []Applied
}
~~~

~~~go
}

type Ready struct {
	Save     Batch
	Messages []Message
	Applied  []Applied
}
~~~

<!-- edit: internal/raft/node.go -->
~~~go
}

func (n *Node) campaign() {
	n.term++
	n.role, n.vote, n.leader = Candidate, n.id, 0
	n.votes = map[int]bool{n.id: true}
	n.resetTimer()
	if n.win() {
~~~

~~~go
}

func (n *Node) campaign() {
	n.role, n.leader = Candidate, 0
	n.setHard(n.term+1, n.id)
	n.votes = map[int]bool{n.id: true}
	n.resetTimer()
	if n.win() {
~~~

<!-- edit: internal/raft/node.go -->
~~~go
		return
	}
	if m.Term > n.term {
		n.term, n.vote, n.role, n.leader = m.Term, 0, Follower, 0
	}
	if m.Term < n.term {
		switch m.Kind {
~~~

~~~go
		return
	}
	if m.Term > n.term {
		n.role, n.leader = Follower, 0
		n.setHard(m.Term, 0)
	}
	if m.Term < n.term {
		switch m.Kind {
~~~

<!-- edit: internal/raft/node.go -->
~~~go
	case RequestVote:
		grant := (n.vote == 0 || n.vote == m.From) && n.upToDate(m)
		if grant {
			n.vote = m.From
			n.resetTimer()
		}
		n.send(m.From, Message{Kind: VoteReply, OK: grant})
~~~

~~~go
	case RequestVote:
		grant := (n.vote == 0 || n.vote == m.From) && n.upToDate(m)
		if grant {
			n.setHard(n.term, m.From)
			n.resetTimer()
		}
		n.send(m.From, Message{Kind: VoteReply, OK: grant})
~~~

</details>

### Step 2. Record log replacements

Report appends and conflict replacements through the same method. Decide which offset your batch stores when the first real entry changes.

<details>
<summary>Hint 1</summary>

The core has a sentinel. Stable.Entries begins with the real entry at index 1.

</details>

<details>
<summary>Hint 2</summary>

Use an index of 1 in the batch. Convert it to offset 0 when replaying.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- edit: internal/raft/replication.go -->
~~~go
	for i, entry := range m.Entries {
		index := m.Prev + 1 + i
		if index >= len(n.log) || n.log[index].Term != entry.Term {
			n.log = append(n.log[:index], m.Entries[i:]...)
			break
		}
	}
~~~

~~~go
	for i, entry := range m.Entries {
		index := m.Prev + 1 + i
		if index >= len(n.log) || n.log[index].Term != entry.Term {
			n.replaceSuffix(index, m.Entries[i:])
			break
		}
	}
~~~

<!-- edit: internal/raft/commit.go -->
~~~go
}

func (n *Node) appendLocal(command Command) {
	n.log = append(n.log, Entry{Term: n.term, Command: command})
}

// tryCommit runs only on the leader. The median-like order statistic
~~~

~~~go
}

func (n *Node) appendLocal(command Command) {
	n.replaceSuffix(len(n.log), []Entry{{Term: n.term, Command: command}})
}

// tryCommit runs only on the leader. The median-like order statistic
~~~

</details>

### Step 3. Restore from a validated batch

Write the validation before updating the prefix. Reject a term that moves backward, a changed vote in the same term, and a suffix that starts past the end. Keep the in-memory Raft log independent of the stored slice.

<details>
<summary>Hint 1</summary>

Check the new suffix's term sequence before applying it.

</details>

<details>
<summary>Hint 2</summary>

Validate with local variables, then update the saved prefix and term together. Copy the recovered suffix into the core.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/raft/stable.go -->
~~~go
package raft

import (
	"fmt"
	"slices"
)

type HardState struct {
	Term uint64
	Vote int
}

// Batch is one atomic change. From is the 1-based start of a new suffix,
// or zero for a change that leaves the log alone.
type Batch struct {
	Hard    *HardState `json:",omitempty"`
	From    int        `json:",omitempty"`
	Entries []Entry    `json:",omitempty"`
}

func (b Batch) Empty() bool { return b.Hard == nil && b.From == 0 && len(b.Entries) == 0 }

type Stable struct {
	Hard    HardState
	Entries []Entry // Index 1 is stored at offset 0.
}

func (s *Stable) Apply(batch Batch, members int) error {
	hard := s.Hard
	if batch.Hard != nil {
		hard = *batch.Hard
		if hard.Term == 0 || hard.Term < s.Hard.Term || hard.Vote < 0 || hard.Vote > members ||
			(hard.Term == s.Hard.Term && s.Hard.Vote != 0 && hard.Vote != s.Hard.Vote) {
			return fmt.Errorf("invalid persisted term or vote: %+v", hard)
		}
	}
	if (batch.From == 0) != (len(batch.Entries) == 0) || batch.From < 0 || batch.From-1 > len(s.Entries) {
		return fmt.Errorf("invalid persisted suffix at index %d", batch.From)
	}
	if batch.From != 0 {
		var previous uint64
		if batch.From > 1 {
			previous = s.Entries[batch.From-2].Term
		}
		for _, entry := range batch.Entries {
			if entry.Term == 0 || entry.Term < previous || entry.Term > hard.Term {
				return fmt.Errorf("invalid persisted entry term %d", entry.Term)
			}
			previous = entry.Term
		}
		s.Entries = append(s.Entries[:batch.From-1], batch.Entries...)
	}
	s.Hard = hard
	return nil
}

func Restore(id, members int, seed int64, stable Stable) *Node {
	n := New(id, members, seed)
	n.term, n.vote = stable.Hard.Term, stable.Hard.Vote
	n.log = append(n.log, stable.Entries...)
	return n
}

func (n *Node) setHard(term uint64, vote int) {
	if n.term == term && n.vote == vote {
		return
	}
	n.term, n.vote = term, vote
	n.ready.Save.Hard = &HardState{Term: term, Vote: vote}
}

func (n *Node) replaceSuffix(index int, entries []Entry) {
	n.log = append(n.log[:index], entries...)
	n.ready.Save.From = index
	n.ready.Save.Entries = slices.Clone(entries)
}
~~~

</details>

### Step 4. Crash on either side of the reply

Stage one vote and decide when to release it. Then use an acknowledged Append to exercise restart before its committed entry is delivered to the application.

<details>
<summary>Hint 1</summary>

At the two crash points the peers may have heard different promises.

</details>

<details>
<summary>Hint 2</summary>

Before sending, an unsaved vote can be discarded. After sending, the vote must already be saved. A later commit message lets the application rebuild.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/raft/stable_test.go -->
~~~go
package raft

import (
	"slices"
	"testing"
)

func TestCrashAroundVote(t *testing.T) {
	run := func(save bool) (afterSave, afterSend bool) {
		vote := func(n *Node, from int) Ready {
			n.Step(Message{Kind: RequestVote, From: from, To: 2, Term: 7})
			return n.Take()
		}
		var disk Stable
		first := vote(Restore(2, 3, 1, disk), 1)
		if len(first.Messages) != 1 || !first.Messages[0].OK {
			t.Fatal("first vote was refused")
		}
		// A crash before save is safe only while the reply stays private.
		beforeSave := vote(Restore(2, 3, 2, disk), 3)
		if !beforeSave.Messages[0].OK {
			t.Fatal("an unsaved vote survived")
		}
		if save {
			if err := disk.Apply(first.Save, 3); err != nil {
				t.Fatal(err)
			}
		}
		afterSave = vote(Restore(2, 3, 2, disk), 3).Messages[0].OK
		// With the same disk, sending the first reply changes outsiders'
		// knowledge. It leaves the restarted voter's answer unchanged.
		afterSend = vote(Restore(2, 3, 3, disk), 3).Messages[0].OK
		return
	}
	a, b := run(true)
	if a || b {
		t.Fatal("double vote after a durable save")
	}
	_, second := run(false)
	if !second {
		t.Fatal("negative control should vote twice in term 7")
	}
	t.Log("save before send: restarted voter refuses the second candidate")
	t.Log("send without save: both candidates can count peer 2 in term 7")
}

func TestStableReplacementIsAtomic(t *testing.T) {
	var disk Stable
	if err := disk.Apply(Batch{
		Hard: &HardState{Term: 2, Vote: 1}, From: 1,
		Entries: []Entry{{Term: 1}, {Term: 2}},
	}, 3); err != nil {
		t.Fatal(err)
	}
	old := slices.Clone(disk.Entries)
	if err := disk.Apply(Batch{
		Hard: &HardState{Term: 3}, From: 2,
		Entries: []Entry{{Term: 3}, {Term: 4}},
	}, 3); err == nil {
		t.Fatal("accepted entry from a future term")
	}
	if disk.Hard.Term != 2 || !slices.Equal(disk.Entries, old) {
		t.Fatal("invalid batch partially changed stable state")
	}
	if err := disk.Apply(Batch{Hard: &HardState{Term: 3}, From: 2, Entries: []Entry{{Term: 3}}}, 3); err != nil {
		t.Fatal(err)
	}
	if got := Restore(1, 3, 7, disk).Entries(); !slices.Equal(got, []Entry{{Term: 1}, {Term: 3}}) {
		t.Fatal("wrong replay", got)
	}
}

func TestRestartRebuildsApplicationAfterAck(t *testing.T) {
	var disk Stable
	n := Restore(2, 3, 7, disk)
	appendAndCommit := Message{Kind: Append, From: 1, To: 2, Term: 1, Commit: 1,
		Entries: []Entry{{Term: 1, Command: Command{Op: "put", Key: "route", Value: "kept"}}}}
	n.Step(appendAndCommit)
	ready := n.Take()
	if err := disk.Apply(ready.Save, 3); err != nil {
		t.Fatal(err)
	}
	if len(ready.Messages) != 1 || !ready.Messages[0].OK || len(ready.Applied) != 1 {
		t.Fatal("expected a reply and an application after saving", ready)
	}
	// The reply can escape now. Crash before delivering Applied to the store.
	n = Restore(2, 3, 8, disk)
	n.Step(Message{Kind: Append, From: 1, To: 2, Term: 1, Prev: 1, PrevTerm: 1, Commit: 1})
	replayed := n.Take()
	if !replayed.Save.Empty() || !slices.Equal(replayed.Applied, ready.Applied) || !replayed.Messages[0].OK {
		t.Fatal("restart lost a durable command or reapplied without a commit", replayed)
	}
	t.Log("a follower that crashed after acknowledgment rebuilt application from the durable entry")
}
~~~

</details>

### Step 5. Run a restart storm

Give each simulated peer its own saved state. Restart with a fresh core and run the seed loop. Finish on a healthy network and check that all peers apply the same last entry.

<details>
<summary>Hint 1</summary>

Election history and the global comparison of applications survive the simulated crash.

</details>

<details>
<summary>Hint 2</summary>

Replace the core and reset local application progress. Preserve the disk and the test oracle.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- edit: internal/cluster/cluster.go -->
~~~go
	Leaders   map[uint64]int
	Committed map[int]raft.Entry
	Applied   []int
}

func New(count int, seed int64) *Cluster {
~~~

~~~go
	Leaders   map[uint64]int
	Committed map[int]raft.Entry
	Applied   []int
	disks     []raft.Stable
}

func New(count int, seed int64) *Cluster {
~~~

<!-- edit: internal/cluster/cluster.go -->
~~~go
		Leaders:   make(map[uint64]int),
		Committed: make(map[int]raft.Entry),
		Applied:   make([]int, count+1),
	}
	for id := 1; id <= count; id++ {
		c.Nodes[id] = raft.New(id, count, seed*31+int64(id))
~~~

~~~go
		Leaders:   make(map[uint64]int),
		Committed: make(map[int]raft.Entry),
		Applied:   make([]int, count+1),
		disks:     make([]raft.Stable, count+1),
	}
	for id := 1; id <= count; id++ {
		c.Nodes[id] = raft.New(id, count, seed*31+int64(id))
~~~

<!-- edit: internal/cluster/cluster.go -->
~~~go

func (c *Cluster) flush(id int) {
	node := c.Nodes[id]
	if node.Role() == raft.Leader {
		term := node.Term()
		if other := c.Leaders[term]; other != 0 && other != id {
~~~

~~~go

func (c *Cluster) flush(id int) {
	node := c.Nodes[id]
	ready := node.Take()
	if err := c.disks[id].Apply(ready.Save, len(c.Nodes)-1); err != nil {
		panic(err)
	}
	if node.Role() == raft.Leader {
		term := node.Term()
		if other := c.Leaders[term]; other != 0 && other != id {
~~~

<!-- edit: internal/cluster/cluster.go -->
~~~go
		}
		c.Leaders[term] = id
	}
	ready := node.Take()
	for _, applied := range ready.Applied {
		if entry, exists := c.Committed[applied.Index]; exists && entry != applied.Entry {
			panic(fmt.Sprintf("different commands applied at index %d", applied.Index))
		}
		c.Committed[applied.Index] = applied.Entry
		c.Applied[id] = applied.Index
	}
	for _, m := range ready.Messages {
		c.Net.Send(m.From, m.To, m)
	}
}
~~~

~~~go
		}
		c.Leaders[term] = id
	}
	for _, m := range ready.Messages {
		c.Net.Send(m.From, m.To, m)
	}
	for _, applied := range ready.Applied {
		if entry, exists := c.Committed[applied.Index]; exists && entry != applied.Entry {
			panic(fmt.Sprintf("different commands applied at index %d", applied.Index))
		}
		c.Committed[applied.Index] = applied.Entry
		c.Applied[id] = applied.Index
	}
}
~~~

<!-- edit: internal/cluster/cluster.go -->
~~~go
	c.flush(id)
	return accepted
}
~~~

~~~go
	c.flush(id)
	return accepted
}

func (c *Cluster) Crash(id int) {
	c.Nodes[id] = nil
	c.Applied[id] = 0
}

func (c *Cluster) Restart(id int) {
	c.Nodes[id] = raft.Restore(id, len(c.Nodes)-1, int64(c.Net.Now*31+id), c.disks[id])
}
~~~

<!-- file: internal/cluster/restart_test.go -->
~~~go
package cluster

import (
	"fmt"
	"math/rand"
	"testing"

	"switchyard/metad/internal/raft"
)

func TestCrashRecoveryStorm(t *testing.T) {
	for seed := int64(1); seed <= 100; seed++ {
		c := New(3, seed)
		rng := rand.New(rand.NewSource(seed))
		c.Net.Loss, c.Net.Delay = 10, 4
		c.Run(100)
		for event := range 12 {
			id := rng.Intn(3) + 1
			if _, leader := c.LatestLeader(); leader != 0 {
				c.Propose(leader, raft.Command{Op: "put", Key: "route", Value: fmt.Sprint(event)})
			}
			c.Run(rng.Intn(12) + 1)
			c.Crash(id)
			c.Run(rng.Intn(30) + 1)
			c.Restart(id)
			c.Run(40)
		}
		c.Net.Loss, c.Net.Delay = 0, 1
		c.Run(200)
		_, leader := c.LatestLeader()
		if leader == 0 || !c.Propose(leader, raft.Command{Op: "put", Key: "route", Value: "after healing"}) {
			t.Fatalf("seed %d: no leader after healing", seed)
		}
		c.Run(160)
		last := c.Applied[leader]
		if c.Committed[last].Command.Value != "after healing" || c.Applied[1] != last ||
			c.Applied[2] != last || c.Applied[3] != last {
			t.Fatalf("seed %d: applied indexes %v", seed, c.Applied)
		}
	}
	t.Log("100 seeds preserved election and state machine safety across 1,200 peer restarts")
}
~~~

</details>

## Check it

~~~bash
test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 -v ./...
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 -v ./... -->

~~~text
stable_test.go:43: save before send: restarted voter refuses the second candidate
stable_test.go:44: send without save: both candidates can count peer 2 in term 7
stable_test.go:93: a follower that crashed after acknowledgment rebuilt application from the durable entry
restart_test.go:41: 100 seeds preserved election and state machine safety across 1,200 peer restarts
~~~

The directed tests cover the order of the effects. The 100-seed storm exercises multiple interleavings on simulated disks.

Full captures are in [05-restart.txt](../evidence/lessons/05-restart.txt).

## If it goes wrong

| Symptom | What to inspect |
|---|---|
| The restarted peer grants a second candidate | Inspect the saved vote and the point where the reply was released. |
| Application starts with a gap | Run from an empty state machine and apply the committed prefix in order after restore. |

## Explain it

1. What can go wrong if a follower sends a success first and then loses power before saving?
2. Why can the commit index be rebuilt here?
