# 06 Model election safety with TLA+

> Consensus in depth · Week 3 · Builds on lesson 05

## The problem

The simulator executes the schedule you give it. Three peers can vote in many orders. We want a model that searches those orders within a small finite configuration.

## The mental model

Draw a table with one row per peer and columns for term, role, vote, and votes collected. Record a separate set of all elected peer and term pairs so a later demotion cannot erase evidence of an earlier election.

## The pattern

TLA+ describes allowed state transitions. A primed variable is its next-state value. In `EXCEPT ![s]`, only the slot for server `s` changes. `UNCHANGED` carries the listed variables forward. TLC enumerates reachable states for the supplied constants.

## Build it

### Step 1 — Model one election step at a time

Write initial values, then model a timeout, recording a vote, and becoming leader. Keep an election history so the invariant covers every past election in a term.

<details>
<summary>Hint 1</summary>

Compare every pair in the elected set that shares a term.

</details>

<details>
<summary>Hint 2</summary>

A second vote in the same term must name the same candidate in the reference model.

</details>

<details>
<summary>Implementation</summary>

Create `tla/RaftElection.tla`.

<!-- file: tla/RaftElection.tla -->
~~~tla
---------------------------- MODULE RaftElection ----------------------------
(* Raft's leader election, and nothing else: terms, votes, and becoming    *)
(* leader. Sending a vote request and getting the answer are modelled as  *)
(* one step, which hides message loss and delay but keeps every order in  *)
(* which servers can time out, vote and win.                              *)
EXTENDS Naturals, FiniteSets

CONSTANTS Servers, MaxTerm, AllowDoubleVote

VARIABLES
    term,      \* each server's current term
    role,      \* "follower", "candidate" or "leader"
    votedFor,  \* whom each server voted for in its current term, or Nil
    votes,     \* the votes each candidate has collected
    elected    \* history: every <<server, term>> that ever won

vars == <<term, role, votedFor, votes, elected>>

Nil == "nil"

\* A quorum is any set of more than half the servers.
IsQuorum(S) == Cardinality(S) * 2 > Cardinality(Servers)

Init ==
    /\ term     = [s \in Servers |-> 0]
    /\ role     = [s \in Servers |-> "follower"]
    /\ votedFor = [s \in Servers |-> Nil]
    /\ votes    = [s \in Servers |-> {}]
    /\ elected  = {}

\* Server s times out and stands for election in a new term, voting for
\* itself.
Timeout(s) ==
    /\ role[s] # "leader"
    /\ term[s] < MaxTerm
    /\ term'     = [term     EXCEPT ![s] = @ + 1]
    /\ role'     = [role     EXCEPT ![s] = "candidate"]
    /\ votedFor' = [votedFor EXCEPT ![s] = s]
    /\ votes'    = [votes    EXCEPT ![s] = {s}]
    /\ UNCHANGED elected

\* Server v votes for candidate c. A newer term resets v's vote, and v
\* becomes a follower; within one term, v votes at most once.
Vote(v, c) ==
    /\ v # c
    /\ role[c] = "candidate"
    /\ term[v] <= term[c]
    /\ AllowDoubleVote \/ term[v] < term[c] \/ votedFor[v] \in {Nil, c}
    /\ term'     = [term     EXCEPT ![v] = term[c]]
    /\ role'     = [role     EXCEPT ![v] = "follower"]
    /\ votedFor' = [votedFor EXCEPT ![v] = c]
    /\ votes'    = [votes    EXCEPT ![c] = @ \cup {v}]
    /\ UNCHANGED elected

\* A candidate with votes from a quorum becomes leader.
BecomeLeader(c) ==
    /\ role[c] = "candidate"
    /\ IsQuorum(votes[c])
    /\ role'    = [role EXCEPT ![c] = "leader"]
    /\ elected' = elected \cup {<<c, term[c]>>}
    /\ UNCHANGED <<term, votedFor, votes>>

Next ==
    \E s \in Servers :
        \/ Timeout(s)
        \/ BecomeLeader(s)
        \/ \E v \in Servers : Vote(v, s)

Spec == Init /\ [][Next]_vars

\* The property: no term ever has two leaders, at any time in the history.
ElectionSafety ==
    \A x, y \in elected : x[2] = y[2] => x[1] = y[1]

=============================================================================
~~~

</details>

### Step 2 — Check a small model and its control

Use Java 21 and verify it with `java -version`. The gate downloads a checksum-pinned TLC jar, or you can pass its local path in `TLA2TOOLS_JAR`.

<details>
<summary>Hint 1</summary>

Bound the term so the state space is finite.

</details>

<details>
<summary>Hint 2</summary>

Change the AllowDoubleVote constant in a second configuration and run the same invariant.

</details>

<details>
<summary>Implementation</summary>

Create `tla/RaftElection.cfg`.

<!-- file: tla/RaftElection.cfg -->
~~~text
SPECIFICATION Spec
CONSTANTS
    Servers = {s1, s2, s3}
    MaxTerm = 3
    AllowDoubleVote = FALSE
INVARIANT ElectionSafety
~~~

Create `tla/DoubleVote.cfg`.

<!-- file: tla/DoubleVote.cfg -->
~~~text
SPECIFICATION Spec
CONSTANTS
    Servers = {s1, s2, s3}
    MaxTerm = 3
    AllowDoubleVote = TRUE
INVARIANT ElectionSafety
~~~

</details>

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/02-consensus-in-depth/gate/run.sh" "$PWD" tla
~~~

TLC found 4,687 distinct states and exhausted the reference queue. The double-vote configuration produced a seven-state counterexample with two leaders in term 1. The model abstracts away persistence, log freshness, and transport timing. [TLC traces](../evidence/README.md)

## If it goes wrong

If finite terminal states trigger deadlock errors, check the gate’s `-deadlock` flag. If the broken model passes, read the constant binding and verify that the invariant records leaders even after they step down.
