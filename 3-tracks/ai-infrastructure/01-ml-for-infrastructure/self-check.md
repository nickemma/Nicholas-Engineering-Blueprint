# ML for infrastructure · Self-check

1. Which columns are available when a job is admitted? When does its label become available?
2. Why can a time split still leak? What happens to a training job whose completion crosses the cutoff?
3. What does the Parquet manifest establish? What decision does the pipeline make when two rows claim the same event ID with different values?
4. What does the training set fit, what does validation choose, and what does the holdout compare?
5. Which measurement could prevent promotion even when overall MAE is better?
6. How does the prediction response identify its model? Which state changes during a rollback?
7. What assumptions make the replayed scheduling comparison fair? Which of them differ from a real queue?
8. What does the queue-depth shift prove? What evidence would show that predictive error also changed?

## From memory

Draw the flow from admission to an online estimate. Mark the data cutoff, the registry's quality decision, and the alias changed during rollback. Then run the gate and match a captured output to each mark.

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
