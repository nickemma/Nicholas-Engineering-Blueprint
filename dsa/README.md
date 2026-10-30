# Data structures and algorithms

Coding interviews for every role in [JOURNEY.md](../JOURNEY.md#11-career-map) include this part. This track teaches the problems **by pattern**, so you recognise the shape of a new problem instead of memorising answers. Every pattern links to a real system that uses it, often one you build in the lessons.

Start in Phase 0, with three sessions a week of 45–60 minutes each.

## What the interviewer is judging

| Dimension | Weak | Strong |
|---|---|---|
| **Problem solving** | Jumps into code; stuck when the first idea fails | Clarifies the problem, tries small examples, names the pattern, compares two approaches |
| **Coding** | Messy, hard to follow, buggy at the edges | Clear names, small functions, correct boundaries |
| **Verification** | "I think it works" | Walks through an example by hand, tests edge cases, states the complexity |
| **Communication** | Silent, or narrating keystrokes | Explains the plan before coding, thinks out loud at decision points, takes hints well |

## The loop for every problem

1. **Understand.** Restate the problem. Ask about input size, empty input, duplicates, negative numbers, sortedness. Write two examples, including an edge case.
2. **Match.** Which pattern does it look like? The "recognise when" column below is your checklist.
3. **Plan.** Describe the brute force and its complexity, then the better approach. Say both out loud before writing code.
4. **Implement.** Write it cleanly. Name things for what they mean.
5. **Review.** Trace your examples by hand. Then test: empty, one element, all the same, the largest size.
6. **Evaluate.** State the time and space complexity, and one trade-off.

Do it in **Go first, then Python**. Go makes you think about types and memory; Python is what many interviewers expect for speed. Being fluent in both is an advantage.

## Patterns, in order

Each pattern is a guide, built like the lessons. It covers when to recognise the pattern, then one or two **worked problems** built step by step in Go and then Python, with tests. It names a real system that uses the pattern, often one you build in the lessons, and ends with **practice problems** (with hints, and no solutions) that you solve alone.

| # | Pattern | Recognise when | Where real systems use it | Worked | Practice |
|---|---|---|---|---|---|
| 00 | [Complexity and Big-O](00-complexity/README.md) | Always | Capacity planning (Phase 5); a measured surprise about caches | 1 | 5 questions |
| 01 | [Arrays and hashing](01-arrays-hashing/README.md) | "Seen before?", counting, grouping | Idempotency keys (Phases 2–3) | 2 | 6 |
| 02 | [Two pointers](02-two-pointers/README.md) | Sorted input; pairs; in-place changes | Merging sorted runs in LSM compaction (Phase 3) | 2 | 4 |
| 03 | [Sliding window](03-sliding-window/README.md) | Longest or shortest contiguous range under a rule | Rate limits (Phase 6); burn-rate windows (Phase 5) | 2 | 5 |
| 04 | [Stack and monotonic stack](04-stack/README.md) | Matching pairs; "next greater" | The JSON parser Runway uses since Phase 0 | 2 | 4 |
| 05 | [Binary search](05-binary-search/README.md) | Sorted data, or a yes/no question that flips once | The consistent-hash ring (Phase 4); B-tree pages (Phase 3) | 2 | 5 |
| 06 | [Linked lists](06-linked-lists/README.md) | Pointer rewiring; O(1) reordering | LRU caches; Redis eviction (Phase 3) | 2 | 4 |
| 07 | [Trees: DFS and BFS](07-trees/README.md) | Hierarchies; levels; paths | B-tree indexes (Phase 3); the Merkle tree (Phase 6); boosted trees (Phase 7) | 2 | 6 |
| 08 | [Heaps and priority queues](08-heaps/README.md) | "Top *k*", "next smallest", merge *k* lists | Go's timers (Phase 1); priority lanes (Phase 7) | 2 | 5 |
| 09 | [Graphs: BFS, DFS, topological sort](09-graphs/README.md) | Dependencies; reachability; ordering | `go build`'s package order; Kubernetes garbage collection (Phase 5) | 2 | 6 |
| 10 | [Union-find](10-union-find/README.md) | Groups that merge | Who can reach whom in a partition (Phase 4) | 1 | 3 |
| 11 | [Shortest paths (Dijkstra)](11-shortest-paths/README.md) | Weighted routes | Link-state routing under Phases 2 and 5 | 1 | 3 |
| 12 | [Intervals](12-intervals/README.md) | Overlaps; merging ranges | Lock leases (Phase 4); scoring alerts against incidents (Phase 7) | 1 | 4 |
| 13 | [Backtracking](13-backtracking/README.md) | "All combinations or permutations" | TLC exploring a TLA+ model (Phase 4) | 2 | 4 |
| 14 | [Dynamic programming, 1D](14-dp-1d/README.md) | Best answer built from smaller answers | PostgreSQL's join-order search (Phase 3) | 2 | 5 |
| 15 | [Dynamic programming, 2D](15-dp-2d/README.md) | Two sequences; grids | `diff` and `git diff`; edit distance | 2 | 5 |
| 16 | [Tries](16-tries/README.md) | Prefix lookups | Go's router (Phase 0); longest-prefix IP routing | 1 | 3 |
| 17 | [Greedy](17-greedy/README.md) | A locally best choice that's provably safe | The Kubernetes scheduler (Phase 5) | 2 | 3 |
| 18 | [Bit manipulation](18-bit-manipulation/README.md) | Flags; parity; sets of small integers | The CRC-32C (Rust Bridge); subnet masks | 2 | 2 |
| 19 | [Design problems](19-design/README.md) | "Implement X with these operations" | Runway's token bucket (Phase 6) and hash ring (Phase 4), rebuilt | 2 | 3 |

That's **114 problems**: 34 worked and 80 to practise, all free on LeetCode. Add problems from the same patterns until you reach **150+** over the whole program; the NeetCode 150 and Blind 75 lists are good sources.

## Your own repository

Do the guides in a repository of your own, called `dsa`. Guide 00 sets it up as one Go module and one Python project. Each pattern gets a folder that's both a Go package and a Python package:

~~~text
dsa/
  go.mod                  module dsa
  pyproject.toml          pytest and ruff
  arrays/
    two_sum.go            Go solution
    two_sum_test.go       table-driven tests
    two_sum.py            Python solution
    test_two_sum.py       pytest tests
  twopointers/
  ...
~~~

Put your practice solutions in the same folders, with tests, and the CI from Phase 0 can run them all. Each problem file starts with a short statement in your own words and a link to the original. Don't copy problem text from the site.

The worked problems are checked like the lessons: `scripts/check_guides.py` rebuilds every guide's code from the guide itself and runs its Go and Python tests, in CI.

## Spaced review

Solving a problem once isn't remembering it. Re-solve it from a blank file on a schedule: **1 day, 3 days, 7 days, 21 days** after the first solve. If you can't, the counter resets. Track it in your own repository:

| Date | Problem | Pattern | Solved alone? | Time | Next review | Note |
|---|---|---|---|---|---|---|
| | | | | | | |

## Practising like the real thing

From Phase 2 on, do one **timed mock** every two weeks: 45 minutes, a problem you haven't seen, talking out loud the whole time. Ask a peer to interview you if you can, or record yourself. Score yourself against the four dimensions above.
