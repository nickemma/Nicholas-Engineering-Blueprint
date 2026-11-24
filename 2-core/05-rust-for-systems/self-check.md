# Self-check · Rust for systems

Use a source line, a diagnostic, or a test result to support each answer.

## Explain it

### 01 Memory layout

1. Where did the target place padding? What does `repr(C)` tell you about the offsets?
2. What problems can arise when a network buffer is treated as a reference to a Rust struct?

### 02 Borrowed frames

1. What does the cursor return for a short frame and for a corrupt frame? How does it change its position in each case?
2. Which test shows that the payload points into the original buffer?

### 03 C interop

1. Write down the pointer and length obligations on both sides of the wrapper.
2. Why can an empty slice be passed to this C function?

### 04 Single ownership

1. What happens to the producer when the channel fills? What causes the writer loop to exit?
2. Why did moving the `Rc` into the thread fail to compile?

### 05 Atomics

1. Draw the happens-before relationship when the ready flag is observed.
2. What outcome did Loom find after you weakened the flag to Relaxed?

### 06 The ring

1. Who owns each initialized slot? Trace a value from a successful push to its pop.
2. Why does the consumer publish its read index after taking the value?
3. How does the mask interact with wrapped counters? Who drops unread values?

### 07 Verification

1. Which part of the ring source is shared between the normal and Loom builds?
2. What do Miri, TSan, ASan, and the fuzz target actually exercise here?
3. Why seed the fuzz corpus with a valid frame?

### 08 Polling a future

1. Trace the task from Pending through the wake to Ready.
2. How does the executor handle a wake that arrives before it parks?

### 09 Tokio and pinning

1. What does an awaited send do when the one-slot channel is full?
2. Which address did the pinning demonstration preserve?

### 10 Python interop

1. Which object owns the input bytes throughout the Rust call?
2. Where does the wrapper allocate or copy, and how does a checksum error cross the boundary?

## From memory

1. Write a cursor that consumes a frame only after validation. Draw its lifetime relationship to the input.
2. Sketch a capacity-one SPSC ring. Annotate publication and reuse with their acquire and release edges.
3. Write the safety contract for a read-only C wrapper around a Rust slice, including the empty slice case.
4. Design one deterministic test and one model or fuzz test for a broken ownership hand-off.
