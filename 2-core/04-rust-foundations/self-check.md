# Self-check · Rust foundations

Answer in your own words and refer to compiler diagnostics, tests, or byte dumps from your work.

## Explain it

### 01 A first Rust program

1. What does Cargo build from `src/main.rs`? How does it decide whether to compile the tests?
2. What does an `Option<f64>` force a caller to consider before printing a mean?

### 02 Ownership, moves, and borrows

1. Draw an owned string and a borrowed slice into it. Which value owns the allocation after moving the string?
2. Why did the compiler refuse to grow the vector while the slice was still in use?

### 03 Enums, patterns, and errors

1. Why can `ParseError::BadNumber` carry the original input? What changes when you print with `Display`?
2. Trace the first `?` that returns from a bad duration. How does the parser handle overflow?

### 04 Traits, generics, and collections

1. What operation does `T: Measurement` promise is available?
2. Which iterator adapters borrow and which operation builds a new collection? Why does the histogram print in a predictable order?

### 05 Lifetimes and shared ownership

1. Which lifetime can `longer` promise when its inputs are borrowed from two different scopes?
2. What changes when you clone an `Rc` and drop either handle? Why does the recursive enum use a `Box`?

### 06 Bytes, framing, and checksums

1. Draw the header, byte order, and checksum coverage. What can the reader trust before the header check succeeds?
2. How did the test show that decoding returns a borrowed payload? Why does the reader cap lengths independently of the checksum?

### 07 Append a record and sync it

1. Trace the bytes from a caller's slice to the file. What has happened once `write_all` returns, and what additional operation is needed before acknowledgment?
2. What does synchronizing the parent directory cover? Why does the tool refuse a second writer?

### 08 Recover a torn tail and refuse corruption

1. Why does a short final frame permit truncation but a complete frame with a bad checksum halt recovery?
2. What does `cat` do on a torn suffix? Which commands can repair it?
3. Which two different events could result in the same short suffix? What extra state would distinguish them?

### 09 Measure syncs and prove recovery

1. Which operations did both benchmark cases share, and which count changed?
2. Which bytes were incomplete when the gate killed the writer? How did the gate make the interruption reproducible?
3. Where would an implementation with grouped syncs put its acknowledgment boundary?

## From memory

1. Write a function that borrows the first word from a string and a rejected example that tries to return a borrow into a local allocation.
2. Design an error enum for a two-unit parser. Write a checked conversion and tests for malformed and overflowing input.
3. Sketch a streaming frame decoder. Write out the check order so a damaged length cannot trigger allocation or recovery.
4. Define a recovery test for each of these files: a valid file, a file with a short last frame, and a file with a checksum failure in its last complete frame. Specify the exact byte changes you expect.

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
