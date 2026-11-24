# Optional AI infrastructure deep dives

Use these after [ML for infrastructure](../01-ml-for-infrastructure/README.md). Choose the exercise that answers a question about your system.

| Guide | What you decide |
|---|---|
| [MapReduce, Spark and the single-machine baseline](mapreduce-spark-and-cost.md) | When the parallel system pays for its startup, shuffle, and coordination |
| [Gradient-boosted trees](gradient-boosted-trees.md) | When better validation accuracy justifies additional inference cost |
| [Backpropagation by hand](backpropagation.md) | Whether an implemented gradient matches the numerical derivative |
| [Anomaly detection for operations](aiops.md) | Whether a detector improves alerting at an acceptable false-alarm rate |

## Rust service build

- [Build a Rust job-status service](rust-as-a-service.md). Use REST, gRPC and WebSockets over shared state, then verify a containerized deployment with PostgreSQL.

