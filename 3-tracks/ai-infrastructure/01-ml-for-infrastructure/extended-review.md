# ML for infrastructure · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: Capture admission and completion

1. What may change in a data contract without a new version? Give one change that needs one.
2. Why partition by event hour, and what's a late event's journey through the pipeline?

### Lesson 02: Build private Parquet snapshots

3. Why commit Kafka offsets after the write? What does that oblige every reader to do?
4. Predict: Kafka goes down for a minute while jobs keep running. What happens to the outbox, the jobs and the pipeline, and what's in the Parquet files afterwards?

### Lesson 03: Split by time and plan the comparison

5. Why keep only jobs old enough that all of them have finished, rather than the ones that have?
6. Why does a random split flatter a model? What did it hide in lesson 03?

### Lesson 05: Promote versioned artifacts

7. What are aliases for? Describe a promotion and a rollback.

### Lesson 07: Test scheduling utility and input drift

8. Why does shortest job first lower the mean wait? Why did strict priority not starve long jobs here, and when would it?

### Lesson 09: Run the lifecycle gate

9. Why must the gate compare champion and challenger on jobs neither trained on, job by job, with an interval? What would a point estimate have promoted?
10. What do the inputs' fingerprints let a reader of the report do?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | What may a writer change without a new contract version, and what may it not? | | |
| 01 | Why partition by event time? Where did your late events land? | | |
| 02 | Why commit the Kafka offset after writing, and what does that make you handle? | | |
| 02 | Why quarantine a bad event rather than drop it or stop? | | |
| 03 | What is leakage? Which test caught it, and which test missed it? | | |
| 03 | Why split by time, and what did the random split hide? | | |
| 04 | Why standardise inputs, and with whose statistics? | | |
| 05 | What do the four fingerprints identify, and why all four? | | |
| 05 | Why did version 1 go so wrong on the holdout? | | |
| 07 | Why does shortest job first lower the mean wait? What does it risk? | | |
| 07 | What was the feedback loop with the served prediction, and what fixed it? | | |
| 07 | Data drift vs concept drift: which can a check on inputs find? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| The contract test on both sides; a breaking change refused | | |
| The gate promoting one model version and refusing a weaker one | | |
| A rollback, live | | |
| `lab report`, and every verdict that changed | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
