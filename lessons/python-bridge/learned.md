# Python Bridge: what I learned

Fill this in as you go, with evidence: commands, outputs, test names, and plots saved in your repository.

## Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | What does `.venv` contain, and why does each project get its own? | | |
| 1 | What happens to the rest of a function after `raise`? How is that different from Go's error returns? | | |
| 1 | Type hints aren't enforced at run time. What does catch type mistakes, then? | | |
| 2 | Why is the mean misleading for latency? Use the 99 × 10 ms + 1 × 5,000 ms example | | |
| 2 | Compute a nearest-rank p95 by hand for 20 values | | |
| 2 | Why did `values.sort()` break a test that `sorted(values)` passes? | | |
| 3 | Why does `main` accept `argv`? What is `__init__.py` for? | | |
| 3 | Why are p95 and p99 equal to the maximum for five samples? | | |
| 4 | Why does `JobsClient` take an `httpx.Client` rather than a URL? | | |
| 4 | Why must `run_job` accept 504? | | |
| 5 | Explain `async`/`await` and the event loop in your own words | | |
| 5 | What is coordinated omission? Why does a closed loop hide a stall? | | |
| 5 | Why does measuring from the scheduled time fix it, and when does the wrong measurement go unnoticed? | | |
| 6 | Why are errors excluded from the latency percentiles but reported separately? | | |
| 6 | Why does latency stay high after a freeze ends? | | |
| 6 | How did you show the generator was the bottleneck at 400 requests per second? | | |

## Evidence checklist

| Claim | Command or file | Result |
|---|---|---|
| All steps' tests and lint pass | | |
| Baseline recorded, with its settings file | | |
| Open vs closed loop under the same freeze: both sets of numbers and the plot | | |
| Generator CPU at three rates | | |
| One experiment rerun from its settings file, with comparable numbers | | |

## Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- What is still unclear:
