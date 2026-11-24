# Self-check · C for Rust programmers

| Lesson | Explain from memory |
|---|---|
| 01 | What is compiled into each object? Which phase resolves a declared symbol to a definition? Which targets must rebuild after a shared header changes? |
| 02 | Why check the count against the remaining length instead of adding it to a start offset? What operations may use a one-past pointer? |
| 03 | Who owns the allocation before and after failed growth? When do the pointer, capacity, and logical length change? |
| 04 | What does a poisoned one-past address tell you? Why does UBSan report fixed signed addition at the integer limit? |
| 05 | Why return a slice tied to the shared borrow of the owner? Where is the matching free function called? |
| 06 | How does the C header describe the ABI? What pointer obligations still belong to the caller after a null check? |
| 07 | Why use shared input files and separately known outcomes? Which file identifies the zero-byte regression? |

## Rebuild the boundary from memory

Write the function signatures for constructor, append, view, and free. Sketch Rust methods that bind the owner's lifetime to the returned view. Then reverse the direction and write the C declaration for a Rust function that borrows a pointer and length and returns a digest through an output pointer.

For each signature, name the owner, initialized span, invalidation event, and behavior on failure. Check the result against the [C wrapper lesson](lessons/05-call-the-c-library-from-rust.md) and the [Rust export lesson](lessons/06-call-a-rust-library-from-c.md).
