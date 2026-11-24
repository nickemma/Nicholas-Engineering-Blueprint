# Core 08 gate

From the finished Core 08 scratch directory, run:

~~~bash
bash "$blueprint/2-core/08-shipping-safely/gate/run.sh" "$PWD"
~~~

The gate builds the Core 07 peers and Rust writer, the gateway, and the probe. It generates two private lab CAs with short-lived leaves. It starts a three-peer cluster, a loopback HTTPS gateway, and a separate probe. It stops its processes and removes its temporary files after the run.

| Check | Passing result |
|---|---|
| Mutual TLS | Clients with a missing certificate or a certificate from the second CA fail the handshake. |
| Authorization | A reader gets HTTP 403 for a write. A writer sets the value and a reader reads it successfully. |
| Alert | After a full healthy window, the fault results in an alert within four bad observations. A verified client receives HTTP 503 while the misconfigured gateway is reachable. |
| Rollback | The saved socket path is restored atomically and the gateway restarts. The original value is readable and the same probe reports a clear transition. |
| Privacy | The gateway, probe, and peer logs omit the synthetic key, value, and PEM private-key material. |
| Negative control | A disposable probe build that drops failures exits with the gate's specific missing-alert failure. The outer gate exits 0 after observing it. |

The [runbook](../runbook.md) gives the operator sequence. Review the [ADR](../adr.md) against the recorded incident. The [game-day capture](../evidence/07-game-day.txt) contains the observed timestamps and outcomes.
