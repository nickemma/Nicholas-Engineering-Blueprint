# 08 Shipping safely

> The core · Time: 3 weeks at 12–15 hours a week · Builds on [06 Linux, networking, and profiling](../06-linux-networking-and-profiling/README.md) and [07 Distributed-systems fundamentals](../07-distributed-systems-fundamentals/README.md) · Status: ready

## What you'll build

Put a Go HTTPS gateway in front of the Core 07 Switchyard metadata service. The gateway authenticates clients with certificates from a lab CA, authorizes reads and writes separately, and forwards approved commands to a configured `metad` peer over a private Unix socket. An independent synthetic client measures whether an authorized request returns the expected value within its deadline. Use its observations to trigger an alert, follow a recovery runbook, and write a postmortem.

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [A container is a process](lessons/01-a-container-is-a-process.md) | Compare the same command on the host and in a Linux namespace. Observe PID and mount visibility, then use a delegated cgroup to compare resource accounting and limits. Read the image configuration and connect it to the running process. |
| 1 | 02 | [Model the trust boundary](lessons/02-model-the-trust-boundary.md) | Draw the client, gateway, peer sockets, logs, and private key files. Inventory what crosses each boundary. Use a reader and a writer to distinguish establishing an identity from granting permission to perform an operation. |
| 1–2 | 03 | [Issue certificates and require mTLS](lessons/03-issue-certificates-and-require-mtls.md) | Create lab CA, server, and client certificates. Require a verified client certificate and use its signed identity to apply the read/write policy. Exercise authorized requests, missing credentials, untrusted certificates, and authenticated requests outside the client's role. |
| 2 | 04 | [Limit what the gateway can read and record](lessons/04-limit-what-the-gateway-can-read-and-record.md) | Load keys from owner-restricted files outside the source tree. Use a private socket directory and a command allowlist. Put a synthetic value through the metadata path and check that gateway logs and probe records omit payloads and key material. |
| 2–3 | 05 | [Define reliability from the client side](lessons/05-define-reliability-from-the-client-side.md) | Count eligible probe attempts and good outcomes, including the response deadline and expected value. Set an SLO and calculate its error budget. Use short, fixed lab windows to exercise alert firing and recovery against recorded probe observations. |
| 3 | 06 | [Verify an AI-assisted change](lessons/06-verify-an-ai-assisted-change.md) | Review a drafted policy test, a decoder fuzz target, and the declared ownership and lifetime at a small Core 05 FFI boundary. Use explicit checks to accept or correct each draft. Keep fixed drafts in the lesson so the verification replays locally. |
| 3 | 07 | [Run a game day and defend the decision](lessons/07-run-a-game-day-and-defend-the-decision.md) | Capture the alert, diagnose an unavailable upstream socket, restore the last known good configuration, and verify recovery through the client API. Write a postmortem and defend the decision to keep the local peer transport behind an authenticated gateway. |

The namespace and cgroup observations use an environment with namespace support and cgroup delegation. The automated gate uses temporary local processes and sockets.

## The gate

The [automated gate](gate/README.md) starts the Core 07 cluster with a known metadata value and runs the gateway against an elected peer. Establish a healthy probe window. Restart the gateway with a syntactically valid configuration that names an unavailable Unix socket, then let the external probe observe the failure. Use the [runbook](runbook.md) to restore the prior configuration, restart the gateway, and verify the value through mTLS.

- The probe counts failed attempts during the fault and the alert fires within the declared lab window. Healthy probes resume and the alert clears within the recovery window.
- The run records the fault, alert, diagnosis, rollback, and recovery with timestamps. The recovered read returns the original value.
- Missing or untrusted client credentials fail at TLS. An authenticated reader's write fails at authorization. The evidence includes a positive writer check and a log scan for the synthetic payload.
- A deliberately broken alert that omits failed attempts must fail the same fault drill. For review, the [ADR](adr.md) names the rejected design, the Unix-socket access assumption, the failure introduced by the configured upstream, and the evidence that informs the decision.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Explain what a namespace changes and show which clients can read or write. |
| Intermediate | Calculate the probe SLI from observations and use the runbook to recover a failed request path. |
| Senior | Defend where the authentication boundary sits, explain which failures the SLO sees, and support the ADR with game-day evidence. |

## Practice

- [Exercise](exercises.md). Build an independent probe and runbook for a service of your choice.
- [Self-check](self-check.md). Use request outcomes to distinguish credential, authorization, and upstream failures.
- [Evidence](evidence/README.md). Review the observed checks and the reference postmortem.

## Next

The [Journey](../../JOURNEY.md) shows the shared units and the three specialization tracks.
