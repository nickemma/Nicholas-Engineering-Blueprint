# AI infrastructure deep dives · Extended review

Questions on the optional deep dives. Answer from memory, then check yourself against the page.

## [MapReduce, Spark and the single-machine baseline](mapreduce-spark-and-cost.md)

1. Walk through map, shuffle and reduce for "median run time per kind". Where does the data cross the network?
2. Predict: the partitioner uses Python's `hash()`. What do the tests say, and what does a real run say? Why?
3. What is COST? When can one thread beat a cluster, and why?

## [Verify backpropagation by hand](backpropagation.md)

4. What does a gradient check compare? Predict: the ReLU's mask is dropped from the backward pass. Does training crash?

## [Find unusual incidents in operational signals](aiops.md)

5. Define recall, precision, time to detect and false alarms per hour. Why add the share of quiet time alarmed?
6. Why is an isolation forest's score compressed, and what did that mean for its limit?
7. Why must the held-out quiet hour's prediction come before its data? What does the report say about it, and why?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Deep dive | Question | My answer | Evidence |
|---|---|---|---|
| MapReduce, Spark and the single-machine baseline | Why must the partition function agree in every process, and why does Python's `hash()` not? | | |
| MapReduce, Spark and the single-machine baseline | What is COST, and what was it for MapReduce and Spark on your machine? | | |
| Verify backpropagation by hand | What does the gradient check compare, and what did the broken ReLU mask do? | | |
| Find unusual incidents in operational signals | Why can a detector that alarms all the time look good, and which column exposes it? | | |
| Find unusual incidents in operational signals | What do the logs see that the metrics don't, and the other way round? | | |
| Find unusual incidents in operational signals | Why must a held-out test be predicted before its data exists? | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| The COST grid: one thread against the cluster | | |
| Trees against the best baseline, paired, with the interval | | |
| A gradient check passing, and failing on the broken backward pass | | |
| The detectors' table with found, false, time to detect and time alarmed | | |
