# Runbook · Recover the metadata gateway

The game-day harness prepares three peers, a gateway, an active upstream file, a saved upstream file, and a continuous mTLS reader. Run the [gate](gate/README.md) for the complete drill. The steps here describe the operator actions the harness performs. `$lab` refers to the incident directory and `$gateway_pid` to the PID recorded for its current gateway process.

## Confirm the symptom

- Check the latest four probe attempts. Record when the alert first fired and their outcomes. Keep the probe running to observe recovery from the same client.
- Check a known-good reader certificate against the gateway. A handshake rejection points to credentials or trust configuration. A 403 identifies a verified client without permission. An authorized request returning 503 points to the request path beyond TLS.

## Verify the configured upstream

Read both paths and confirm which one names a socket.

~~~bash
IFS= read -r configured < "$lab/upstream"
IFS= read -r saved < "$lab/known-upstream"
printf 'active socket path: %s\nsaved socket path: %s\n' "$configured" "$saved"
test -S "$saved"
~~~

In this drill, the active path is absent and the saved socket still exists. If the saved path is also unavailable, investigate the peer or choose the current verified leader before changing the gateway. A socket on disk alone cannot establish that the peer serves reads.

## Roll back and verify

1. Run `bash ops/restore-upstream.sh "$lab/known-upstream" "$lab/upstream"` from the scratch directory. It validates the saved socket and stages replacement of the active file in the same directory.
2. Stop the owned gateway process with `kill -TERM "$gateway_pid"` and wait for shutdown. Restart the same gateway on the same address with the restored socket path and existing certificate files. The lab harness performs this restart when you run the gate.
3. Wait for the ongoing probe to report at least three good outcomes in its latest four attempts and a clear transition. Read the original metadata value over mTLS and compare it with the expected value.
4. Save the fault, alert, diagnosis, rollback, and recovery times. Record the client result and any assumptions made about the current leader. Use the [reference postmortem](evidence/postmortem.md) as a worked example.
