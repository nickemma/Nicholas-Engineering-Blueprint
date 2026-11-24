# Core 04 · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: A first Rust program

1. What does `let x = 5; x = 6;` produce, and why is that the default?
2. What's the difference between `[u64; 5]`, `&[u64]` and `Vec<u64>`?
3. Why does Rust have `Option` instead of null? What does `match` force you to do with it?
4. What is a macro, and why is `println!` one?

### Lesson 02: Ownership, moves, and borrows

5. State the three ownership rules.
6. Predict: `let a = String::from("x"); let b = a; println!("{a}");`. Which error, and what bug does it prevent?
7. Predict: `let n: u64 = 5; let m = n; println!("{n}");`. Does it compile? Why is it different?
8. What may exist at the same time: shared borrows, a mutable borrow, or both? Why does that rule out data races?
9. Why can't a function return a reference to its own local `String`?

### Lesson 03: Enums, patterns, and errors

10. What does `?` expand to, roughly?
11. Why is an `enum` with data a richer error than Go's sentinel errors?
12. What does `impl From<io::Error> for LogError` let you write?
13. Predict the output of `cargo run -- 2h` for the Lesson 03 program, and explain the format.

### Lesson 05: Lifetimes and shared ownership

14. What does lifetime elision infer for `fn longest_word(text: &str) -> Option<&str>`?

### Lesson 06: Bytes, framing, and checksums

15. Draw the record format byte by byte. Decode `0d 00 00 00`.
16. What's little-endian? Why must a file format specify it?
17. What does a CRC detect? Give two things it doesn't protect against.
18. What is a known-answer test (the CRC's check value), and why can it catch a bug that round-trip tests miss?
19. Why must `decode` check the length against a maximum before using it?
20. What does "zero-copy decoding" mean here, and what guarantees it's safe?

### Lesson 07: Append a record and sync it

21. What is the page cache? When does a write survive a power cut?
22. Predict: you delete the sync call from `append`. Do the tests fail? What would?

### Lesson 08: Recover a torn tail and refuse corruption

23. Define a torn write. Why can only the last record of an append-only file be torn?
24. Walk through what `klog check` does on a file whose last 5 bytes were chopped off.
25. Why does `klog` refuse to open after damage in the first record of two?
26. What two situations does klog's recovery fail to distinguish? How do real systems deal with that?

### The whole module

27. Compare how Go and Rust would each let you down if two goroutines or threads appended to one file without coordination.
28. Rebuild `klog` from the format description and your notes. Which parts did you have to look up?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | Why is immutability the default? What does returning `Option` force the caller to do? | | |
| 02 | State the three ownership rules. Explain move, `&` and `&mut` with an example of each | | |
| 02 | Why does "many readers or one writer" rule out data races? | | |
| 02 | Why does `join` take `Vec<String>` but `longest_word` take `&str`? | | |
| 03 | What does `?` do, exactly? Why use `checked_mul`? | | |
| 03 | `Debug` vs `Display`: who is each for? | | |
| 06 | Why a length prefix? Why say little-endian explicitly? | | |
| 06 | What can a CRC detect, and what can't it? Why did only the known-answer test catch the wrong polynomial? | | |
| 07 | Why can only the last record be torn? What can klog's recovery *not* tell apart? | | |
| 08 | Why refuse to open after mid-file corruption? | | |
| 09 | When is a write durable? What does `fsync` cost? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| The five compiler errors produced and understood | | |
| The CRC-32C known answer matches | | |
| A hex dump decoded by hand | | |
| A torn write recovered | | |
| Mid-file corruption refused | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
