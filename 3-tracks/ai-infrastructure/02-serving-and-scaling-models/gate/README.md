# Gate: Serving and scaling models

## What it checks

The gate runs on your lab directory, the one holding `serve/` and `gateway/`. It takes about 20 seconds once the Python environment is installed.

1. `serve` is formatted and lint-clean, and every test passes: the tiny transformer, streaming, batching, scoring, pod timings, the readiness probe and recovery.
2. `gateway` is `gofmt`-clean, passes `go vet`, and passes its tests under the race detector.
3. Two processes train with DDP and report parity with the serial reference.
4. Negative controls. In a disposable copy, the gate removes one guarantee at a time, and the named test must fail:
   - the causal mask, so a token can see the future: `test_a_token_cannot_see_the_future`;
   - the check for `[DONE]`, so a truncated stream counts as a success: `test_usage_is_not_chunk_count_and_truncated_stream_is_failure`;
   - failed requests in the denominator: `test_failures_stay_in_denominator_and_unknown_tokens_cannot_pass`;
   - the release of an admission slot: `TestDisconnectCancelsUpstreamAndReleasesSlot`.

A guarantee that no test notices is one the next refactor can delete. The negative controls change the lines the lessons wrote. If you changed one of those lines, the gate stops and names it: rename it back, or adapt the control.

The gate doesn't run the live experiments: the real model, Kubernetes, signing, the shaped link, Ray and the GPU. Their results are in the lessons and in [evidence/](../evidence/README.md).

## Run it

From the Blueprint checkout, rebuild the lessons; lesson 14 runs the gate on the result:

~~~bash
python3 scripts/replay_lessons.py 3-tracks/ai-infrastructure/02-serving-and-scaling-models
~~~

On your own lab directory:

~~~bash
bash "$blueprint/3-tracks/ai-infrastructure/02-serving-and-scaling-models/gate/run.sh" ~/path/to/your/lab
~~~

It needs `uv`, Go and Bash, and runs offline once `uv sync` has installed CPU PyTorch.

## A pass looks like

~~~text
$ bash gate/run.sh .
== serve: format, lint, tests
26 files already formatted
All checks passed!
..............                                                           [100%]
14 passed in 2.18s
== gateway: format, vet, race tests
ok  	inferencegateway/internal/inference	1.199s
== data parallelism: two processes match the serial reference
{"world": 2, "seconds": 0.0081769069947768, "serial_parity": true}
negative control: attention sees the future -> caught by test_a_token_cannot_see_the_future
negative control: a truncated stream counts as success -> caught by test_usage_is_not_chunk_count_and_truncated_stream_is_failure
negative control: failed requests leave the denominator -> caught by test_failures_stay_in_denominator_and_unknown_tokens_cannot_pass
negative control: a finished request keeps its slot -> caught by TestDisconnectCancelsUpstreamAndReleasesSlot
gate passed
[exit 0]
~~~

## A fail looks like

A gateway that never gives back its admission slot fails in its own tests: the next request waits, times out, and the capacity check reports the leak.

~~~text
$ bash gate/run.sh .
== serve: format, lint, tests
26 files already formatted
All checks passed!
..............                                                           [100%]
14 passed in 2.12s
== gateway: format, vet, race tests
--- FAIL: TestAuthAndTokenReservations (30.01s)
    gateway_test.go:40: 504
--- FAIL: TestDisconnectCancelsUpstreamAndReleasesSlot (0.00s)
    gateway_test.go:76: capacity leaked
panic: test timed out after 1m0s
...
~~~

A test weakened until it no longer checks for a truncated stream passes on its own. The negative control catches it:

~~~text
$ bash gate/run.sh .
== serve: format, lint, tests
26 files already formatted
All checks passed!
..............                                                           [100%]
14 passed in 1.82s
== gateway: format, vet, race tests
ok  	inferencegateway/internal/inference	1.196s
== data parallelism: two processes match the serial reference
{"world": 2, "seconds": 0.008317335013998672, "serial_parity": true}
negative control: attention sees the future -> caught by test_a_token_cannot_see_the_future
.                                                                        [100%]
1 passed in 0.52s
negative control 'a truncated stream counts as success' was not caught by test_usage_is_not_chunk_count_and_truncated_stream_is_failure
[exit 1]
~~~

The gate was checked both ways: it passes on the reference build and fails on both of these deliberately broken ones. The full runs are in [evidence/gate](../evidence/gate/).
