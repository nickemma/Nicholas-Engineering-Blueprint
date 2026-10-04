# Python Bridge exercises

Write a failing test first for every code exercise. There are no solutions on purpose.

## 1. Run a full job workflow as the load

Add a `--target run` that creates a job and then runs it, as one "user action". Record the latency of the whole action.

**Done when:** a test with a fake API checks that both calls happen in order, and a real run at 20 actions per second reports p50/p95/p99 for the combined action.

## 2. Ramp the rate

Add `--ramp 10:200:30`: start at 10 requests per second and increase linearly to 200 over 30 seconds.

**Done when:** a unit test checks the schedule of send times, and a real run plus plot shows the rate at which latency starts to climb. Mark the "knee" on the plot.

## 3. Repeat and report the spread

Add `kload repeat --times 5 ...`, which runs the same load five times and reports the median and the range of each percentile across runs.

**Done when:** you can say "p99 was 8–14 ms across 5 runs" instead of quoting a single number. Explain why one run isn't enough.

## 4. Compare two results files

Add `kload compare a.csv b.csv`. It prints each percentile for both files and the difference, and flags differences smaller than the run-to-run spread you found in exercise 3.

**Done when:** comparing two baseline runs is flagged as "no significant difference".

## 5. Use your client in the Go service's CI

Write a pytest "contract test" that starts the Phase 1 binary on a free port (`LISTEN_ADDR=127.0.0.1:0` won't work here; pick a free port in Python first), then runs every row of the Phase 1 contract through `JobsClient`.

**Done when:** the test passes against the real binary and fails if you change a status code in the Go handler.

## 6. Stretch: a second generator process

Experiment 3 found the generator's CPU limit. Run two `kload load` processes at 200 requests per second each against the same server, and merge their results.

**Done when:** you can show that 400 requests per second split across two processes stays healthy, while one process at 400 doesn't.
