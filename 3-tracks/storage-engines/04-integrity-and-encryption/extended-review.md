# Integrity and encryption · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 03: Append job events before committing offsets

1. What makes a log an audit trail rather than just a history?
2. Describe how audit events reach `klog`. Why must one record never contain a line break?
3. When can an event be written to the audit log twice? How would you find out?

### Lesson 04: Check a record against a signed Merkle root

4. What does CRC-32C protect against? What would protect against deliberate tampering?
5. Why can't a checksum, or a hash chain, stop someone who can rewrite the file?
6. What does a Merkle tree's root commit to? What do inclusion and consistency proofs show?
7. What does the witness check, and why must it be run by someone else?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 03 | Why does the feed commit only after `klog` confirms, and what does that guarantee? | | |
| 03 | When can an audit line be written twice, and how would you detect it? | | |
| 04 | What does CRC-32C protect against, and what doesn't it? | | |
| 04 | Why isn't a hash chain enough, and what does a witness add? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| `klog` dies and the feed recovers with nothing lost | | |
| An edited audit log refused by the witness and flagged by `auditctl` | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
