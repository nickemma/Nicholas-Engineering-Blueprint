# Core 08 · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: A container is a process

1. What is a container, to the kernel? Name three namespaces and what each changes.
2. What do cgroups do? Where can a process read its own memory limit?

### Lesson 02: Model the trust boundary

3. What is a trust boundary? Name three in Switchyard, including one the lesson 02 diagram doesn't draw.
4. Name the six STRIDE threats and the property each violates.
5. Why does each threat in the model carry a command as evidence?
6. Predict: a new route is added without asking the policy. Which test catches it, and how?

### Lesson 03: Issue certificates and require mTLS

7. What does mutual TLS prove, and what doesn't it?

### Lesson 04: Limit what the gateway can read and record

8. Why can the API seal a webhook secret but not open it?
9. What is a canary, and what did Switchyard's inventory find that nobody had written?

### Lesson 05: Define reliability from the client side

10. Define SLI, SLO, error budget and burn rate. What burn rate spends 2% of a month's budget in an hour?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | What does a PID namespace change, and what does it not? | | |
| 01 | Why did `sleep` take 10 seconds to stop, and the API half a second? | | |
| 01 | Why did `127.0.0.1` work on your laptop and fail in a container? | | |
| 02 | Why must identity come before authorization, tenants and rate limits? | | |
| 02 | Pick three threats: which property does each violate, and what would an attacker do? | | |
| 03 | What does mutual TLS prove that a token doesn't, and the other way round? | | |
| 05 | SLI, SLO, error budget, burn rate: define each with Switchyard's numbers | | |
| 05 | Why two windows per alert, and why was the page still firing after recovery? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A PID 1 that ignores `SIGTERM` takes 10 s to stop; the API takes under 1 s | | |
| A forged Raft vote demoting the leader, then refused | | |
| The canary inventory, before and after | | |
| The game day: held, open, and the controls | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
