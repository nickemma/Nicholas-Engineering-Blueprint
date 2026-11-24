# Your first system design

Start with a short-link service at a scale you can reason about on paper. Give yourself 20 minutes. At each step, write your answer before reading the worked choice.

## 1. Clarify what users need

A user submits a long URL and gets a short one. Someone opening the short URL should be redirected. Ask whether links expire or can be edited. For this first pass, assume links are immutable and the main requirement is that valid links keep working.

## 2. Draw one request before picking components

A create request generates a code and stores the mapping. A redirect looks up the code and returns the stored URL. Start with one application and one database. A unique index on the code serves both paths. Ask what the user sees if the code does not exist.

## 3. Walk one edge case

Two creates can pick the same code at the same time. Let the database's uniqueness constraint choose one successful insert. Retry code generation for the other request with a limit, then return an explicit error if retries are exhausted. Explain why an application-level check before insertion can race.

## 4. Change one constraint

Suppose redirects grow from 20 to 2,000 per second and repeat heavily. What measurement would show whether the database is the bottleneck? A cache can absorb repeat lookups if the database starts missing the latency target. Trace a cache miss and say what changes if links become editable.

## 5. Explain your decision

Say which requirement drove your choice, what breaks first, and what evidence would make you change the design. Run the [short-link lab](url-shortener-lab.md) to see the index, cache and lost-response retry in action. Then try the [full URL shortener design](url-shortener.md), the [scorecard](../scorecard.md), and the [timed interview rehearsal](../interview-rehearsal.md).
