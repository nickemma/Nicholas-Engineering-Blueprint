# 07 Run the gate and explain the limits

> A Rust edge proxy · Week 4 · Builds on lesson 06

## The problem

A test can pass while missing the invariant you want it to enforce. A benchmark can show high successful throughput while hiding the requests that did not finish.

## The mental model

Match each client observation to origin evidence. The relay forwards the remaining bytes after FIN. The pool changes socket counts. The breaker changes which requests the origin ever receives.

## The pattern

Run the portable gate from the assembled learner workspace. It builds two copies with one behavior removed at a time. Require each copy to fail at its matching assertion. Read the loopback performance results as measurements of this workload and setup.

## Build it

### Step 1 — Check the reference and the two negative cases

Run the gate from the workspace that contains Cargo.toml. For the reuse check, predict the socket count when each of the 12 requests has to dial. For the breaker check, predict the origin count when the fourth request is forwarded.

<details>
<summary>Hint</summary>

The two assertions compare independent origin counters.

</details>

### Step 2 — Save a short benchmark report

Use the direct baseline and repeated trials to describe which path met the offered load, which dropped work, and how much scheduled-start latency came from the driver. Retain the configuration and raw rows.

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/cloud-and-network/02-rust-edge-proxy/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/cloud-and-network/02-rust-edge-proxy/gate/run.sh" "$PWD" -->

The gate recorded both deliberate failures and then passed.

~~~text
AssertionError: pool: 12 sockets for 12 requests
AssertionError: breaker: open request reached origin (count=4)
edge proxy gate passed
~~~

[Gate transcript](../evidence/gate.txt) · [Exercises](../exercises.md) · [Self-check](../self-check.md)

## If it goes wrong

If a negative case reports a build, connection, or fixture error, fix that before treating the case as a detection. The gate only accepts the designated assertion.
