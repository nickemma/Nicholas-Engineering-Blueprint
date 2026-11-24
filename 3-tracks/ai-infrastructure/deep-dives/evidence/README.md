# Historical measurement captures

These plots were captured for the earlier utility and evaluation guide. The optional lab guides describe how to design a new comparison. The old plots record their own workload and do not establish a result for the new fixture.

- [MapReduce and Spark crossover](s04-cost.png)
- [Baseline comparison](s05-baselines.png)
- [Resource limit scenario](s02-new-limits.png)
- [TLS overhead experiment](s01-tls-overhead.png)
- [Repeated baseline comparison](s01-aa-first.png) and [sequential run control](s01-aa-sequential.png)

## Replacement checks

- Spark's one- and two-worker modes returned the same tenant aggregates as the Python streaming baseline on 10,001 synthetic rows. The first Spark run took 29.647 s and the second took 4.715 s in the same Python process. The second could reuse the JVM, so the two times do not establish a worker-count speedup. The streaming run took 0.002 s.
- The boosted model selected 15 leaves on the validation split. Its held-out mean absolute error was 2.86 versus 26.15 for the median baseline on the seeded duration fixture.
- The isolation forest detected the injected incident at its first window and flagged three quiet windows. The fixed error rule missed the incident and flagged no quiet windows. This is a synthetic alerting comparison.
- The CPU PyTorch comparison matched the batch loss and all four NumPy parameter gradients on the same inputs and weights.
