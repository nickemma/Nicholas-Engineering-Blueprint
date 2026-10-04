# Phase 4 learning record

Answer from test histories and traces. Draw diagrams where a sentence would hide timing.

1. What fault model did you assume? What behavior would be Byzantine and therefore outside this lesson's guarantee?
2. Why is a timeout suspicion rather than proof of failure?
3. What is a term? What state must a node persist across restart?
4. Draw the path of a command from client to committed state machine result.
5. Why can one node be unavailable while the other two still commit? Why can one isolated node not commit by itself?
6. State the safety property tested by your invariant. What did the TLC counterexample show before repair?
7. What did the linearizability checker receive? What does a passing finite history establish, and what does it not establish?
8. How does etcd's role as a coordination store differ from storing KESTREL source records?
9. Describe one bug your fault test found and the invariant it violated.

| Evidence | Attach |
|---|---|
| Leader replacement | event trace with terms and node roles |
| Minority partition cannot commit | test name and output |
| Majority partition commits and minority catches up | test name and output |
| Client history is checked | saved history and checker result |
| Model finds and then avoids one violation | TLC counterexample and repaired output |

## Kestrel transfer

- What metadata did I replicate, and why is it small and safe to replicate?
- What state must survive a node restart?
- What did I implement without looking at lesson code?
- What failed first, and how did I diagnose it?
- Which protocol property can I explain from a test trace rather than memory?
- What differs from the exercise and why?
- What is still unclear?
