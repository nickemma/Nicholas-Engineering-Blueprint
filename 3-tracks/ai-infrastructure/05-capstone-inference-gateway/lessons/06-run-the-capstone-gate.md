# 06 Run the capstone gate

> Inference gateway capstone · Week 2

## The problem

A faster implementation can drop accounting, masking failures in a misleading throughput number. The acceptance gate needs to test the behavior of both builds as well as the measurement client.

## Check it

~~~bash
SWITCHYARD_CAPSTONE_LIVE=1 bash "$blueprint/3-tracks/ai-infrastructure/05-capstone-inference-gateway/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/ai-infrastructure/05-capstone-inference-gateway/gate/run.sh" "$PWD" -->

The socket gate checks the fixed model profile, quota, cancellation, and terminal outcomes for both decoders. The benchmark test supplies an unfinished stream and verifies that it produces no completed throughput. The [independent exercises](../exercises.md) use the same gate design with a changed operating point.

## If it goes wrong

| Symptom | Check |
|---|---|
| The SDK refuses the model | Check the alias exposed by the model server and by discovery. |
| Throughput counts a truncated response | Require a terminal marker as well as usage. |
| A profile is empty | Verify the profiler is enabled and the input runs long enough to collect samples. |
| The whole-request timings barely change | Compare the parser profile with the model matrix. Check whether the model dominates this workload. |
