# 08 Run the control-plane game day

> The proxy’s control plane · Week 3 · Builds on lesson 07

## The problem

An update log alone cannot establish that the serving path stayed usable. Check the management view and the request path during each failure and recovery.

## The mental model

Keep the applied generation, selected origin, receipt count, and TLS serials as independent observations. A failure to receive an acknowledgement does not determine whether an update went through.

## The pattern

Run the portable gate from the assembled work directory. In a disposable copy, change the acknowledgement returned for a duplicate update and show that the retry assertion fails. Run the OpenBao and XDP profiles with their designated fixtures.

## Build it

### Step 1 — Write a brief operator timeline

Record the rejected health check, the lost acknowledgement after publication, the successful retry, the rollback, and the fresh TLS handshakes in time order.

<details>
<summary>Hint</summary>

Use the origin observed by the held request and the next request as separate evidence.

</details>

### Step 2 — Verify the other profiles

Verify the limited OpenBao token, the signing key versions, and the XDP packet delta. Keep the observed status or capability failure for each profile.

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/cloud-and-network/03-proxy-control-plane/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/cloud-and-network/03-proxy-control-plane/gate/run.sh" "$PWD" -->

The portable gate passed and its intentional duplicate-acknowledgement change failed the designated retry assertion. [Gate transcript](../evidence/portable.txt) · [Exercises](../exercises.md) · [Self-check](../self-check.md)

## If it goes wrong

If the mutation fails anywhere else, inspect the transcript and repair the test setup before claiming the retry assertion caught it.
