# Self-check: Python runtime and honest measurement

## Explain it

Answer in your own words. Where you can, point at something you ran.

### 01 How Python runs your code

1. After `b = a` and `b.append(3)`, why has `a` changed? How do you make a real copy?
2. Why does a million integers in a list take about five times the memory of a Go `[]int64`?
3. When is a Python object freed? When isn't reference counting enough, and what frees it then?
4. What did the specialising interpreter change in `total`'s bytecode, and why doesn't that make Python as fast as Go?
5. Python and Go printed different totals for the same loop. Which was right, and why was the other wrong?

### 02 The GIL: threads, processes and the free-threaded build

1. Why didn't 8 threads count faster than 1, while 64 sleeping threads finished as fast as 1?
2. What does a process cost that a thread doesn't?
3. What does the free-threaded build change, and why isn't it the default yet?
4. Why did a waiting thread wake 5 ms late while another thread computed, and what would that do to a load generator's numbers?

### 03 How the event loop works

1. In `byhand.py`, what does a task hand the loop when it yields, and what does the loop do with it?
2. Where does an idle event loop wait, and why does it use no CPU while it waits?
3. What does `await` do underneath, as `await.py` showed?
4. Why does `time.sleep` inside a coroutine delay every other task, and what do you use instead?
5. Why can't a timer on this loop fire more precisely than about a millisecond?

### 04 `kload` as a package: why averages lie

1. What do the src layout and `[project.scripts]` each give you?
2. Why does `main` take `argv` and return a status instead of reading `sys.argv` and calling `sys.exit`?
3. With 99 requests at 10 ms and one at 5,000 ms, what are the mean, the p50, the p99 and the max? Which of them describe a request that happened?
4. Why does `kload` keep every raw latency instead of only a summary?

### 05 An HTTP client tested without a network

1. What does `MockTransport` replace, and why doesn't `SwitchyardClient` notice?
2. What makes `FakeSwitchyard` a fake rather than a mock?
3. Which of Switchyard's errors come as JSON, which as plain text, and why must the client read both?
4. What does the smoke test prove that the fake can't?

### 06 Load on a schedule: open and closed loops

1. What is coordinated omission? Show it with the two runs of `test_closed_loop_hides_a_stall_that_the_open_loop_reveals`.
2. Why is every latency timed from when the request was due, not when it was sent?
3. What is send lag, what does `kload` do when it's high, and why exit with status 3 rather than 1?
4. Why did starting every task at the beginning make the first requests late, and what does the dispatcher do instead?
5. Why did `kload` stop sending its load with httpx?

### 07 Three experiments on Switchyard

1. The same 1-second freeze gave an open-loop p99 hundreds of times the closed loop's. Where did the closed loop's missing time show up?
2. Why does the freeze appear as a slanted line on the latency-over-time plot?
3. In the saturation experiment, what told you Switchyard was saturated, if not the latency? Why didn't the latency rise?
4. At 4,000 requests a second `kload` warned about its CPU, and the p99 changed from run to run. How would you prove a slow tail like that was `kload`'s, not Switchyard's?

### 08 Repeat runs and confidence intervals

1. Why is a run, not a request, the unit of evidence?
2. What does a confidence interval that includes zero mean, and what doesn't it mean?
3. What does the bootstrap resample, and why with replacement?
4. Why run the builds in a random order? What did a fixed order do?
5. What is an A/A test for, and what would you conclude if it showed a difference?

## From memory

Close the lessons. Without notes:

1. Write a nearest-rank `percentile(values, p)` and parametrised tests for it, including a single value, p100, an empty list and a `p` out of range.
2. Write a small event loop by hand that runs two generator tasks, one sleeping 0.1 s three times and one 0.15 s twice, and prints when each wakes. It must finish in about 0.3 s, using one thread.
3. Write an open-loop sender for any `async` function: `rate` calls a second for `duration` seconds, each timed from when it was due, recording each call's send lag. Then write the test that shows a closed loop hides a stall that yours reveals.
4. You're told "the new build is 0.3 ms faster at p99, I ran it once." List what you'd ask for before believing it, and design the experiment that would settle it.
