# 07 Run the streaming gate

> A Rust inference gateway · Week 3

## The problem

A gateway can look correct when requests finish quickly, even if UTF-8 framing is wrong or cancellation leaks capacity. Run the same checks after an intentional parser change to prove the test observes the contract.

## Check it

~~~bash
SWITCHYARD_GATEWAY_LIVE=1 bash "$blueprint/3-tracks/ai-infrastructure/03-rust-inference-gateway/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/ai-infrastructure/03-rust-inference-gateway/gate/run.sh" "$PWD" -->

The gate starts a fixture for the executable and verifies the selected profile from templating through the terminal event. The negative control joins two data lines with a space in an isolated copy and has to fail the multiline framing test. The original learner directory stays usable.

Record whether completion, quota refusal, admission refusal, stream timeout, or disconnect occurred. Inspect the [gate capture](../evidence/README.md) and then repeat the exercise with a new stream shape.

## If it goes wrong

| Symptom | Check |
|---|---|
| The first role frame increments first content | Check the nonempty delta-content condition. |
| A disconnect leaves the slot active | Check which object owns the permit and upstream body after headers return. |
| A stream ends without a terminal marker | Inspect the terminal SSE event and the fixture's content and usage frames. |
| An exhausted tenant gets a different tenant's budget | Confirm the key is chosen by the configured credential and each bucket is independent. |
