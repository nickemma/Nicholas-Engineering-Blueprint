# 03 The proxy's control plane

> Cloud and network track · 3 weeks at 12–15 hours a week · Status ready

## What you'll build

Add a Go controller to the Rust proxy from Part 02. The controller checks candidate origins and sends versioned route snapshots over a mutually authenticated management connection. A Go sidecar checks the controller's identity and relays updates to the Rust process over a private Unix socket. The proxy validates each snapshot before publishing it and reports the applied generation. Each request keeps the origin it selected at the start, so it can finish even as the active route changes. [A Rust edge proxy](../02-rust-edge-proxy/README.md) · [Go–Rust wire](../../../2-core/06-linux-networking-and-profiling/README.md)

Start with [Before you start](lessons/00-before-you-start.md). The lab uses two fixed origin slots and in-memory generations.

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Push a versioned route snapshot](lessons/01-push-a-versioned-snapshot.md) | Define generation, digest, and acknowledgement. Reject stale generations and conflicting content at the same generation. Retry the same snapshot safely after a lost acknowledgement. |
| 1 | 02 | [Check origins and apply a route change](lessons/02-check-and-apply-a-route.md) | Run bounded health checks against configured origins. Hold an active request while publishing a checked snapshot, then verify the old request finishes and the new request reaches the new origin. Publish a rollback as a new generation. |
| 1 | 03 | [Put mutual TLS on the management path](lessons/03-bind-management-peer-identities.md) | Bind controller and sidecar roles to explicit certificate identities. Send accepted updates through a permission-restricted Unix socket and check that an unrecognized peer leaves the active generation unchanged. |
| 2 | 04 | [Rotate the management certificates](lessons/04-rotate-management-certificates.md) | Replace the leaf credentials with an overlap window. Test new TLS handshakes during and after rotation. Use a generation readback to verify that the rotated channel can still apply changes. |
| 2 | 05 | [Deliver signed events to registered destinations](lessons/05-deliver-signed-events.md) | Sign the exact body with a timestamp and event identifier. Check authentication, freshness, and idempotent receipt. Select destinations from trusted configuration and enforce an outbound allowlist for SSRF prevention. |
| 2 | 06 | [Load a signing key from OpenBao](lessons/06-load-a-key-from-openbao.md) | Give the signing process read access to its own secret path. Verify policy denial for another path, then rotate the key and check delivery using the newly loaded version. |
| 3 | 07 | [Count traffic from the kernel](lessons/07-count-traffic-at-xdp.md) | Attach a pass-through XDP counter in a disposable Linux network namespace. Compare the counter before and after known fixture traffic and correlate it with the origin's request count. |
| 3 | 08 | [Run the control-plane game day](lessons/08-run-the-control-plane-gate.md) | Exercise a bad route candidate, lost acknowledgement, certificate rotation, and a webhook key change. Use request outcomes and applied generations to show recovery, then run the negative control. |

Lessons 03–04 use the [lab certificate authority](../../../2-core/08-shipping-safely/lessons/03-issue-certificates-and-require-mtls.md) from Core 08. Lesson 07 extends Core 06's kernel observations.

## The gate

- Start two instrumented origins and apply a valid route change through the controller and sidecar. An in-flight request must finish at the old origin and the next request must reach the new one. A failed health check, stale generation, or conflicting snapshot must leave the active generation and route intact. Retry after a lost acknowledgement and verify that the same generation is acknowledged without reapplying the snapshot. A disposable build that drops the idempotent acknowledgement must fail this retry check.
- Verify the controller and sidecar identities on fresh connections before and after a leaf rotation. Require a trusted certificate carrying the wrong role identity to leave the proxy's generation unchanged.
- Deliver a signed event once and confirm an idempotent retry. Verify that rejected signatures, expired events, and unregistered destinations leave recipient state unchanged. Use an isolated OpenBao instance to check that the signing role reads its own key path, sees a rotated key, and receives a policy denial for another path.
- Run XDP verification on a disposable veth pair with kernel support and permission to attach the program. Check that fixture packets still pass and that the counter increases. Record the interface, attach mode, and before-and-after counts. The loopback gate runs separately from the privileged kernel check.

[Run the gate](gate/README.md) · [Reference captures](evidence/README.md)

## Practice

- Reconcile after a restart, measure when a health sample goes stale, and rotate a signing key with a bounded overlap. [Exercises](exercises.md)
- Trace the trust boundaries and route transitions from memory. [Self-check](self-check.md)

The capstone uses this control path to measure request continuity during reloads under load. [A programmable edge proxy](../04-capstone-programmable-edge-proxy/README.md)
