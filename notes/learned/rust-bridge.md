# Rust Bridge self-test

Answer from memory, then check yourself against [the lesson](../../lessons/rust-bridge/TEACHING.md). Write each "predict" answer before running anything.

## A. Basics

1. What does `let x = 5; x = 6;` produce, and why is that the default?
2. What's the difference between `[u64; 5]`, `&[u64]` and `Vec<u64>`?
3. Why does Rust have `Option` instead of null? What does `match` force you to do with it?
4. What is a macro, and why is `println!` one?

## B. Ownership

5. State the three ownership rules.
6. Predict: `let a = String::from("x"); let b = a; println!("{a}");`. Which error, and what bug does it prevent?
7. Predict: `let n: u64 = 5; let m = n; println!("{n}");`. Does it compile? Why is it different?
8. What may exist at the same time: shared borrows, a mutable borrow, or both? Why does that rule out data races?
9. What does lifetime elision infer for `fn longest_word(text: &str) -> Option<&str>`?
10. Why can't a function return a reference to its own local `String`?

## C. Errors

11. What does `?` expand to, roughly?
12. Why is an `enum` with data a richer error than Go's sentinel errors?
13. What does `impl From<io::Error> for LogError` let you write?
14. Predict the output of `cargo run -- 2h` for the Step 3 program, and explain the format.

## D. Bytes and formats

15. Draw the record format byte by byte. Decode `0d 00 00 00`.
16. What's little-endian? Why must a file format specify it?
17. What does a CRC detect? Give two things it doesn't protect against.
18. What is a known-answer test, and why did it catch a bug the round-trip tests missed?
19. Why must `decode` check the length against a maximum before using it?
20. What does "zero-copy decoding" mean here, and what guarantees it's safe?

## E. Files and crashes

21. What is the page cache? When does a write survive a power cut?
22. Predict: you delete `sync_data()` from `append`. Do the tests fail? What would?
23. Define a torn write. Why can only the last record of an append-only file be torn?
24. Walk through what `klog check` does on a file whose last 5 bytes were chopped off.
25. Why does `klog` refuse to open after damage in the first record of two?
26. What two situations does klog's recovery fail to distinguish? How do real systems deal with that?

## F. Threads

27. Define `Send` and `Sync`. Why isn't `Rc` `Send`?
28. What does `move` do in `thread::spawn(move || ...)`, and why is it needed?
29. How does the appender guarantee one writer without a lock around the file?
30. Explain the deadlock from Step 6. Why can't the compiler catch it?

## G. Explain it whole

31. Compare how Go and Rust would each let you down if two goroutines or threads appended to one file without coordination.
32. Rebuild `klog` from the format description and your notes. Which parts did you have to look up?
