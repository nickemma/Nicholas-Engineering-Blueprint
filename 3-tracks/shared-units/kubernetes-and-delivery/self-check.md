# Kubernetes and delivery · Self-check

| Lesson | Explain from memory |
|---|---|
| 01 | Which probe controls routing, and which can cause a restart? How do you distinguish a slow start from an unhealthy running process? |
| 02 | How does a client find a Service after the selected Pod changes? Which selector directs candidate traffic? |
| 03 | Draw the jobs API, worker, migration Job, and PostgreSQL volume. Which state persists across recreating each Pod? |
| 04 | Name the three links among StatefulSet ordinal, TLS peer identity, and Rust log claim. Which observation shows the replacement applied committed state? |
| 05 | Why can an old ready Pod hide a failed candidate? What check controls promotion? |
| 06 | Which identity can sign? Which process can verify? How do the image and its attached inventory stay bound to the deployed artifact? |
| 07 | Given two spans, which IDs establish the same trace and parent-child relationship? |
| 08 | Calculate burn rate when 8% of requests fail against a 99% SLO. Why check two windows? |
| 09 | Why use the durable queue gauge and scale subresource? What happens when the sample is NaN or an update races with another writer? |
| 10 | Which control applies at admission, which at API authorization, and which when a peer sends network traffic? |

## Rebuild the drill from memory

Draw the path from an image produced by CI to the running candidate. Describe how you prove readiness failure, keep the stable path available, restore the release, and verify the old data remains readable. Write down the role, observation, and evidence for each transition.
