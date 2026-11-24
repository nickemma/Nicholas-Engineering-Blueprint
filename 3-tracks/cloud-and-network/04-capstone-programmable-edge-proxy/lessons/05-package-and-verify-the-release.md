# 05 Run the gate and package the release

> Programmable edge proxy capstone · Week 2 · Builds on lesson 04

## The problem

A reviewer should be able to reproduce the behavior and measurements without manually assembling the lessons.

## The mental model

The portable gate exercises the real management path, the held-request invariant, and a paced reload. The negative control creates a disposable binary that fails a request if its route changes before the response leaves the proxy.

## The pattern

Run the gate, archive the standalone inputs and captured evidence, and rebuild the extracted project in an empty directory. Include the design record with the measured limits and the restart procedure.

## Build it

### Step 1 — Prove the gate sees the failure

Run the reference and disposable control. Require the control to fail because the held request gets HTTP 503 during a route change.

### Step 2 — Verify the archive

Export the locked source, runnable gate, benchmark and profile commands, capture directory, and decision record. Extract into a fresh directory and run its portable gate.

## Check it

~~~bash
module="$BLUEPRINT_ROOT/3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy"
bash "$module/gate/run.sh" "$PWD"
release=$(mktemp -d)
bash "$module/gate/export.sh" "$PWD" "$release/switchyard-edge-capstone.tar.gz"
tar -xzf "$release/switchyard-edge-capstone.tar.gz" -C "$release"
cd "$release/switchyard-edge-capstone"
bash gate/run.sh "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/gate/run.sh" "$PWD" -->

The reference gate caught an interrupted held request. The clean export passed its own gate. [Gate and export instructions](../gate/README.md) · [Exercises](../exercises.md) · [Self-check](../self-check.md)

## If it goes wrong

If the archive build needs anything from the checkout, check which dependency or script the export omitted. Confirm that the negative test returned HTTP 503 for the held request.
