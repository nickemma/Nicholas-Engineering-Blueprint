# 12 Ray, and where distribution helps

Ray supplies a scheduler, remote tasks, actors and an object store. A task is a function with an object reference as its future; an actor owns mutable state. Neither automatically makes side effects exactly once. Retry a task that writes an external object only when the write is idempotent or uses a commit protocol.

Use a separate optional extra so ordinary CI does not start another runtime. Add this section to `serve/pyproject.toml`, then resolve and retain `uv.lock` in your learner repo:

<!-- append: serve/pyproject.toml -->
~~~toml
[project.optional-dependencies]
ray = ["ray[serve,train]==2.49.2", "protobuf==6.33.5"]
~~~

This is a pinned teaching version, not a claim that it is the latest release. The Protobuf pin is required: the live Serve run failed with Protobuf 7.36.2 because Ray 2.49.2 still reads `FieldDescriptor.label`, which newer Protobuf releases removed ([migration guide](https://protobuf.dev/support/migration/)). Train and Serve both passed after resolving 6.33.5. Retain the resolved lockfile; a successful import does not establish Serve compatibility. Read the matching [Ray tasks and actors documentation](https://docs.ray.io/en/latest/ray-core/actors.html) when upgrading.


<!-- file: serve/src/serve/raylab.py -->
~~~python
"""Tasks, object references and a single-writer actor; run manually with Ray extra."""

import ray


@ray.remote
def square(values):
    return sum(x * x for x in values)


@ray.remote
class Ledger:
    def __init__(self):
        self.seen = set()
        self.total = 0

    def commit(self, batch_id, value):
        if batch_id not in self.seen:
            self.seen.add(batch_id)
            self.total += value
        return self.total


def main():
    ray.init(num_cpus=2, include_dashboard=False)
    try:
        values = ray.put(list(range(100)))
        refs = [square.remote(values) for _ in range(4)]
        ledger = Ledger.remote()
        for i, value in enumerate(ray.get(refs)):
            ray.get(ledger.commit.remote(i, value))
            ray.get(ledger.commit.remote(i, value))  # replay, not double credit
        assert ray.get(ledger.commit.remote(0, 0)) == 4 * sum(x * x for x in range(100))
        print("four task results committed once each")
    finally:
        ray.shutdown()


if __name__ == "__main__":
    main()
~~~

~~~bash
cd serve
uv sync --extra ray
uv run --extra ray python -m serve.raylab
~~~

The object store avoids repeatedly serialising the same input; the ledger actor deduplicates task result commits by batch ID. Its set is in memory: killing the actor loses it. Durable exactly-once accounting still needs a transactional external store. `ray.get` inside a submission loop would serialise the tasks; this example submits all tasks first.

Measure one serial sum versus four tasks for increasing input sizes, including object-store transfer and startup separately. The tiny example should not be expected to win. Bound the number of pending references in a real producer (`ray.wait`) or object-store pressure becomes your new unbounded queue.

Now let [Ray Train](https://docs.ray.io/en/latest/train/getting-started-pytorch.html) own DDP setup. Keep the same serial gradient/update reference, and avoid initialising a second process group inside its workers.

<!-- file: serve/src/serve/raytrain.py -->
~~~python
"""Ray owns the process group; workers own their data shards."""

import ray.train
import torch
from ray.train import ScalingConfig
from ray.train.torch import TorchTrainer, prepare_model


def loop(config):
    torch.set_num_threads(1)
    context = ray.train.get_context()
    rank, world = context.get_world_rank(), context.get_world_size()
    torch.manual_seed(41)
    raw = torch.nn.Linear(8, 1, bias=False)
    model = prepare_model(raw)
    reference = torch.nn.Linear(8, 1, bias=False)
    reference.load_state_dict(raw.state_dict())
    torch.manual_seed(7)
    x = torch.randn(32, 8)
    y = x.sum(dim=1, keepdim=True)
    opt = torch.optim.SGD(model.parameters(), lr=0.01)
    serial = torch.optim.SGD(reference.parameters(), lr=0.01)
    for _ in range(config["steps"]):
        opt.zero_grad()
        loss = (model(x.chunk(world)[rank]) - y.chunk(world)[rank]).square().mean()
        loss.backward()
        opt.step()
        serial.zero_grad()
        (reference(x) - y).square().mean().backward()
        serial.step()
    torch.testing.assert_close(raw.weight, reference.weight, rtol=1e-5, atol=1e-6)
    ray.train.report({"loss": loss.item(), "serial_parity": True})


if __name__ == "__main__":
    result = TorchTrainer(
        loop,
        train_loop_config={"steps": 4},
        scaling_config=ScalingConfig(num_workers=2, use_gpu=False),
    ).fit()
    print(result.metrics)
~~~

~~~bash
cd serve
uv run --extra ray python -m serve.raytrain
~~~

[Ray Serve](https://docs.ray.io/en/latest/serve/index.html) instead manages long-lived serving replicas. Load a model once per replica, not once per request. This minimal endpoint demonstrates replica initialisation and returns its parameter count; it is not an alternative language-model API.

<!-- file: serve/src/serve/rayserve.py -->
~~~python
"""One model initialisation per Serve replica; test control-plane semantics."""

from ray import serve

from serve.tiny import Shape, Tiny


@serve.deployment(num_replicas=1, ray_actor_options={"num_cpus": 1})
class Decoder:
    def __init__(self):
        import torch

        torch.set_num_threads(1)
        torch.manual_seed(41)
        self.model = Tiny(Shape()).eval()

    async def __call__(self, request):
        # This teaching model is random, not the generation API from step 4.
        return {"ready": True, "parameters": sum(p.numel() for p in self.model.parameters())}


app = Decoder.bind()
~~~

~~~bash
cd serve
uv run --extra ray serve run serve.rayserve:app
# Another terminal:
curl -f http://127.0.0.1:8000/
~~~

Stop Serve with Ctrl-C after recording the result. Use Serve as an alternative control plane in a separate experiment; keep Switchyard's auth and token admission in front of a real model deployment. The random teaching model cannot meet the quality gate.

**Break it:** commit the same task result twice with deduplication removed; then kill/recreate the actor and repeat. Explain the difference between task retries and durable commit semantics. Capture the Ray commands and versions in the report; Ray execution is manual and is not part of the CPU CI claim below.
