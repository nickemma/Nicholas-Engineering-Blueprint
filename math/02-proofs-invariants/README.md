# 02. Proofs and invariants

<!-- continue: ../01-queueing/README.md -->

Tests show a program works on the cases you tried. A distributed system runs through more cases than you could ever try, and the ones that break it are the rare ones. This guide teaches the mathematics that covers every case: **induction** and **invariants**. It ends with Raft's safety argument, and with a working model checker you've written yourself, so that TLA+ stops being magic.

**Real systems:** [Phase 4](../../lessons/04-replicated-state/README.md) builds Raft, and models elections in [TLA+ in step 9](../../lessons/04-replicated-state/TEACHING.md#step-9-a-tla-model-of-elections). [DSA's binary search](../../dsa/05-binary-search/README.md) relies on a loop invariant. For AI-generated code, this is the sharpest tool you have: asking "what stays true on every step?" finds bugs that a passing test suite won't.

## Induction

To prove something about every whole number, prove two things:

1. **Base case:** it's true for the first one.
2. **Inductive step:** *if* it's true for some *n*, *then* it's true for *n* + 1.

It works like dominoes. The first falls, and each one knocks over the next, so all of them fall. You never check them one at a time.

**Claim:** 1 + 2 + … + *n* = *n*(*n* + 1)/2.

- **Base:** for *n* = 1, both sides are 1.
- **Step:** suppose it's true for *n*. Then 1 + … + *n* + (*n* + 1) = *n*(*n* + 1)/2 + (*n* + 1) = (*n* + 1)(*n* + 2)/2, which is the claim for *n* + 1.

That's where "a loop inside a loop over the same data is O(*n*²)" comes from.

## Loop invariants

A loop is induction in disguise. An **invariant** is a statement that's true every time the loop reaches a certain point. To prove a loop correct, show:

1. **Initialisation:** it's true before the first iteration.
2. **Maintenance:** if it's true before an iteration, it's true after.
3. **Termination:** when the loop ends, the invariant tells you the answer is right. And the loop does end.

Here's the sum, and binary search. Each takes a `check` function, so a test can test the invariant at every step, and not only the final answer:

<!-- file: proofs/invariants.py -->
~~~python
"""Small programs with loop invariants that the tests check at every step."""

from collections.abc import Callable, Sequence


def sum_to(n: int, check: Callable[[int, int], None] = lambda i, total: None) -> int:
    """Return 1 + 2 + ... + n, calling check(i, total) before each step."""
    total = 0
    for i in range(1, n + 1):
        check(i, total)
        total += i
    return total


def search(
    items: Sequence[int],
    target: int,
    check: Callable[[int, int], None] = lambda low, high: None,
) -> int:
    """Return target's position in sorted items, or -1.

    Invariant: if target is anywhere, it's at a position in [low, high).
    """
    low, high = 0, len(items)
    while low < high:
        check(low, high)
        middle = (low + high) // 2
        if items[middle] == target:
            return middle
        if items[middle] < target:
            low = middle + 1
        else:
            high = middle
    return -1
~~~

For `search`, the invariant is in the docstring: **if the target is anywhere, it's in [low, high)**.

- **Initialisation:** [0, len) is the whole list.
- **Maintenance:** if the middle item is too small, then so is everything to its left, since the list is sorted. Setting `low = middle + 1` throws away only items that can't be the target. Likewise for `high`.
- **Termination:** the range shrinks each time, so the loop ends. If it ends with `low == high`, the range is empty, so by the invariant the target isn't there.

Notice what the proof tells you. Write `high = middle - 1`, a classic bug, and maintenance breaks, because with a half-open range you'd throw away a position that might hold the target. The invariant shows you the bug before any test does.

Now the leading idea of this guide, which appears again below. **An invariant has to be strong enough to carry itself from one step to the next.** "low ≤ high" is also always true here, but it says nothing about the target, so it proves nothing.

## Safety and liveness

Two kinds of claim:

- **Safety:** nothing bad ever happens. "There are never two leaders in a term." One bad state disproves it, so a counterexample is a finite trace.
- **Liveness:** something good eventually happens. "A leader is eventually elected." No finite trace can disprove it, since it might still happen later.

Raft guarantees safety **always**, even with messages lost, delayed or reordered. It guarantees liveness only when timing behaves. That split is the [FLP result](https://groups.csail.mit.edu/tds/papers/Lynch/jacm85.pdf) in practice: an asynchronous system can't guarantee both. Safety is the part you prove with invariants.

## Why a majority works

Raft's safety rests on one small fact, the **pigeonhole principle**: if you put more than *n* items in *n* boxes, some box holds two.

**Claim:** any two majorities of the same set overlap.

**Proof.** Take 2*f* + 1 servers. A majority has at least *f* + 1. Two majorities have at least 2*f* + 2 members between them, among only 2*f* + 1 servers, so some server is in both. ∎

**Election Safety: at most one leader per term.**

**Proof.** A leader needs votes from a majority in its term. Suppose two different servers won term *t*. Their majorities overlap, so some server voted for both. But a server votes at most once per term, and it records that vote on disk before answering. Contradiction. ∎

Three lines, and they cover every possible schedule of messages, crashes and restarts. No test suite can do that. It also says why each rule exists: drop the vote limit, or the persistence, or the majority, and the proof fails at a particular line.

## Raft's full safety argument

Election Safety isn't enough. What clients care about is **State Machine Safety**: if one server applies a command at some log position, no server ever applies a different one there. The Raft paper gets there through a chain of invariants, each one resting on those before it:

| Invariant | What it says | Why it holds |
|---|---|---|
| **Election Safety** | At most one leader per term | Majorities overlap; one vote per term |
| **Leader Append-Only** | A leader never overwrites or deletes its log | That's the rule it follows |
| **Log Matching** | Two logs with the same index and term at an entry are identical up to there | A leader makes one entry per index in a term, and `AppendEntries` checks the entry before |
| **Leader Completeness** | A committed entry is in the log of every later leader | The commit's majority overlaps the voters' majority, and a voter refuses a less up-to-date candidate |
| **State Machine Safety** | No two servers apply different commands at one index | Follows from the two above |

Leader Completeness is the deep one. Suppose an entry was committed in term *T*, and a leader of a later term lacks it. Take the first such leader. Some server that stored the entry also voted for that leader, since the two majorities overlap. That voter's log was at least as up to date as the candidate's, or it wouldn't have voted, and following Log Matching through, that forces the candidate to have the entry. Contradiction. The full proof has a subtle case, which is why Raft only counts replicas to commit entries from the **current** term. You met that rule in Phase 4: it's there because a proof needed it, and the paper's Figure 8 shows the failure without it.

## A model checker of your own

A proof by hand can be wrong. A **model checker** takes a different route: describe the system as a state machine, then visit **every reachable state**, testing the invariant in each. It's brute force, only feasible for small models, and very effective: Lamport's tool TLC does this for TLA+. The core takes about twenty lines:

<!-- file: proofs/checker.py -->
~~~python
"""An explicit-state model checker: the idea behind TLC, in a few lines."""

from collections import deque
from collections.abc import Callable, Hashable, Iterable
from dataclasses import dataclass


@dataclass
class Result:
    states: int  # distinct states reached
    trace: list | None  # a path to a bad state, or None if there's none


def check[S: Hashable](
    init: Iterable[S],
    next_states: Callable[[S], Iterable[S]],
    invariant: Callable[[S], bool],
) -> Result:
    """Visit every reachable state, breadth first, and test the invariant.

    Breadth first means that a trace, if there is one, is a shortest one.
    """
    parent: dict[S, S | None] = {s: None for s in init}
    queue = deque(parent)
    while queue:
        state = queue.popleft()
        if not invariant(state):
            trace = [state]
            while (previous := parent[trace[-1]]) is not None:
                trace.append(previous)
            return Result(len(parent), trace[::-1])
        for following in next_states(state):
            if following not in parent:
                parent[following] = state
                queue.append(following)
    return Result(len(parent), None)


def inductive[S](
    states: Iterable[S],
    next_states: Callable[[S], Iterable[S]],
    invariant: Callable[[S], bool],
) -> tuple[S, S] | None:
    """Test whether invariant is inductive, over every state, reachable or not.

    Returns None if each step from a state satisfying it leads to another
    such state, or else a counterexample: a (good, bad) pair of states.
    """
    for state in states:
        if invariant(state):
            for following in next_states(state):
                if not invariant(following):
                    return state, following
    return None
~~~

`inductive` is the second function, and it's explained below. Now describe elections. A state records who voted for whom and who won. A **step** is any single thing that could happen: any server votes, or anyone with a quorum declares victory. There are no timers or messages, and that's deliberate. They could only make some steps fail to happen, and a safety property asks what's **possible**. Rules that keep things safe in this model, with every step allowed in any order, keep them safe in a real network.

<!-- file: proofs/election.py -->
~~~python
"""Raft's leader election as a state machine, small enough to check every state.

A state records who voted for whom in each term, and who became leader. It
leaves out timers, messages and logs: messages can be delayed or lost, but
that only makes fewer steps happen, and a safety property is about which
steps are possible.
"""

from collections.abc import Iterator
from dataclasses import dataclass
from itertools import product

SERVERS = (0, 1, 2)
TERMS = (0, 1)
NO_VOTE = -1


@dataclass(frozen=True)
class State:
    votes: tuple[tuple[int, ...], ...]  # votes[term][server]: who it voted for
    leaders: tuple[frozenset[int], ...]  # leaders[term]: who won


@dataclass(frozen=True)
class Rules:
    quorum: int = 2  # votes needed to win
    vote_once: bool = True  # may a server vote only once in a term?


def initial() -> State:
    return State(
        votes=tuple(tuple(NO_VOTE for _ in SERVERS) for _ in TERMS),
        leaders=tuple(frozenset() for _ in TERMS),
    )


RAFT = Rules()


def next_states(state: State, rules: Rules = RAFT) -> Iterator[State]:
    """Yield every state one step away: any server votes, or anyone wins."""
    for term in TERMS:
        ballots = state.votes[term]
        for voter in SERVERS:
            if rules.vote_once and ballots[voter] != NO_VOTE:
                continue
            for candidate in SERVERS:
                if ballots[voter] != candidate:  # a real change of vote
                    updated = (*ballots[:voter], candidate, *ballots[voter + 1 :])
                    votes = (*state.votes[:term], updated, *state.votes[term + 1 :])
                    yield State(votes, state.leaders)
        for candidate in SERVERS:
            if candidate not in state.leaders[term]:
                if ballots.count(candidate) >= rules.quorum:
                    won = state.leaders[term] | {candidate}
                    leaders = (*state.leaders[:term], won, *state.leaders[term + 1 :])
                    yield State(state.votes, leaders)


def election_safety(state: State) -> bool:
    """At most one leader per term."""
    return all(len(won) <= 1 for won in state.leaders)


def leaders_have_a_quorum(state: State, quorum: int = 2) -> bool:
    """Everyone who won a term holds a quorum of that term's votes."""
    return all(
        state.votes[term].count(leader) >= quorum
        for term in TERMS
        for leader in state.leaders[term]
    )


def strengthened(state: State) -> bool:
    """A stronger property, which does survive every step."""
    return election_safety(state) and leaders_have_a_quorum(state)


def every_state() -> Iterator[State]:
    """Yield every state of the right shape, reachable or not."""
    ballots = list(product((NO_VOTE, *SERVERS), repeat=len(SERVERS)))
    winners = [
        frozenset(s for s, won in zip(SERVERS, bits, strict=True) if won)
        for bits in product((False, True), repeat=len(SERVERS))
    ]
    for votes in product(ballots, repeat=len(TERMS)):
        for leaders in product(winners, repeat=len(TERMS)):
            yield State(votes, leaders)


def describe(trace: list[State]) -> str:
    """Render a trace, one step per line, as votes by term and who has won."""
    lines = []
    for number, state in enumerate(trace):
        winners = {t: sorted(won) for t, won in enumerate(state.leaders) if won}
        lines.append(f"{number}: votes {state.votes[0]} {state.votes[1]}  leaders {winners}")
    return "\n".join(lines)
~~~

The tests make the checker prove something, then break the rules to see that it notices:

<!-- file: proofs/test_proofs.py -->
~~~python
import random
from functools import partial
from itertools import combinations

import pytest

from proofs import election
from proofs.checker import check, inductive
from proofs.election import Rules, election_safety, initial, next_states, strengthened
from proofs.invariants import search, sum_to


@pytest.mark.parametrize("n", [0, 1, 2, 10, 1000])
def test_the_sum_formula_at_every_step(n):
    def check_step(i, total):
        assert total == (i - 1) * i // 2

    assert sum_to(n, check_step) == n * (n + 1) // 2


def search_checking_the_invariant(items, target):
    def check_step(low, high):
        if target in items:
            assert low <= items.index(target) < high

    return search(items, target, check_step)


def test_search_keeps_its_invariant_on_random_lists():
    rng = random.Random(1)
    for _ in range(2000):
        items = sorted(rng.sample(range(100), rng.randrange(0, 30)))
        target = rng.randrange(100)
        found = search_checking_the_invariant(items, target)
        assert found == (items.index(target) if target in items else -1)


def test_every_two_majorities_of_five_overlap():
    majorities = [set(c) for c in combinations(range(5), 3)]
    assert all(a & b for a in majorities for b in majorities)


def test_raft_rules_keep_election_safety():
    assert check([initial()], next_states, election_safety).trace is None


@pytest.mark.parametrize("rules", [Rules(vote_once=False), Rules(quorum=1)])
def test_broken_rules_are_caught(rules):
    result = check([initial()], partial(next_states, rules=rules), election_safety)
    assert result.trace is not None
    assert result.trace[0] == initial()
    assert not election_safety(result.trace[-1])


def test_the_checker_finds_a_shortest_trace():
    # Counting up by 1 or 2 from 0: the shortest way to 5 has three steps.
    result = check([0], lambda n: [n + 1, n + 2] if n < 10 else [], lambda n: n != 5)
    assert len(result.trace) == 4


def test_election_safety_alone_is_not_inductive():
    assert inductive(election.every_state(), next_states, election_safety) is not None


def test_the_strengthened_invariant_is_inductive():
    assert inductive(election.every_state(), next_states, strengthened) is None
~~~

<!-- file: proofs/show.py -->
~~~python
"""Run the checks in the guide, and print what each one finds."""

from functools import partial

from proofs.checker import check, inductive
from proofs.election import (
    Rules,
    describe,
    election_safety,
    every_state,
    initial,
    next_states,
    strengthened,
)


def report(title: str, rules: Rules) -> None:
    result = check([initial()], partial(next_states, rules=rules), election_safety)
    print(f"{title}: {result.states} states, ", end="")
    if result.trace is None:
        print("invariant holds")
    else:
        print(f"VIOLATED in {len(result.trace) - 1} steps")
        print(describe(result.trace))


def main() -> None:
    report("Raft's rules", Rules())
    report("A server may vote twice", Rules(vote_once=False))
    report("A quorum of one", Rules(quorum=1))
    print()
    for name, invariant in (("election_safety", election_safety), ("strengthened", strengthened)):
        found = inductive(every_state(), next_states, invariant)
        print(f"{name} inductive? {'yes' if found is None else 'no'}")
        if found is not None:
            print(describe(list(found)))


if __name__ == "__main__":
    main()
~~~

<!-- run: uv run pytest -q proofs && uv run ruff format --check . && uv run ruff check . -->

~~~bash
uv run pytest -q proofs
uv run python -m proofs.show
~~~

~~~text
Raft's rules: 8836 states, invariant holds
A server may vote twice: 11220 states, VIOLATED in 6 steps
0: votes (-1, -1, -1) (-1, -1, -1)  leaders {}
1: votes (0, -1, -1) (-1, -1, -1)  leaders {}
2: votes (0, 0, -1) (-1, -1, -1)  leaders {}
3: votes (0, 0, 1) (-1, -1, -1)  leaders {}
4: votes (0, 0, 1) (-1, -1, -1)  leaders {0: [0]}
5: votes (1, 0, 1) (-1, -1, -1)  leaders {0: [0]}
6: votes (1, 0, 1) (-1, -1, -1)  leaders {0: [0, 1]}
A quorum of one: 4145 states, VIOLATED in 4 steps
0: votes (-1, -1, -1) (-1, -1, -1)  leaders {}
1: votes (0, -1, -1) (-1, -1, -1)  leaders {}
2: votes (0, 1, -1) (-1, -1, -1)  leaders {}
3: votes (0, 1, -1) (-1, -1, -1)  leaders {0: [0]}
4: votes (0, 1, -1) (-1, -1, -1)  leaders {0: [0, 1]}

election_safety inductive? no
0: votes (-1, -1, -1) (-1, 0, 0)  leaders {1: [2]}
1: votes (-1, -1, -1) (-1, 0, 0)  leaders {1: [0, 2]}
strengthened inductive? yes
~~~

Each line of a trace is one step: the votes in term 0 and term 1, with `-1` for no vote, and the winners by term.

- **Raft's rules hold** in all 8,836 reachable states of three servers and two terms. Not a sample: all of them.
- **Let a server vote twice,** and in six steps server 0 votes for itself, and for server 1, and both win term 0. The trace is the bug report.
- **Make a quorum one vote,** and it takes four steps. Those are the two rules the three-line proof used, and the checker finds the same two. A passing test of "elect a leader" wouldn't have.

Breadth-first search means that the trace is a shortest one. A real system's failure might need a thousand unrelated steps, but the checker hands you only the ones that matter. That's what you saw in Phase 4, where TLC found a broken vote rule.

## True isn't the same as inductive

Look at the last part of the output. "At most one leader" holds in every **reachable** state, and yet it isn't **inductive**. To be inductive, a property must survive one step from **any** state where it's true, reachable or not.

The counterexample shows why. Take a state where term 1's winner is server 2, and servers 1 and 2 have voted for server 0. That state has one leader, so it satisfies the property. It can't actually happen, since server 2 won with no votes. But one step from it, server 0 wins as well, and there are two leaders.

So you can't prove "at most one leader" by induction on that statement alone. It's too weak to carry itself, as "low ≤ high" was. **Strengthen** it, by adding the reason it's true: *every leader holds a quorum of its term's votes*. That stronger statement is inductive, and the checker confirms it across all 262,144 states of the right shape, reachable or not.

This is the real work of proving systems correct: finding the invariant that's strong enough. The thing you want to prove is rarely inductive by itself, and strengthening it forces you to say **why** the system works.

## How TLA+ fits

You've now written the core of TLC, and TLA+ names the same parts:

| Here | TLA+ |
|---|---|
| `initial()` | `Init` |
| `next_states` | `Next`, a disjunction of actions |
| `election_safety` | `INVARIANT` in the `.cfg` file |
| `SERVERS`, `TERMS` | `CONSTANTS`, set small for checking |
| `check` | TLC |
| `describe(trace)` | TLC's error trace |

What does TLA+ add? A precise language that isn't tied to one implementation; a far faster checker, with symmetry reduction, temporal properties for liveness, and history variables; and TLAPS for machine-checked proofs. Most important is the discipline: writing a spec shows up the unclear parts of a design before any code exists. Amazon reported finding serious bugs in DynamoDB and S3 designs this way. And a spec is a model: it says nothing about whether your **code** matches. That's why Phase 4 also has a deterministic simulator and Porcupine's linearizability checks.

## What to do with this

- **When you review a loop, name its invariant.** If you can't, you don't know why it works. That goes for AI-written code as well.
- **When you review a protocol, ask what overlaps.** Most quorum systems reduce to two sets having to intersect. Practice problem 7 below is the same fact.
- **Ask what each rule is for.** Remove it, and see which proof breaks. If none does, it's cargo cult, or your invariant is missing something.
- **A model is worth writing when the protocol is small and the bugs are subtle.** It isn't for business logic.

## Practice

Solve these alone. There are no solutions here.

1. Prove by induction that a binary tree of height *h* has at most 2^(*h*+1) − 1 nodes. What does that say about a B-tree's depth?
2. Write the invariant for insertion sort's outer loop, and prove all three parts.
3. Change `search` to `high = middle - 1`, keeping the half-open range. Use the `check` hook to find the failing input, and say which part of the proof breaks.
4. Add a `persist` rule to `election.py`: a server can crash and forget its vote. Does the checker find the bug? This is why votes go to disk before the reply.
5. Add a third term. How does the number of states grow? Add a fourth server: what does a quorum need to be, and what happens with a quorum of 2?
6. Model a simple lock server with a lease: a client holds the lock until its lease expires. Add a slow client that writes after expiry. What invariant fails, and how does Phase 4's fencing token fix it?
7. Prove that R + W > N means that a read overlaps the latest write. What does it stop guaranteeing during a sloppy quorum?

## Read

- Ongaro and Ousterhout, [*In Search of an Understandable Consensus Algorithm*](https://raft.github.io/raft.pdf): section 5.4 for the safety argument, and Figure 8.
- Newcombe et al., [*How Amazon Web Services Uses Formal Methods*](https://cacm.acm.org/research/how-amazon-web-services-uses-formal-methods/), Communications of the ACM, 2015.
- Leslie Lamport, [*Specifying Systems*](https://lamport.azurewebsites.net/tla/book.html), and [the TLA+ video course](https://lamport.azurewebsites.net/video/videos.html).
- Hillel Wayne, [*Learn TLA+*](https://learntla.com/).
