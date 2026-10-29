# Phase 7: what I learned

Fill this in as you go, with evidence: commands and their output, test names, the failing output of each "Break it", plots, captures. Keep your filled-in copy in your own repository.

## Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | Why is a benchmark run one measurement, not 40,000? | | |
| 1 | What does an A/A experiment measure, and what did yours find? | | |
| 1 | Why did running the conditions in sequence fake a difference, and why did interleaving remove it? | | |
| 1 | What does a confidence interval say that a p-value doesn't? What is the margin for? | | |
| 1 | Why must the plan be written first? What did the peeking simulation show? | | |
| 2 | Why does a log-log plot of time against size bend flat at the small end? | | |
| 2 | Why does a job's run time depend on what else is running, and what did the CPU limit change? | | |
| 2 | Why must "unknown" stay `NULL`? What did a zero time do? | | |
| 3 | What may a writer change without a new contract version, and what may it not? | | |
| 3 | Why commit the Kafka offset after writing, and what does that make you handle? | | |
| 3 | Why partition by event time? Where did your late events land? | | |
| 3 | Why quarantine a bad event rather than drop it or stop? | | |
| 4 | Why must the partition function agree in every process, and why does Python's `hash()` not? | | |
| 4 | Which aggregates can a combiner reduce, and why can't it reduce an exact median? | | |
| 4 | What is COST, and what was it for MapReduce and Spark on your machine? | | |
| 5 | What is leakage? Which test caught it, and which test missed it? | | |
| 5 | Why split by time, and what did the random split hide? | | |
| 5 | How does MAPE reward guessing low? Which metric fits shortest job first? | | |
| 5 | Why resample whole minutes in the bootstrap? | | |
| 6 | Why must the feature pipeline be fitted inside the model? | | |
| 6 | Why did shuffled folds promise more than time-ordered ones? | | |
| 6 | When does conformal calibration hold its promise, and why didn't it here? | | |
| 6 | What does permutation importance measure, and what doesn't it? | | |
| 7 | What does the gradient check compare, and what did the broken ReLU mask do? | | |
| 7 | Why standardise inputs, and with whose statistics? | | |
| 7 | Was the network worth it over the trees? On what measure? | | |
| 8 | What did the parity test find, and why had step 5's leakage test missed it? | | |
| 8 | Which clock may a feature use? | | |
| 8 | What do the timeout, the breaker and the fallback each do? What happened with the predictor down? | | |
| 8 | Why did the trees time out under load, and what replaced them? | | |
| 9 | Why does shortest job first lower the mean wait? What does it risk? | | |
| 9 | Why aren't reserved lanes work-conserving, and what did that cost? | | |
| 9 | What was the feedback loop with the served prediction, and what fixed it? | | |
| 10 | What do the four fingerprints identify, and why all four? | | |
| 10 | Why does the gate need the interval, and what did a point estimate promote? | | |
| 10 | Why did version 1 go so wrong on the holdout? | | |
| 11 | Data drift vs concept drift: which can a check on inputs find? | | |
| 11 | Why did `history_log_run` read MAJOR with nothing wrong? | | |
| 11 | What does a model guess for a tenant it never saw? What did the shadow show? | | |
| 12 | Why inject incidents, and what does the truth file get wrong about when an incident ends? | | |
| 12 | Why can a detector that alarms all the time look good, and which column exposes it? | | |
| 12 | Why did the burn-rate alerts find none of the incidents, and why is that right? | | |
| 12 | What do the logs see that the metrics don't, and the other way round? | | |
| 12 | Why must a held-out test be predicted before its data exists? | | |
| 13 | What makes a conclusion a claim that can fail? | | |
| 13 | Why did the trees' win reverse on the final data? What should step 6 have claimed? | | |
| 13 | Why is an interval across zero "inconclusive", not "fails"? | | |

## Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| The noise floor from an A/A run, with its interval | | |
| A fake difference from sequential runs under load, gone when interleaved | | |
| A plan committed before its results | | |
| Run time against size, per kind, and the contention plot | | |
| The contract test on both sides; a breaking change refused | | |
| The pipeline killed mid-batch: rerun, duplicates removed, counts reconciled | | |
| MapReduce's combiner: pairs and bytes shuffled, with and without | | |
| The COST grid, with DuckDB's single thread marked | | |
| The leakage break, caught by the per-job as-of test | | |
| Baselines on the time split; MAPE's trap | | |
| Trees against the best baseline, paired, with the interval | | |
| A gradient check passing, and failing on the broken backward pass | | |
| The parity test at zero differences | | |
| Prediction outcomes with the predictor up, throttled and down; jobs accepted throughout | | |
| FIFO against priority against reserved: waits per class, with intervals | | |
| The gate promoting one model and refusing another | | |
| A rollback, live | | |
| The unusual-inputs alert firing for the new tenant; the shadow's comparison | | |
| The detectors' table with found, false, time to detect and time alarmed | | |
| The pre-registered prediction and the detectors' hashes | | |
| `lab report`, and every verdict that changed | | |

## Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the guide, and why:
- What is still unclear:
