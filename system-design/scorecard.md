# System-design scorecard

Score each practice session straight after the timer, **before** reading any reference answer. Be strict: a 3 means you'd be comfortable with an interviewer reading your notes.

## The four dimensions

| Score | Problem navigation | Solution design | Technical excellence | Communication and collaboration |
|---|---|---|---|---|
| **1** | Started drawing straight away; requirements were vague or missing | A generic diagram; components with no reason to exist | Buzzwords; no numbers; no failure handling | Silent stretches or a monologue; ignored hints |
| **2** | Listed requirements but never named the hard part | Reasonable design, but the crux was hand-waved | Some trade-offs, mostly shallow | Clear, but never checked in |
| **3** | Numbered requirements with numbers; named the crux by minute 10 | The crux got a concrete mechanism; each component traced to a requirement | Numbers drove at least two decisions; main failure modes covered | Stated the plan, checked in at milestones, used hints |
| **4** | Also prioritised requirements and turned down scope with a reason | Also compared two real mechanisms for the crux and chose with evidence | Also explained what breaks at 10× and how you'd detect it | Also led the discussion and adapted when challenged |

## Red flags (−1 each, on the matching dimension)

- [ ] Spent more than 5 minutes on users, auth or CRUD tables.
- [ ] Never said "the hard part is..." out loud.
- [ ] No numbers before choosing a database, cache or queue.
- [ ] Added a component (Kafka, Redis, Kubernetes) without saying what requirement it serves.
- [ ] Said "it's eventually consistent" without saying what a user would see.
- [ ] Didn't mention what happens when a node, region or dependency fails.
- [ ] Ran out of time before any deep dive.
- [ ] Went 5+ minutes without checking in with the interviewer.

## Session log

| Date | Design | Track | Nav | Design | Tech | Comms | Biggest fix for next time |
|---|---|---|---|---|---|---|---|
| | | | | | | | |
