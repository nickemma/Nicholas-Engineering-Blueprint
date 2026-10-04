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

| # | Pattern | Recognise when | Where real systems use it | Problems | Status |
|---|---|---|---|---|---|
| 00 | Complexity and Big-O | Always | Capacity planning (Phase 5) | — | Planned |
| 01 | Arrays and hashing | "Seen before?", counting, grouping | Dedup by idempotency key (Phase 2) | 8 | Planned |
| 02 | Two pointers | Sorted input; pairs; in-place changes | Merging sorted runs during compaction (Phase 3) | 6 | Planned |
| 03 | Sliding window | Longest or shortest contiguous range under a rule | Rate limiters (Phase 6); moving-window SLOs (Phase 5) | 6 | Planned |
| 04 | Stack and monotonic stack | Matching pairs; "next greater" | Parsers; undo; expression evaluation | 6 | Planned |
| 05 | Binary search | Sorted data, or a yes/no question that flips once | Consistent-hash ring lookup; finding the first bad commit | 7 | Planned |
| 06 | Linked lists | Pointer rewiring; cycles | LRU cache (list + map); free lists | 6 | Planned |
| 07 | Trees: DFS and BFS | Hierarchies; levels; paths | Filesystems; B-tree indexes (Phase 3) | 8 | Planned |
| 08 | Heaps and priority queues | "Top k", "next smallest", merge k lists | Job schedulers; timers; LSM merges | 6 | Planned |
| 09 | Graphs: BFS, DFS, topological sort | Dependencies; reachability; ordering | Migration order; build systems; Kubernetes controllers | 8 | Planned |
| 10 | Union-find | Groups that merge | Network partitions (Phase 4); clustering | 4 | Planned |
| 11 | Shortest paths (Dijkstra) | Weighted routes | Routing (Phase 5) | 4 | Planned |
| 12 | Intervals | Overlaps; meeting rooms | Lease and lock windows (Phase 4); calendars | 5 | Planned |
| 13 | Backtracking | "All combinations or permutations" | Constraint search; test-case generation | 6 | Planned |
| 14 | Dynamic programming, 1D | Best answer built from smaller answers | Retry budgets; resource planning | 7 | Planned |
| 15 | Dynamic programming, 2D | Two sequences; grids | Diff tools (`diff`, `git`); edit distance | 7 | Planned |
| 16 | Tries | Prefix lookups | Router path matching (Phase 0); autocomplete | 4 | Planned |
| 17 | Greedy | A locally best choice that's provably safe | Schedulers; bin packing for pods (Phase 5) | 5 | Planned |
| 18 | Bit manipulation | Flags; parity; sets of small integers | Bloom filters; permission bitmasks (Phase 6) | 4 | Planned |
| 19 | Design problems | "Implement X with these operations" | LRU cache, rate limiter, consistent hashing | 5 | Planned |

That's about 120 problems in the folders. Add problems from the same patterns until you reach **150+** over the whole program.

## Folder layout

~~~text
dsa/
  go.mod                         one Go module for every pattern
  01-arrays-hashing/
    README.md                    recognise when, template, complexity, pitfalls, real-system link
    contains_duplicate.go        Go solution
    contains_duplicate_test.go   table-driven tests
    contains_duplicate.py        Python solution
    test_contains_duplicate.py   pytest tests
~~~

Each problem file starts with a short problem statement in our own words and a link to the original problem. We don't copy problem text from paid sites.

## Spaced review

Solving a problem once isn't remembering it. Re-solve it from a blank file on a schedule: **1 day, 3 days, 7 days, 21 days** after the first solve. If you can't, the counter resets. Track it in your own repository:

| Date | Problem | Pattern | Solved alone? | Time | Next review | Note |
|---|---|---|---|---|---|---|
| | | | | | | |

## Practising like the real thing

From Phase 2 on, do one **timed mock** every two weeks: 45 minutes, a problem you haven't seen, talking out loud the whole time. Ask a peer to interview you if you can, or record yourself. Score yourself against the four dimensions above.
