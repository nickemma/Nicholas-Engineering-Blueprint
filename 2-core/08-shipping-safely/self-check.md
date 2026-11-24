# Core 08 self-check

| Lesson | Explain from memory |
|---|---|
| 01 | Which kernel feature changes what a process sees? Which feature accounts for its tasks? What does an image contribute? |
| 02 | Draw the client, issuer, gateway, peer, and durable log. Mark which identity each boundary trusts and where write authority is decided. |
| 03 | Explain why the client needs the server IP or hostname and why the gateway needs the signed client identity. Which processes need each private key? |
| 04 | Which exact fields are sent upstream? How do file permissions and trusted account ownership affect the Unix-socket boundary? |
| 05 | Convert a 99.9% SLO to allowed misses over 10,000 eligible attempts. Evaluate the rolling window for four successes, two failures, then three successes. |
| 06 | Explain why an allow-all policy can pass a positive-only test. Describe which property the decoder fuzzer checks and how the Rust wrapper protects the C call. |
| 07 | State what changed, what the client observed, and which check established that the prior value survived. |

## Diagnose from memory

You observe three independent runs. The first client fails the TLS handshake. The second presents a trusted reader certificate and gets 403 on a write. The third presents that same certificate and gets 503 on a read.

For each, identify the stage that produced the result and the first observation you would take. Then write down the compound condition that would let you declare the third incident recovered.

<details>
<summary>Check your reasoning</summary>

The first request has a TLS trust or credential problem. Check the trust root, leaf purpose, server identity, and client credential. The second made it to the operation policy, which denies the reader's write by design. The third passed those gates. Check the configured peer path and peer availability. Recovery requires a good probe window and a read returning the expected value through the same authenticated client path.

</details>

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
