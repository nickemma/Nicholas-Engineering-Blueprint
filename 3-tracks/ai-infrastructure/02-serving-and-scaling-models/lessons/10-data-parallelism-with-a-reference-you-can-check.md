# 10 Data parallelism, with a reference you can check

Inference batches different users' requests. Training batches examples to estimate one gradient. **Data parallelism** gives every rank (one process, often one GPU) a full copy of the model and a different share of the examples. After the backward pass, the ranks **all-reduce** their gradients: each ends up with the average of everyone's. Then each takes the same optimiser step, so the copies stay identical.

That's a claim you can test. With equal shares and a mean loss, the average of the ranks' gradients must equal the gradient of the whole batch on one process. So two ranks must end up with exactly the weights that one process would, apart from rounding. Build that check before measuring any speed. [PyTorch's DDP tutorial](https://docs.pytorch.org/tutorials/intermediate/ddp_tutorial.html) explains the process group and the model wrapper.

<!-- file: serve/src/serve/ddp.py -->
~~~python
"""One full-batch SGD update: two CPU ranks must equal the serial reference."""

import json
import os
import time
from datetime import timedelta

import torch
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP


def main():
    torch.set_num_threads(1)
    dist.init_process_group("gloo", timeout=timedelta(seconds=30))
    rank, world = dist.get_rank(), dist.get_world_size()
    try:
        torch.manual_seed(41)
        model = torch.nn.Linear(8, 1, bias=False)
        reference = torch.nn.Linear(8, 1, bias=False)
        reference.load_state_dict(model.state_dict())
        torch.manual_seed(7)
        x = torch.randn(32, 8)
        y = x.sum(dim=1, keepdim=True)
        if len(x) % world:
            raise ValueError("equal shard sizes required by this mean-loss example")
        ddp = DDP(model)
        optimizer = torch.optim.SGD(ddp.parameters(), lr=0.01)
        serial = torch.optim.SGD(reference.parameters(), lr=0.01)
        dist.barrier()
        start = time.perf_counter()
        for _ in range(4):
            optimizer.zero_grad()
            loss = (ddp(x.chunk(world)[rank]) - y.chunk(world)[rank]).square().mean()
            loss.backward()
            optimizer.step()
            serial.zero_grad()
            (reference(x) - y).square().mean().backward()
            serial.step()
        dist.barrier()
        elapsed = time.perf_counter() - start
        torch.testing.assert_close(model.weight, reference.weight, rtol=1e-5, atol=1e-6)
        # Atomic checkpoint published by one writer, after the same update count.
        if rank == 0:
            torch.save(
                {
                    "model": model.state_dict(),
                    "optimizer": optimizer.state_dict(),
                    "step": 4,
                    "seed": 41,
                    "world": world,
                },
                "checkpoint.tmp",
            )
            os.replace("checkpoint.tmp", "checkpoint.pt")
            print(json.dumps({"world": world, "seconds": elapsed, "serial_parity": True}))
        dist.barrier()
    finally:
        dist.destroy_process_group()


if __name__ == "__main__":
    main()
~~~

<!-- run: cd serve && uv run python -m torch.distributed.run --standalone --nproc-per-node=2 -m serve.ddp -->

~~~bash
cd serve
uv run python -m torch.distributed.run --standalone --nproc-per-node=2 -m serve.ddp
~~~

`torch.distributed.run` (also installed as `torchrun`) starts two processes and tells each its rank. They meet through a rendezvous on this machine, and gloo, PyTorch's CPU backend, carries the all-reduce over TCP. The script prints `"serial_parity": true`: four distributed updates matched four serial ones. Its timing isn't a speed measurement, because the serial reference runs inside the timed loop.

## Checkpoint, crash, resume

Long training runs fail: a machine dies, a network link drops. What matters is what you can resume from. Three things make a resume correct:

1. **The whole training state.** The weights, the optimiser's state (SGD with momentum keeps a running average of past gradients), and the step number. Weights alone aren't enough.
2. **An atomic write.** Write to a temporary file, then rename it. A crash mid-write leaves the previous checkpoint intact; the rename either happened or it didn't.
3. **The same data.** A resumed run must see the examples the uninterrupted run would have, with none repeated or skipped. Here, each step's examples are generated from the step number, so that's automatic. With a real dataset, you save the sampler's position and the random state too.

<!-- file: serve/src/serve/ddpnet.py -->
~~~python
"""Train across ranks, checkpoint every step, survive a failure, and prove it.

  torchrun --standalone --nproc-per-node=2 -m serve.ddpnet --steps 6 --dir ckpt

Each step's examples come from the step number, so a resumed run sees exactly
the examples the uninterrupted run would have. At the end, rank 0 trains a serial
copy from the same start and checks that the distributed model matches it.
"""

import argparse
import json
import os
import statistics
import time
from datetime import timedelta
from pathlib import Path

import torch
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel as DDP

BATCH = 64  # the global batch; each rank gets an equal share


def make_model(hidden: int) -> torch.nn.Module:
    torch.manual_seed(41)
    return torch.nn.Sequential(
        torch.nn.Linear(64, hidden), torch.nn.ReLU(), torch.nn.Linear(hidden, 1)
    )


def batch(step: int) -> tuple[torch.Tensor, torch.Tensor]:
    g = torch.Generator().manual_seed(1000 + step)
    x = torch.randn(BATCH, 64, generator=g)
    return x, x[:, :8].sum(dim=1, keepdim=True)


def optimiser(model: torch.nn.Module) -> torch.optim.Optimizer:
    # A wider layer sums more terms, so the same step moves its output further:
    # shrink the learning rate with width, or training diverges.
    hidden = model[0].out_features
    return torch.optim.SGD(model.parameters(), lr=0.01 * min(1, 32 / hidden), momentum=0.9)


def train_step(model, opt, x, y) -> None:
    opt.zero_grad()
    (model(x) - y).square().mean().backward()
    opt.step()


def save(path: Path, model, opt, step: int) -> None:
    """Write the whole training state, then rename: a crash leaves the old file intact."""
    tmp = path.with_suffix(".tmp")
    torch.save({"model": model.state_dict(), "opt": opt.state_dict(), "step": step}, tmp)
    os.replace(tmp, path)


def resume(path: Path, model, opt) -> int:
    if not path.exists():
        return 0
    state = torch.load(path)
    model.load_state_dict(state["model"])
    opt.load_state_dict(state["opt"])  # the momentum buffers are training state too
    return state["step"]


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--steps", type=int, default=6)
    p.add_argument("--hidden", type=int, default=32)
    p.add_argument("--dir", type=Path, default=Path("ckpt"))
    p.add_argument("--stop-at", type=int, default=0, help="exit after this step, like a crash")
    p.add_argument(
        "--timeout", type=float, default=20, help="seconds before a stuck collective fails"
    )
    a = p.parse_args()
    torch.set_num_threads(1)
    dist.init_process_group("gloo", timeout=timedelta(seconds=a.timeout))
    rank, world = dist.get_rank(), dist.get_world_size()
    path = a.dir / "checkpoint.pt"
    try:
        model = make_model(a.hidden)
        opt = optimiser(model)
        start = resume(path, model, opt)
        ddp = DDP(model)
        params = sum(p.numel() for p in model.parameters())
        step_times = []
        for step in range(start, a.steps):
            x, y = batch(step)
            began = time.perf_counter()
            train_step(ddp, opt, x.chunk(world)[rank], y.chunk(world)[rank])
            step_times.append(time.perf_counter() - began)
            dist.barrier()  # every rank finished this step before it is recorded
            if rank == 0:
                save(path, model, opt, step + 1)
            if step + 1 == a.stop_at:
                if rank == 0:
                    print(json.dumps({"stopped_after": step + 1}), flush=True)
                return
        # The network alone: all-reduce a buffer the size of the gradients.
        grads = torch.zeros(params)
        reduce_times = []
        for _ in range(5):
            began = time.perf_counter()
            dist.all_reduce(grads)
            reduce_times.append(time.perf_counter() - began)
        if rank == 0:
            serial = make_model(a.hidden)
            serial_opt = optimiser(serial)
            for step in range(a.steps):
                train_step(serial, serial_opt, *batch(step))
            for mine, ref in zip(model.parameters(), serial.parameters(), strict=True):
                torch.testing.assert_close(mine, ref, rtol=1e-4, atol=1e-5)
            report = {
                "world": world,
                "params": params,
                "grad_mb": round(params * 4 / 1e6, 2),
                "resumed_from": start,
                "steps": a.steps,
                "step_ms": round(statistics.median(step_times) * 1000, 1) if step_times else None,
                "allreduce_ms": round(statistics.median(reduce_times) * 1000, 1),
                "matches_serial": True,
            }
            print(json.dumps(report), flush=True)
    finally:
        dist.destroy_process_group()


if __name__ == "__main__":
    main()
~~~

How it fits together:

- `batch(step)` builds that step's 64 examples from a seed derived from the step number. Each rank takes its half with `chunk`.
- After every step, a `barrier` makes sure both ranks finished, then rank 0 saves. Only one rank writes, so there's one checkpoint, not two that might disagree. Both ranks read it when they start again.
- `--stop-at` exits after a step, as a clean stand-in for a crash. Real crashes come later.
- The all-reduce timing sends a buffer exactly the size of the gradients, five times, and keeps the median. That isolates the network from the computation.
- At the end, rank 0 trains a serial copy from the same starting weights for the same steps, and `assert_close` fails the run if the two models differ.
- The learning rate shrinks as the hidden layer gets wider. I found out why the hard way: with 32,768 hidden units and a learning rate of 0.01, the loss went from 7 to about 8 × 10¹⁴ in six steps, and the parity check failed by 0.9. Training that diverges magnifies tiny rounding differences until two correct implementations disagree. The check caught a real problem, just not the one it was written for.

Run it straight through, then stopped at step 3 and resumed:

<!-- run: cd serve && rm -rf /tmp/ddpnet-a /tmp/ddpnet-b && mkdir -p /tmp/ddpnet-a /tmp/ddpnet-b && uv run python -m torch.distributed.run --standalone --nproc-per-node=2 -m serve.ddpnet --steps 6 --dir /tmp/ddpnet-a && uv run python -m torch.distributed.run --standalone --nproc-per-node=2 -m serve.ddpnet --steps 6 --stop-at 3 --dir /tmp/ddpnet-b && uv run python -m torch.distributed.run --standalone --nproc-per-node=2 -m serve.ddpnet --steps 6 --dir /tmp/ddpnet-b -->

~~~bash
cd serve
mkdir -p ckpt-a ckpt-b
uv run python -m torch.distributed.run --standalone --nproc-per-node=2 -m serve.ddpnet --steps 6 --dir ckpt-a
uv run python -m torch.distributed.run --standalone --nproc-per-node=2 -m serve.ddpnet --steps 6 --stop-at 3 --dir ckpt-b
uv run python -m torch.distributed.run --standalone --nproc-per-node=2 -m serve.ddpnet --steps 6 --dir ckpt-b
~~~

~~~text
{"world": 2, "params": 2113, "grad_mb": 0.01, "resumed_from": 0, "steps": 6, "step_ms": 2.3, "allreduce_ms": 0.9, "matches_serial": true}
{"stopped_after": 3}
{"world": 2, "params": 2113, "grad_mb": 0.01, "resumed_from": 3, "steps": 6, "step_ms": 2.2, "allreduce_ms": 0.6, "matches_serial": true}
~~~

Both runs end with weights that match the serial model; the second resumed from step 3. Above each result, `torchrun` prints a banner saying it set `OMP_NUM_THREADS` to 1 for each process. That's expected, and harmless here.

**Break it:** in `resume`, delete the line that loads the optimiser state, so a resumed run starts with no momentum. Run the stop-and-resume pair again (delete `ckpt-b` first):

~~~text
[rank0]: AssertionError: Tensor-likes are not close!

[rank0]: Mismatched elements: 2028 / 2048 (99.0%)
[rank0]: Greatest absolute difference: 0.016440898180007935 at index (7, 6) (up to 1e-05 allowed)
[rank0]: Greatest relative difference: 23.150144577026367 at index (29, 5) (up to 0.0001 allowed)
...
serve.ddpnet FAILED
~~~

The weights were restored exactly, yet the model no longer matches. Momentum is part of the training state. Put the line back.

## Across a real network link

On one machine, the ranks talk over loopback, which is almost free. Put them in two containers with a link you control, as in the [network calibration lab](../../../cloud-and-network/01-networking-in-depth/lessons/01-calibrate-a-network-you-can-break.md):

<!-- file: experiments/ddp/Dockerfile -->
~~~text
# One training rank: Python, CPU PyTorch at the version serve/ locks, and tc.
FROM python:3.12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 \
 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir numpy==2.5.4 \
 && pip install --no-cache-dir torch==2.15.0 --index-url https://download.pytorch.org/whl/cpu
ENV PYTHONPATH=/lab/serve/src
~~~

<!-- file: experiments/ddp/compose.yaml -->
~~~yaml
# Two training ranks joined by one link, like netlab: tc on each side shapes
# what that side sends. Run from the lab root:
#   docker compose -f experiments/ddp/compose.yaml up -d --build
name: ddp
services:
  rank0: &rank
    image: ddp-rank
    build: .
    command: sleep infinity
    cap_add: [NET_ADMIN] # for tc on this container's own interface
    volumes: ["../..:/lab"] # the code, and a shared checkpoint directory
    working_dir: /lab
    environment:
      GLOO_SOCKET_IFNAME: eth0 # talk over the shaped link, not loopback
  rank1:
    <<: *rank
~~~

<!-- file: experiments/ddp/link.sh -->
~~~bash
#!/bin/sh
# Shape the link between the two ranks. All-reduce sends both ways, so each
# side gets half the round trip, the full rate limit and the loss. The queue
# holds 10,000 packets: a gradient burst is thousands, and netem drops beyond it.
#   experiments/ddp/link.sh 40ms 100mbit 0%     round trip, rate, loss
#   experiments/ddp/link.sh off
set -eu
c() { docker compose -f "$(dirname "$0")/compose.yaml" exec -T "$@"; }
for r in rank0 rank1; do
  if [ "$1" = off ]; then
    c "$r" tc qdisc del dev eth0 root 2>/dev/null || true
  else
    c "$r" tc qdisc replace dev eth0 root netem delay "$(( ${1%ms} / 2 ))ms" rate "$2" loss "$3" limit 10000
  fi
done
~~~

<!-- run: chmod +x experiments/ddp/link.sh && sh -n experiments/ddp/link.sh -->

`GLOO_SOCKET_IFNAME=eth0` matters: without it, gloo may choose an interface that bypasses the shaped one, and your measurements would be of the wrong link. Start the two containers and check the shaping works:

~~~bash
docker compose -f experiments/ddp/compose.yaml up -d --build
experiments/ddp/link.sh 40ms 100mbit 0%
docker compose -f experiments/ddp/compose.yaml exec rank0 tc qdisc show dev eth0
experiments/ddp/link.sh off
~~~

~~~text
qdisc netem 8001: root refcnt 17 limit 10000 delay 20ms rate 100Mbit seed 7001724481774582651
~~~

Half the round trip on each side, as `link.sh` intends. If it fails with `Specified qdisc kind is unknown`, your kernel needs netem loaded as a module: load it with netlab's image, `docker run --rm --privileged -v /lib/modules:/lib/modules:ro nettools modprobe sch_netem`.

Each training run needs one command per container. `train.sh` starts both, with rank 0's container as the meeting point:

<!-- file: experiments/ddp/train.sh -->
~~~bash
#!/usr/bin/env bash
# Start one training job across the two containers; arguments go to serve.ddpnet.
#   experiments/ddp/train.sh --steps 6 --hidden 2048 --dir ckpt
# Exits non-zero if either rank failed.
set -uo pipefail
here=$(dirname "$0")
node() {
  local r=$1; shift
  docker compose -f "$here/compose.yaml" exec -T "rank$r" \
    python -m torch.distributed.run --nnodes=2 --nproc-per-node=1 --node-rank="$r" \
    --master-addr=rank0 --master-port=29500 -m serve.ddpnet "$@" 2>&1 | sed "s/^/[rank$r] /"
}
node 1 "$@" &
other=$!
node 0 "$@"
mine=$?
wait "$other"
theirs=$?
exit $(( mine || theirs ))
~~~

<!-- run: chmod +x experiments/ddp/train.sh && bash -n experiments/ddp/train.sh -->

## Predict, then measure

Before running anything, predict. A step's all-reduce must at least:

- **wait for round trips.** Gloo's ring all-reduce for two ranks takes a few message exchanges, each costing a round trip, whatever the size.
- **move the bytes.** Each rank sends about 2(P−1)/P times the gradient size, where P is the number of ranks. For P = 2 that's the gradient size once.

So a small model is **latency-bound**: its step time grows with the round trip and ignores bandwidth. A big model is **bandwidth-bound**: With `--hidden 32768` the model has 2.16 million parameters: 8.65 MB of gradients. At 100 Mbit/s (12.5 MB/s) that's at least 0.69 s per all-reduce, whatever the round trip; at 10 Gbit/s, under 10 ms.

Now measure. Each run below is one call to `train.sh`, on a link set by `link.sh`, and prints the same JSON line as before. For example, the big model on a 40 ms, 100 Mbit/s link:

~~~bash
experiments/ddp/link.sh 40ms 100mbit 0%
rm -rf ckpt-m && mkdir ckpt-m
experiments/ddp/train.sh --steps 6 --hidden 32768 --dir ckpt-m
experiments/ddp/link.sh off
~~~

~~~text
[rank0] {"world": 2, "params": 2162689, "grad_mb": 8.65, "resumed_from": 0, "steps": 6, "step_ms": 972.5, "allreduce_ms": 928.3, "matches_serial": true}
~~~

`10gbit` stands in for "no bandwidth limit": netem needs some rate, and this one is far above what the link can actually do. I ran every combination twice, in shuffled order, and checked that the laptop didn't sleep. All-reduce times, in milliseconds:

| Link | Small model (8 KB) | Big model (8.65 MB) |
|---|---:|---:|
| No shaping | 0.7, 0.8 | 7.8, 8.4 |
| 100 Mbit/s, no added delay | 1.4, 1.5 | 728, 728 |
| 40 ms round trip, no bandwidth limit | 81, 81 | 248, 248 |
| 40 ms round trip and 100 Mbit/s | 82, 82 | 889, 928 |

Every run also passed the serial check. The predictions held in two cases and failed in one:

- **The small model is latency-bound, as predicted.** A bandwidth limit barely touched it (0.7 → 1.4 ms). A 40 ms round trip made each all-reduce cost 81 ms: two round trips.
- **The big model is bandwidth-bound, as predicted.** At 100 Mbit/s it took 728 ms, close to the 692 ms the bytes alone need.
- **But the big model also paid far more for latency than predicted.** With no bandwidth limit, a 40 ms round trip cost 248 ms, not "under 10 ms". So I varied the round trip:

| Round trip | Big model all-reduce |
|---|---:|
| 20 ms | 128 ms |
| 40 ms | 248 ms |
| 80 ms | 489 ms |

That's six round trips every time, three times as many as the small model's two. My first explanation was the bandwidth-delay product from the Networking Bridge: TCP's send buffer is capped at 4 MB here, which limits a connection to about 100 MB/s at a 40 ms round trip. So I raised the cap to 64 MB in both containers and reran: 248.5 and 249.2 ms, no change. My second explanation was TCP restarting slowly after idle (`net.ipv4.tcp_slow_start_after_idle`). Turning that off also changed nothing: 249.2 and 248.6 ms. What's left is the most likely cause, though I haven't verified it: gloo's all-reduce splits a large buffer into steps that each wait for the other rank, so it pays more round trips than a small message does. Two wrong explanations, each ruled out with a measurement, is a normal day in performance work. Write them down; they stop the next person from trying them again.

What the measurements do support is a simple model you can use to plan:

**all-reduce time ≈ (round trips × RTT) + (bytes ÷ bandwidth)**

With six round trips for the big model, it predicts 6 × 40 + 692 = 932 ms at 40 ms and 100 Mbit/s. I measured 889 and 928 ms. Without any shaping, the big model's step took 35–53 ms, of which the all-reduce was only 8 ms: computation dominated. On the 100 Mbit/s link, the all-reduce was more than 90% of every step. That's why real clusters put GPUs on links a thousand times faster, and why frameworks overlap communication with the backward pass.

**Your turn:** add a fifth row with loss, `link.sh 40ms 100mbit 1%`, and predict it first. Core 06 measured what 1% loss does to a single TCP download.

## Break it: lose a rank, lose the link

A training job across machines can lose a rank (the process or the machine dies) or lose the link (packets stop arriving). Either way, the other rank is left waiting inside an all-reduce. The questions: does the job end, how quickly, and can it resume exactly?

Run a longer job, 30 steps of the big model on the 40 ms, 100 Mbit/s link, and break it about 12 seconds in. First, kill rank 1's container outright:

~~~bash
experiments/ddp/link.sh 40ms 100mbit 0%
rm -rf ckpt-f && mkdir ckpt-f
experiments/ddp/train.sh --steps 30 --hidden 32768 --dir ckpt-f > kill.txt 2>&1 &
sleep 12
docker compose -f experiments/ddp/compose.yaml kill rank1
wait
grep -m1 "RuntimeError" kill.txt
~~~

~~~text
[rank0] [rank0]: RuntimeError: [/__w/pytorch/pytorch/third_party/gloo/gloo/transport/tcp/pair.cc:545] Read error [172.26.0.3]:11445: Connection reset by peer. This is typically caused by a remote worker hanging or bugs in the appl...
~~~

Rank 0 failed 1.3 seconds after the kill. The dead container's kernel reset the connection, so rank 0 found out at once. Restart the container and run the same command again: it resumes from the last checkpoint.

~~~bash
docker compose -f experiments/ddp/compose.yaml start rank1
experiments/ddp/train.sh --steps 30 --hidden 32768 --dir ckpt-f
~~~

~~~text
[rank0] {"world": 2, "params": 2162689, "grad_mb": 8.65, "resumed_from": 5, "steps": 30, "step_ms": 922.7, "allreduce_ms": 889.1, "matches_serial": true}
~~~

It resumed from step 5 and finished with exactly the model the serial reference computes. Only the step in progress was lost, because this job checkpoints after every step; most of those first 12 seconds were start-up. A real job checkpoints far less often, because writing a large model's state takes time, and everything since the last checkpoint is lost and redone.

Now cut the link instead: replace the `docker compose kill` line with `experiments/ddp/link.sh 40ms 100mbit 100%`. Every packet is dropped, and both processes stay alive.

~~~text
[rank0] [rank0]: RuntimeError: [/__w/pytorch/pytorch/third_party/gloo/gloo/transport/tcp/unbound_buffer.cc:78] Timed out waiting 20000ms for recv operation to complete
~~~

This time the job ended 22 seconds after the fault: nothing told the ranks that anything was wrong, so each waited out the 20-second timeout from `--timeout`. Without a timeout, a partition hangs the job until someone notices. Restore the link (`link.sh off`, then the 40 ms, 100 Mbit/s shape again) and resume: mine resumed from step 4 and matched the serial model.

| Fault, twice each | Job ended after the fault | Resumed from | Matches serial |
|---|---|---|---|
| Rank 1 killed | 1.3 s, 1.3 s | step 5, step 6 | yes, yes |
| 100% packet loss | 22.1 s, 22.0 s | step 4, step 4 | yes, yes |

The timeout is a trade-off you now have numbers for. Each big-model step takes about a second, so 20 seconds is long enough not to fire on a slow step, and short enough that a partition wastes only 20 seconds of every rank. Set it much shorter and a slow but healthy step kills the job; set it much longer and a partition idles the whole cluster.

**Done when:** the serial-parity and resume checks pass locally, your measured step and all-reduce times are in a table with your predictions next to them, and both failures ended within the timeout and resumed to a model that matches the serial one. My raw results are in [evidence/2026-11-13-training-network](../evidence/2026-11-13-training-network/README.md).

**What this proves, and what it doesn't.** It proves that data-parallel training here computes the same model as one process, that a checkpoint resumes it exactly, and that a dead rank or a dead link fails the job in bounded time instead of hanging. It doesn't measure GPU training: NCCL over NVLink or InfiniBand overlaps communication with computation and uses links a thousand times faster than this one, so only the *shape* of the trade-off carries over. Two containers on one machine aren't two machines, and a job that fails cleanly and resumes from a checkpoint still loses the work since that checkpoint. Elastic training, which continues with fewer ranks, is a different design.
