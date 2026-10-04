# Phase 4: Replicate approved state through failure

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: a type-along guide with the code inline, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This self-study lesson builds and tests the Raft core for a three-node key/value state-machine workload. It first lets you inspect a maintained Raft library, then guides you through the protocol implementation in the supplied Go lab and uses its simulator to test elections, replication, persistence, and snapshots. The stored values are synthetic metadata, never source health records.

## The goal

You will distinguish safety (“nothing incorrect is committed”) from liveness (“the system eventually makes progress”), reproduce leader change and network partition behavior, check client histories for linearizability, and model one safety invariant. You will be able to explain the evidence behind the guarantee instead of saying “Raft makes it consistent.”

## Before you start

Finish Phases 0–3 and the Rust Bridge. Bring a tested API, a process/network failure vocabulary, a durable local-store experiment, Go tests, and the record that says exactly what Phase 3 can recover. Read the MIT 6.5840 lab instructions and download their provided starter material before implementing the lab. The lab API and handout can change between course years; record which release you used.

Make a separate practice area for the MIT lab. Its starter repository is a complete Go module with its own tests, so do not run `go mod init` inside it:

~~~bash
cd lessons/04-replicated-state
mkdir -p practice
cd practice
git clone git://g.csail.mit.edu/6.5840-golabs-2026 6.5840
cd 6.5840/src
make raft1
cd raft1
go test -v -race
~~~

The first test run should fail because the supplied Raft implementation is a skeleton. Keep this course checkout separate from your Kestrel code. The course tests drive the protocol implementation; the small project-specific experiments below explain why those behaviors matter.

## 1. Write the failure model first

For this lesson, a crash fault means a node stops or restarts and does not invent arbitrary protocol messages. A Byzantine fault means a participant may lie or behave arbitrarily; Raft in this lesson does not tolerate it. A network partition means two groups of nodes cannot exchange messages. A timeout is evidence that a response was late; it is not proof that a node died.

State these assumptions in a file named failure-model.md:

- There are three named nodes with stable identities.
- Processes may stop and restart.
- Messages may be delayed, lost, duplicated, or arrive after a timeout.
- Nodes may not behave maliciously.
- A majority is two of three.
- Committed metadata must not disappear after a leader change.

Define one example value, such as query-policy-version=7. Do not put personal, medical, or source records in the replicated store. The project tests protocol behavior, not record sharing.

## 2. Trace a maintained Raft implementation

Before writing a protocol, inspect HashiCorp's maintained [Raft library](https://github.com/hashicorp/raft) and its [API documentation](https://pkg.go.dev/github.com/hashicorp/raft). Read the descriptions of `Raft.Apply`, `FSM`, `LogStore`, `StableStore`, `SnapshotStore`, and `Transport`. Trace this path in your notebook: client command → `Apply` → replicated log/quorum → `FSM.Apply` → state machine response. Record which interfaces separate the consensus algorithm from storage, transport, snapshots, and application state.

This is a source/API walkthrough, not a second implementation project. The supplied MIT lab below is the hands-on Raft implementation with tests and an exact interface. The distinction saves you from writing a cluster bootstrap and storage layer before you have learned the protocol invariants.

## 3. Learn the state machine by adding one guarantee at a time

Raft nodes use three roles: follower, candidate, and leader. A term is a logical election epoch. A quorum is a majority that can agree on an action. Each node stores a log of commands, a current term, and the candidate it voted for in that term.

Implement the protocol in stages by following the supplied MIT Lab 3 handout and skeleton at [Lab 3: Raft](https://pdos.csail.mit.edu/6.824/labs/lab-raft1.html). The code belongs in `src/raft1/raft.go`; the tests are in `src/raft1/raft_test.go`. Run the named test group after each stage, using `go test -v -race -run 3A`, then `3B`, `3C`, and `3D` from `src/raft1`. These groups test election, replication, persistence/safety, and snapshots. Keep the supplied interfaces: later tests depend on them. The stages mean:

1. **Election only.** Add randomized election timeouts, RequestVote messages, in-memory term/vote state, and heartbeat messages. Test that one leader is elected after startup and eventually another leader appears after the first is stopped. Persistence comes in 3C.
2. **Replicate one command.** Add AppendEntries and a log index. Followers accept a matching prefix and reject conflicting entries. Test that the same committed command appears in log order.
3. **Commit through quorum.** Advance the commit index only when the leader has replicated an entry to a majority and meets Raft's term rule. Apply committed entries in order to the state machine.
4. **Persist before responding.** Identify which state survives a restart: term, vote, and log. Write persistent state before sending protocol replies whose correctness depends on it. Reboot one node and confirm it cannot forget a vote and elect a conflicting leader.
5. **Trace the lab's client boundary.** In this lab, `Start(command)` reports the proposed log position, term, and whether this peer is leader; its return does not mean the command is committed. The test service learns about committed commands through the apply channel. Trace both paths and name the point where commitment is known. Stable request IDs and retry behavior belong to a service wrapper and are an optional extension, not a change to the supplied lab API.
6. **Add snapshots only after log recovery works.** A snapshot records current application state and the last included log position. Test that installing a snapshot and replaying the suffix produces the same state as replaying the full log.

At each stage, keep the failing test, repair, and explanation. Do not add later-stage code to hide a failure in an earlier invariant. The handout supplies the exact interface and setup; its tests say what to implement. Use the explanation above to understand the reasoning behind each stage. Run the full suite with `go test -v -race` after 3D passes.

## 4. Test safety and liveness separately

Safety violations include two leaders committing conflicting values in one term or a committed entry being replaced. Liveness failures include no leader being elected even though a majority can communicate. A system may preserve safety by refusing writes while a majority is unavailable; that is not the same as remaining available.

Use a deterministic transport harness to delay, drop, duplicate, and reorder messages. Seed each randomized run and save the seed. Test:

- stop one node: the other two can elect and commit;
- stop two nodes: the remaining node cannot commit a new value;
- partition one node from the other two: only the majority side can commit;
- heal the partition: the minority catches up without replacing committed history;
- restart a node from persisted state: it rejoins without creating a second committed value.

Do not test by blindly running privileged network commands on your everyday host. If you use tc netem, apply it only inside a dedicated disposable network namespace and remove that namespace at the end.

## 5. Check client histories

Linearizability means each successful operation appears to take effect at one point between its invocation and response, in an order consistent with real-time ordering of non-overlapping operations. Record each test request's invocation time, response time, operation, and result.

The supplied MIT lab is a Raft library with a simulator, not a complete key/value HTTP service. Its 3A–3D tests are the required executable history/failure checks. If you later add a key/value adapter, an optional extension is to record each operation's invocation time, response time, input, and output and check that history against a sequential model with [Porcupine](https://github.com/anishathalye/porcupine). Its model must match the adapter's actual API; do not report a checker result from a service you did not build. A counterexample means the implementation or model violates the claimed behavior. A passing finite history is evidence for that test run, not proof for all executions.

## 6. Inspect etcd as a persistent coordination service

Run one local etcd node as a reference for its API and durable metadata. It is a single node, so it is not a quorum or replication exercise; the MIT tests above cover those behaviors. It stores only synthetic keys.

~~~bash
docker volume create kestrel-etcd-data
docker run -d --name kestrel-etcd \
  -p 127.0.0.1:2379:2379 \
  -p 127.0.0.1:2380:2380 \
  --mount type=volume,source=kestrel-etcd-data,destination=/etcd-data \
  gcr.io/etcd-development/etcd:v3.7.2 \
  /usr/local/bin/etcd \
  --name s1 \
  --data-dir /etcd-data \
  --listen-client-urls http://0.0.0.0:2379 \
  --advertise-client-urls http://127.0.0.1:2379 \
  --listen-peer-urls http://0.0.0.0:2380 \
  --initial-advertise-peer-urls http://127.0.0.1:2380 \
  --initial-cluster s1=http://127.0.0.1:2380 \
  --initial-cluster-token kestrel-training \
  --initial-cluster-state new
docker exec kestrel-etcd etcdctl --endpoints=http://127.0.0.1:2379 endpoint health
docker exec kestrel-etcd etcdctl --endpoints=http://127.0.0.1:2379 put query-policy-version 7
docker exec kestrel-etcd etcdctl --endpoints=http://127.0.0.1:2379 get query-policy-version
~~~

Expect `endpoint health` to report a healthy endpoint and `get` to print the key and value. In one terminal, start `docker exec kestrel-etcd etcdctl --endpoints=http://127.0.0.1:2379 watch query-policy-version`. In another, put value `8`; the watch should report the revision change. Compare revisions, leases, watch behavior, and consistency claims with the [etcd API guarantees](https://etcd.io/docs/v3.7/learning/api_guarantees/). etcd is useful for small ordered coordination state; it is not where KESTREL's source records belong.

Remove only this training container and its data after taking notes: `docker rm -f kestrel-etcd` and `docker volume rm kestrel-etcd-data`.

Read the Raft paper after you can trace a replicated write. Then read the ordered list at the end of this guide. For each paper, record one assumption or trade-off that differs from your experiment. CAP does not mean “choose two”; state a partition scenario and the exact consistency/availability behavior.

## 7. Model-check one invariant

Return to the Phase 4 folder and create the TLA+ files in the named practice subfolder:

~~~bash
cd lessons/04-replicated-state
mkdir -p practice/tla
cd practice/tla
~~~

Create `RaftSafety.tla` with this deliberately small abstraction. It models three voters, a single term, and one log position; it is not a full Raft specification.

~~~tla
---- MODULE RaftSafety ----
EXTENDS FiniteSets
CONSTANTS Nodes, ValueOf, Buggy
ASSUME /\ Cardinality(Nodes) = 3
       /\ ValueOf \in [Nodes -> {"A", "B"}]
       /\ Buggy \in BOOLEAN

VARIABLES votes, committed
vars == <<votes, committed>>

Init == /\ votes = {}
        /\ committed = {}

CanVote(n) == Buggy \/ ~\E previous \in Nodes : <<n, previous>> \in votes

Vote(n, candidate) ==
  /\ n \in Nodes
  /\ candidate \in Nodes
  /\ CanVote(n)
  /\ votes' = votes \cup {<<n, candidate>>}
  /\ UNCHANGED committed

Commit(candidate) ==
  /\ candidate \in Nodes
  /\ Cardinality({n \in Nodes : <<n, candidate>> \in votes}) >= 2
  /\ committed' = committed \cup {ValueOf[candidate]}
  /\ UNCHANGED votes

Next ==
  \/ \E n \in Nodes : \E candidate \in Nodes : Vote(n, candidate)
  \/ \E candidate \in Nodes : Commit(candidate)

Spec == Init /\ [][Next]_vars
NoConflictingValues == Cardinality(committed) <= 1
====
~~~

Create `RaftSafety.cfg` in the same directory:

~~~text
CONSTANTS
  Nodes = {"n1", "n2", "n3"}
  ValueOf = ["n1" |-> "A", "n2" |-> "B", "n3" |-> "A"]
  Buggy = FALSE
SPECIFICATION Spec
INVARIANT NoConflictingValues
~~~

Download the TLA+ tools JAR from the [official TLA+ tools page](https://github.com/tlaplus/tlaplus/releases), place/rename it as `practice/tla/tla2tools.jar`, and check `java -version`. From the TLA folder, run:

~~~bash
java -cp tla2tools.jar tlc2.TLC -config RaftSafety.cfg RaftSafety.tla
~~~

With `Buggy = FALSE`, TLC should finish without violating `NoConflictingValues`. Now change only that constant in the config to `TRUE` and run the same command. TLC should print a counterexample showing that voters can elect two candidates in one term, allowing both values to be committed at the modeled log position. Restore `FALSE` and rerun. Connect `votes` to each peer's per-term vote record and `committed` to the committed entry in the implementation. A model checks only the model and explored state space; it does not automatically verify the Go code.

## Evidence gate

Keep the written failure model, passing 3A–3D test output, one leader-stop trace, one partition trace, one TLA+ counterexample and repaired run, and a short report of one bug the test exposed. If you built the optional key/value adapter, also keep its randomized history and checker output. Complete learned.md. Close the reference code and rebuild the metadata-replication feature in Kestrel from the state model and invariant list. You may consult protocol documentation, but do not copy the implementation.

## Read beside the work

Read one item after the matching behavior appears; use the question to connect it to your experiment.

| When | Read | Carry this question into the reading |
|---|---|---|
| After writing the failure model | DDIA, Chapter 8, “The Trouble with Distributed Systems”; *Understanding Distributed Systems*, Part II sections on system models and failure detection | Which failures can your model observe, and which can it only suspect? |
| Before leader-election work | *Understanding Distributed Systems*, Part II sections on time and leader election; van Steen & Tanenbaum, 4th ed., §§5.1–5.4; Lamport, “Time, Clocks, and the Ordering of Events” | What does a timeout tell you, and what does it not prove? |
| Before the first replication step | DDIA, Chapter 5, “Replication”; Nancy Lynch's distributed-algorithms lecture slides on synchronous/asynchronous models and election | Which safety condition must hold even when progress stops? |
| While completing Lab 3A–3D | Ongaro and Ousterhout, “In Search of an Understandable Consensus Algorithm,” §§1–8 first; read §§9–11 after the tests pass | Which rule protects election safety, log matching, and commitment? |
| Before randomized history checking | DDIA, Chapter 9, “Consistency and Consensus”; read the first three sections of Herlihy and Wing's linearizability paper | Does every returned operation fit one legal sequential history? |
| After a working Raft implementation | Liskov and Cowling, “Viewstamped Replication Revisited”; Lamport, “Paxos Made Simple” | What changes in the roles, messages, or assumptions? |
| When discussing coordination and state | van Steen & Tanenbaum, Chapter 7 §§7.1–7.5, Chapter 8 §§8.1–8.2 and §8.5; SRE, Chapter 23 | What state is small and important enough to coordinate this way? |
| When fault tests pass | DDIA, Chapter 6; Kurose & Ross, 8th ed., §§3.6–3.8 | How do congestion, tail latency, and partitions affect the observed result? |
| Before writing trade-offs | GFS (2003), Spanner (2012), the FLP paper, Gilbert and Lynch's CAP proof, and Dynamo (2007) | Which workload and failure assumptions make each design a reasonable choice? |

Official and primary references: [MIT 6.5840 Lab 3](https://pdos.csail.mit.edu/6.824/labs/lab-raft1.html), [MIT 6.5840 lectures and labs](https://pdos.csail.mit.edu/6.5840/), [HashiCorp Raft](https://github.com/hashicorp/raft), [etcd API guarantees](https://etcd.io/docs/v3.7/learning/api_guarantees/), and [TLA+ tools](https://tla.msr-inria.inria.fr/video/). The MIT course page identifies the exact semester's starter code; if the course URL advances, use that page's current Lab 3 and record the term and commit you followed.
