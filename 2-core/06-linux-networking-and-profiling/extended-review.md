# Core 06 · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: A slow service, and the USE method

1. Explain the USE method, and apply it to Switchyard's workers and its database pool.

### Lesson 10: Watch TCP on a lossy link

2. Describe the three packets of a TCP handshake.
3. Why is HTTP/1.1 readable in `tcpdump` but gRPC isn't?
4. What's an ephemeral port?

### Lesson 13: Trace and profile the wire

5. Define a trace and a span. What does a `traceparent` header contain?
6. Gateway collector or sidecar: what does each cost and buy?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | Name the U, the S and the E for Switchyard's workers | | |
| 10 | Describe a handshake you captured, packet by packet | | |
| 10 | Did your SYN capture explain the seven-second tail Core 02 left open? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| `tcpdump` shows the handshake and the HTTP request | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
