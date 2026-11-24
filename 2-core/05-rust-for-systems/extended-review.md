# Core 05 · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 04: Move work to a single owner

1. Define `Send` and `Sync`. Why isn't `Rc` `Send`?
2. What does `move` do in `thread::spawn(move || ...)`, and why is it needed?
3. How does the appender guarantee one writer without a lock around the file?
4. Explain the deadlock from lesson 04's break-it

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 04 | Define `Send` and `Sync`. Why does `Mutex<T>` contain its data? | | |
| 04 | Explain the deadlock from lesson 04's break-it | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| 100 records from 4 threads, all intact | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
