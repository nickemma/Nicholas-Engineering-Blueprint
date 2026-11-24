# Step 10 captures, 2026-11-13

Two CPU training ranks (gloo, PyTorch 2.15.0) in two containers on one laptop, joined by one Docker bridge shaped with netem by `experiments/ddp/link.sh`. The model and code are Step 10's `serve.ddpnet`.

| File | What it is |
|---|---|
| `local.txt`, `break-resume.txt` | Two ranks on one machine: straight run, stop at step 3 and resume, and the resume without optimiser state failing the serial check |
| `matrix.jsonl` | Small (32 hidden) and big (32,768 hidden) model on four link shapes, two shuffled repeats each |
| `rtt.txt` | Big model at 20 and 80 ms round trip, no bandwidth limit |
| `bigbuf.txt` | Big model at 40 ms with the TCP buffer cap raised to 64 MB: no change |
| `noss.txt` | Big model at 40 ms with `tcp_slow_start_after_idle=0`: no change. Its 20 and 80 ms lines were repeated without that setting in `rtt.txt`, with the same results |
| `fail.log`, `fail-*-train.txt` | Rank 1 killed, and 100% packet loss, twice each, then resumed |
| `*-sleepwatch.txt` | No sleep or clock step during the matrix or the failure runs |

Limits: two containers on one host are not two machines; this is CPU gloo over TCP, not NCCL over NVLink or InfiniBand. The cause of the big model's six round trips per all-reduce is not established; two candidate explanations were tested and ruled out.
