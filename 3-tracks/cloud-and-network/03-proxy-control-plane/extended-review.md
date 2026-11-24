# The proxy's control plane · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 05: Deliver signed events to registered destinations

1. What does a webhook signature cover, and what attack does each part stop?
2. Why does a duplicate get `200`? Why is an ID remembered only after the work succeeds?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 05 | What does each signed part of a webhook (ID, timestamp, body) protect against? | | |
| 06 | How does a service prove who it is to OpenBao? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A replayed webhook, a changed body, a stale timestamp: each refused | | |
| Management certificates rotated with no errors | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
