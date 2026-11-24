# Kubernetes run, 2026-11-24

Lesson 06, run from a fresh kind cluster (kind v0.33.0, Kubernetes v1.37.0: one control plane, one worker) on a 16-CPU laptop under WSL 2. Every output in the lesson comes from these files. Paths are shortened to `~/lab`.

| File | What it shows |
|---|---|
| [01-setup.txt](01-setup.txt) | The cluster, the restricted namespace with default-deny, and Prometheus |
| [02-pss.txt](02-pss.txt) | A Pod without a security context, refused by Pod Security |
| [03-weights.txt](03-weights.txt) | The weights copied in (7 s), their digest inside the cluster, the volume's node |
| [04-cold.txt](04-cold.txt) | Cold start: 335 s to ready, 5 min 33 s of it pulling the image |
| [05-probe.txt](05-probe.txt), [06-policy.txt](06-policy.txt) | The in-cluster probe, and the same request blocked once its policy label is removed |
| [07-replace.txt](07-replace.txt) | Replacing the model Pod under load without the preStop hook: 26 of 122 requests failed |
| [08-replace-hook-1.txt](08-replace-hook-1.txt), [08-replace-hook-2.txt](08-replace-hook-2.txt) | The same with the hook, twice: every request completed |
| [09-break.txt](09-break.txt), [11-break-under-load.txt](11-break-under-load.txt) | A one-second startup allowance: restarts, and 60.6 s with nothing served |
| [10-restore.txt](10-restore.txt) | The measured allowance restored: ready again in 9 s |
| [12-prom.json](12-prom.json), [13-adapter.txt](13-adapter.txt), [14-custom-metric.json](14-custom-metric.json) | The waiting-requests series, the Prometheus adapter, and the metric in the Kubernetes API |
| [15-tokens-before.txt](15-tokens-before.txt), [16-watch.txt](16-watch.txt), [17-load.txt](17-load.txt), [18-tokens-after.txt](18-tokens-after.txt) | The autoscaler under six long requests at a time: scale out at 17 s, ready at 23 s, back in at 467 s |

The [2026-11-13 run](../2026-11-13-kubernetes/README.md) was made on an earlier cluster with less CPU to spare; its numbers differ, most of all the throughput a second replica added (about 40% then, nearly double here).
