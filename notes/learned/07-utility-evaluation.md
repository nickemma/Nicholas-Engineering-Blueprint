# Phase 7 self-test

Answer from memory, then check yourself against [the lesson](../../lessons/07-utility-evaluation/TEACHING.md). Write each "predict" answer before running anything.

## A. Experiments

1. What is the experimental unit in a benchmark, and why does treating its 40,000 round trips as samples mislead?
2. What does an A/A experiment tell you before you look for any effect?
3. Predict: you run all of A, then all of B, while another program warms the machine up. What does the comparison say, and what does interleaving change?
4. What does a percentile bootstrap do? Why is a ratio of medians a sensible statistic for run times?
5. What question does a permutation test's p-value answer, and what question doesn't it?
6. Name the four outcomes of a comparison against a margin. Which one was the TLS overhead, and why wasn't it re-run until it said something else?
7. Why does testing many comparisons, or peeking after every run, find effects that aren't there? Roughly how often, in the simulations?

## B. Real work and real data

8. What do fixed and proportional costs look like on a log-log plot? Which kind had the largest fixed cost?
9. How does a CPU limit make a job's run time depend on other jobs? What changed when the limits changed?
10. Event time vs processing time: which do durations use, and why?
11. What may change in a data contract without a new version? Give one change that needs one.
12. Why commit Kafka offsets after the write? What does that oblige every reader to do?
13. Predict: Kafka goes down for a minute while jobs keep running. What happens to the outbox, the jobs and the pipeline, and what's in the Parquet files afterwards?
14. Why partition by event hour, and what's a late event's journey through the pipeline?

## C. Big data

15. Walk through map, shuffle and reduce for "median run time per kind". Where does the data cross the network?
16. Predict: the partitioner uses Python's `hash()`. What do the tests say, and what does a real run say? Why?
17. Which aggregates are algebraic, which holistic? What did the approximate median cost and save?
18. What is speculative execution, and what must be true of a task's output for it to be safe?
19. What is COST? Why was DuckDB on one thread faster than MapReduce and Spark at every width here?

## D. Datasets, baselines and models

20. Define point-in-time correctness. How does the per-job as-of test check it?
21. Why keep only jobs old enough that all of them have finished, rather than the ones that have?
22. Why does a random split flatter a model? What did it hide in step 5?
23. Name four error metrics and what each is dominated by. Which suits shortest job first?
24. Predict: you halve every prediction of the per-kind median. What happens to MAPE and to log error?
25. What is a paired block bootstrap, and why did per-job resampling give an interval four times too narrow?
26. How do gradient-boosted trees differ from the power law in what they can represent?
27. Why tune with time-ordered folds? What did tuning gain over the defaults?
28. What does conformal calibration promise, under what assumption, and what did it do on the test split?
29. What does a gradient check compare? Predict: the ReLU's mask is dropped from the backward pass. Does training crash?
30. Why did the network's prediction cost a fraction of the trees', and why did that decide step 8?

## E. Serving and using predictions

31. What's a parity test? What leak did it find that step 5's test missed, and why?
32. Which clock may a feature use, and why did the API stamping `created_at` before predicting matter?
33. What do the timeout, the breaker and the fallback each protect? Predict: the predictor is deleted. What happens to `POST /jobs`?
34. Why did the trees time out on a busy machine when they answered in 8 ms in a quiet one?
35. Why does shortest job first lower the mean wait? Why did strict priority not starve long jobs here, and when would it?
36. Why are reserved lanes not work-conserving? What did the experiment show, and what couldn't it show?
37. What was the feedback loop in step 9's first experiment, and why did predicting the job's time alone fix it?

## F. MLOps and drift

38. What does each of the four fingerprints identify? How did you prove training is reproducible?
39. What are aliases for? Describe a promotion and a rollback.
40. Why must the gate compare champion and challenger on jobs neither trained on, job by job, with an interval? What would a point estimate have promoted?
41. Why was version 1 off by a factor of four on the holdout? What in the model card would have warned you?
42. Data, concept, prediction and label drift: give an example of each from Runway.
43. How is PSI computed, and what are the conventional limits? Why did `history_log_run` read MAJOR with nothing wrong?
44. Why is the alert built on unusual inputs and not on PSI?
45. What does a shadow deployment show that the gate doesn't?

## G. AIOps and the report

46. Why inject incidents? What does the truth file get wrong about when an incident ends?
47. Define recall, precision, time to detect and false alarms per hour. Why add the share of quiet time alarmed?
48. Why do MAD and the median resist the warm-up's spikes? Why did EWMA need `clip`?
49. Why do signals that were zero through the warm-up need a minimum change, and who should choose it?
50. Why is an isolation forest's score compressed, and what did that mean for its limit?
51. Predict: three slow minutes push the API's p50 to seven times its objective. Do the burn-rate alerts page? Why?
52. What did Drain's new templates show about which incidents logs can find?
53. Why must the held-out quiet hour's prediction come before its data? What does the report say about it, and why?
54. What makes a conclusion a claim that can fail? Give step 6's claim as it should have been written.
55. Why is an interval across zero "inconclusive" rather than "fails"? Which of the report's first verdicts got this wrong?
56. What do the inputs' fingerprints let a reader of the report do?
