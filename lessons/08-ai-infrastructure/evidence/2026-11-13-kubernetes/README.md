# Step 6 captures, 2026-11-13

Phase 5's kind layout (one control plane, two workers, Kubernetes 1.37), the `runway` namespace with restricted Pod Security and default-deny policies, Phase 5's Prometheus, and the Step 6 manifests as written in the guide. One laptop: 16 threads, about 7.5 GB of RAM for WSL.

| File | What it is |
|---|---|
| `pss-refusal.txt` | The namespace refusing a Pod with no security settings |
| `cold.json`, `warm.json` | Pod records for the first start (image pull) and a replacement |
| `policy-check.txt` | The probe without its label: the policy drops the connection |
| `replace-rows.txt`, `replace3-rows.txt` | Pod replaced under load, no preStop hook (one and three workers) |
| `drain-rows.txt`, `drain2-rows.txt` | The same with the preStop hook, twice |
| `break-startup.txt` | Startup allowance of one second: the restart loop |
| `hpa2-*.txt` | Queue-depth autoscaling: settings, watcher, probe rows, per-Pod token counters, Pods, and the sleep/clock check (`CLEAN`) |

Limits and corrections:

- An earlier autoscaling run is not included: the wall clock stepped forward about 386 s during it, and Kubernetes keeps its scale-down timing on that clock. The run here was repeated with a sleep and clock-step check running alongside.
- The watcher log ends with about 100 s of `ready=0`: the cluster's node containers were stopped from outside the experiment at 15:21:09 PST, after the scale-down at 468 s had been recorded. Those last lines are not a result.
- Every model replica shared one node, because the weights volume is `ReadWriteOnce`. Nothing here measures scaling across nodes.
