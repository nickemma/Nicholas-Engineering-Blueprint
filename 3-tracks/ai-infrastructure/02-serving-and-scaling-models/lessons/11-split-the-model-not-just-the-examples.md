# 11 Split the model, not just the examples

> **Optional.** The required path skips this lesson; the module's gate doesn't depend on it.

When a replicated model does not fit, split its weights. For a two-layer MLP `relu(XA)B`, split A by columns and B by corresponding rows. Each rank produces part of the hidden dimension; summing their outputs reconstructs the layer. That sum becomes a collective in a distributed implementation. **Pipeline parallelism** instead puts the first layer on one stage and the second on another: forward activations and backward gradients cross the boundary.

Start in one process so numerical mistakes cannot hide behind network code. This is a decomposition reference, not a claim of distributed tensor/pipeline training.


<!-- file: serve/src/serve/parallel.py -->
~~~python
"""Forward AND backward parity for tensor and staged pipeline decompositions."""

import torch


def compare():
    torch.manual_seed(11)
    x = torch.randn(8, 4)
    a = torch.randn(4, 6, requires_grad=True)
    b = torch.randn(6, 2, requires_grad=True)
    expected = torch.relu(x @ a) @ b
    expected.square().mean().backward()
    # Column-parallel first matrix, row-parallel second matrix.
    aa = [v.detach().clone().requires_grad_() for v in a.chunk(2, dim=1)]
    bb = [v.detach().clone().requires_grad_() for v in b.chunk(2, dim=0)]
    actual = sum(torch.relu(x @ u) @ v for u, v in zip(aa, bb, strict=True))
    actual.square().mean().backward()
    torch.testing.assert_close(actual, expected)
    torch.testing.assert_close(torch.cat([v.grad for v in aa], dim=1), a.grad)
    torch.testing.assert_close(torch.cat([v.grad for v in bb], dim=0), b.grad)
    # Pipeline cut: receiver owns a detached activation. Send its gradient back.
    pa = a.detach().clone().requires_grad_()
    pb = b.detach().clone().requires_grad_()
    for micro in x.chunk(4):
        activation = torch.relu(micro @ pa)
        received = activation.detach().requires_grad_()
        out = received @ pb
        (out.square().mean() / 4).backward()
        activation.backward(received.grad)
    torch.testing.assert_close(pa.grad, a.grad)
    torch.testing.assert_close(pb.grad, b.grad)
    print("tensor and pipeline outputs/gradients match the unsplit reference")


if __name__ == "__main__":
    compare()
~~~

<!-- run: cd serve && uv run python -m serve.parallel -->

The tensor case checks outputs **and both weight gradients**. The pipeline case detaches the activation as a remote receiver would, then explicitly sends its gradient back. Four equal microbatches divide each loss by four to preserve full-batch gradient scale. Without that factor the update is four times too large, although the forward answers still look correct.

Now make the boundary real. Both ranks compute the serial reference, then own just their local shards for the split computation. The tensor case explicitly applies the replicated loss derivative once to each branch. This special two-layer example needs no gradient through the output reduction; a general network needs an autograd-aware collective. The pipeline case sends activations and gradients across processes, with fixed shapes and message order.

<!-- file: serve/src/serve/distributed_split.py -->
~~~python
"""Two ranks, real point-to-point pipeline and tensor-parallel gradients."""

from datetime import timedelta

import torch
import torch.distributed as dist


def main():
    torch.set_num_threads(1)
    dist.init_process_group("gloo", timeout=timedelta(seconds=30))
    try:
        rank = dist.get_rank()
        assert dist.get_world_size() == 2
        torch.manual_seed(11)
        x = torch.randn(8, 4)
        a = torch.randn(4, 6, requires_grad=True)
        b = torch.randn(6, 2, requires_grad=True)
        expected = torch.relu(x @ a) @ b
        expected.square().mean().backward()
        # TP forward output reduction. The replicated loss derivative is
        # identical on both ranks, so each local branch uses it ONCE.
        aa = a.detach().chunk(2, dim=1)[rank].clone().requires_grad_()
        bb = b.detach().chunk(2, dim=0)[rank].clone().requires_grad_()
        local = torch.relu(x @ aa) @ bb
        total = local.detach().clone()
        dist.all_reduce(total)
        torch.testing.assert_close(total, expected)
        local.backward(2 * total / total.numel())
        torch.testing.assert_close(aa.grad, a.grad.chunk(2, dim=1)[rank])
        torch.testing.assert_close(bb.grad, b.grad.chunk(2, dim=0)[rank])
        # PP sequential microbatches. No overlap is claimed by this schedule.
        pa = a.detach().clone().requires_grad_()
        pb = b.detach().clone().requires_grad_()
        for micro in x.chunk(4):
            if rank == 0:
                activation = torch.relu(micro @ pa)
                dist.send(activation.detach().contiguous(), dst=1)
                gradient = torch.empty_like(activation)
                dist.recv(gradient, src=1)
                activation.backward(gradient)
            else:
                received = torch.empty(2, 6)
                dist.recv(received, src=0)
                received.requires_grad_()
                out = received @ pb
                (out.square().mean() / 4).backward()
                dist.send(received.grad.contiguous(), dst=0)
        if rank == 0:
            torch.testing.assert_close(pa.grad, a.grad)
        else:
            torch.testing.assert_close(pb.grad, b.grad)
        dist.barrier()
        if rank == 0:
            print("two-rank tensor and pipeline output/gradient parity passed")
    finally:
        dist.destroy_process_group()


if __name__ == "__main__":
    main()
~~~

<!-- run: cd serve && uv run python -m torch.distributed.run --standalone --nproc-per-node=2 -m serve.distributed_split -->

The assertions compare each rank's weight gradients with the unsplit reference. This is real two-process communication with a sequential pipeline schedule; it does not claim overlap or speedup. Run the same program across the shaped link with lesson 10's launcher arguments to expose communication cost.

Read [Megatron-LM's parallelism guide](https://github.com/NVIDIA/Megatron-LM/blob/main/docs/user-guide/parallelism-guide.md), then `megatron/core/tensor_parallel/layers.py` and `pipeline_parallel/schedules.py` at a recorded commit. Find the column/row parallel linear layers, their gradient collectives, and the schedule that alternates forward/backward work. Draw which tensors cross which boundary. With p stages and m microbatches, a simple fill/drain schedule has ideal bubble fraction (p−1)/(m+p−1), assuming equal stage times and ignoring communication; increasing m trades bubbles for scheduling/activation costs. A sequential two-process exercise proves transport, not overlap.

**Break it:** swap the paired B shards, or omit the backward handoff. Show which parity assertion detects each error. Remove the `/4` and explain the gradient failure. Do not claim Megatron-scale performance from this arithmetic check.
