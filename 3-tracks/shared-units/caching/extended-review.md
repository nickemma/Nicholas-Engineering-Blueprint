# Caching · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: Keep job status in PostgreSQL

1. Draw the race that can still cache a stale value. What bounds how stale it gets?
2. Why can a finished job be cached for an hour, but a running job only for seconds?
3. Why does the cache key contain `v1`?

### Lesson 02: Add cache-aside reads and invalidation

4. Describe cache-aside reads and writes. Why delete on write instead of updating?

### Lesson 03: Collapse concurrent misses with singleflight

5. What is a stampede? Predict: 100 concurrent misses on one key, with and without singleflight. How many database reads?

### Lesson 04: Measure expiry and Redis failure

6. What does "fail open" mean for a cache? Why does each Redis call need its own short timeout?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | Why does a write delete the cached copy instead of updating it? | | |
| 01 | Draw the race that still lets a stale value in, and say what bounds it | | |
| 01 | Why must a cache fail open, and what makes it fail fast? | | |
| 03 | What is a stampede, and how does singleflight stop it? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| The cache serves hits, survives Redis being stopped, and recovers | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
