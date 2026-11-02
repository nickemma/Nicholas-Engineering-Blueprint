# Design: <name>

**Track:** <cloud-infra | distributed-systems | platform | ai-infrastructure | security | data-infrastructure | classic> · **Built in:** <lesson phase or repository link> · **Time spent:** <minutes>

## 0. The crux

Write this first, in 2–4 sentences. What makes this problem hard? Why? Where will most of the time go?

## 1. Requirements

**Functional**

1.
2.
3.

**Non-functional** (with numbers)

| Property | Target |
|---|---|
| Users / requests per second (average, peak) | |
| Data size and growth | |
| Latency (p99) | |
| Availability | |
| Consistency | |
| Durability | |

**Out of scope:**

## 2. Estimates

Only the numbers that change a decision. Show the arithmetic.

## 3. API

A list, not a design. Spend 3 minutes or less.

## 4. Core entities

A list of names and key fields. Spend 3 minutes or less.

## 5. High-level design

~~~mermaid
flowchart LR
    Client --> LB[Load balancer] --> API
~~~

Walk one request through it, end to end.

## 6. Deep dives (crux first)

### 6.1 <the crux>

Options considered, the one chosen, and why. Include numbers.

### 6.2 <next most important>

## 7. Trade-offs and alternatives

| Decision | Chose | Instead of | Because | Revisit when |
|---|---|---|---|---|
| | | | | |

## 8. Failure modes

| Failure | Effect | Detection | Mitigation |
|---|---|---|---|
| A node dies | | | |
| A network partition | | | |
| 10× traffic | | | |
| A hot key or tenant | | | |

## 9. With more time

## 10. Where I've built this

Links to the lesson phases, tests or repositories that implement part of this design.

## 11. Self-score

See [scorecard.md](scorecard.md).

| Dimension | Score (1–4) | Evidence |
|---|---|---|
| Problem navigation | | |
| Solution design | | |
| Technical excellence | | |
| Communication and collaboration | | |
