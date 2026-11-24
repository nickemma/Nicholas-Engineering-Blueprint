# 01 What a model server does

## What this step teaches

- What actually happens between a prompt and a stream of words.
- **Prefill** and **decode**, two different workloads inside one request.
- The **KV cache**, the trick that makes serving affordable, and what it costs.

A language model does one thing: given a sequence of **tokens** (word pieces, as whole numbers), it scores every possible next token. Everything else is a loop. To generate text, you pick a token, add it to the sequence, and ask again.

That loop is what you're serving, so build it small enough to read. This model is never trained. Timing and memory depend on its shape and not on what its weights say, so random weights show everything this step needs. Set up a new project next to `lab`:

<!-- file: serve/pyproject.toml -->
~~~toml
[project]
name = "serve"
version = "0.1.0"
description = "Serve a language model on Switchyard"
requires-python = ">=3.12"
dependencies = [
    "numpy>=2",
    "torch>=2.0",
]

[dependency-groups]
dev = [
    "pytest>=8",
    "ruff>=0.8",
]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/serve"]

[tool.uv.sources]
torch = { index = "pytorch-cpu" }

[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true

[tool.pytest.ini_options]
addopts = "--import-mode=importlib"

[tool.ruff]
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP"]
~~~

<!-- file: serve/.python-version -->
~~~text
3.12
~~~

## A transformer, in one file

The part to understand is **attention**. Each token makes three vectors from itself, each by a matrix multiply (the [linear algebra guide](../../../../math/03-linear-algebra/README.md) again): a **query** (what am I looking for?), a **key** (what do I offer?), and a **value** (what do I pass on?). A token's query is dotted with the key of every token before it. The scores become weights, and the token's output is the weighted sum of those values.

So every token looks at every earlier token. A sequence of *n* tokens costs *n*² dot products. Remember that.

<!-- file: serve/src/serve/tiny.py -->
~~~python
"""A tiny transformer, small enough to read, with a KV cache you can turn off.

It's never trained. Timing and memory depend on the model's shape, not on
what its weights say, so random weights show everything this step needs.
"""

from dataclasses import dataclass

import torch
from torch import Tensor, nn


@dataclass(frozen=True)
class Shape:
    vocab: int = 2048
    context: int = 2048  # the longest sequence it can handle
    width: int = 256  # numbers per token
    heads: int = 8
    layers: int = 6


type Cache = list[tuple[Tensor, Tensor] | None]


class Attention(nn.Module):
    """Each token looks back at those before it, and takes a weighted sum."""

    def __init__(self, shape: Shape):
        super().__init__()
        self.heads = shape.heads
        self.head_width = shape.width // shape.heads
        self.query = nn.Linear(shape.width, shape.width, bias=False)
        self.key = nn.Linear(shape.width, shape.width, bias=False)
        self.value = nn.Linear(shape.width, shape.width, bias=False)
        self.out = nn.Linear(shape.width, shape.width, bias=False)

    def split(self, x: Tensor) -> Tensor:
        batch, length, _ = x.shape
        return x.view(batch, length, self.heads, self.head_width).transpose(1, 2)

    def forward(
        self, x: Tensor, past: tuple[Tensor, Tensor] | None
    ) -> tuple[Tensor, tuple[Tensor, Tensor]]:
        q, k, v = self.split(self.query(x)), self.split(self.key(x)), self.split(self.value(x))
        if past is not None:  # the keys and values of every earlier token
            k = torch.cat([past[0], k], dim=2)
            v = torch.cat([past[1], v], dim=2)
        scores = q @ k.transpose(-2, -1) / self.head_width**0.5
        new, total = x.shape[1], k.shape[2]
        allowed = torch.ones(new, total, dtype=torch.bool).tril(total - new)
        scores = scores.masked_fill(~allowed, float("-inf"))
        mixed = (scores.softmax(dim=-1) @ v).transpose(1, 2).flatten(2)
        return self.out(mixed), (k, v)


class Block(nn.Module):
    def __init__(self, shape: Shape):
        super().__init__()
        self.norm1 = nn.LayerNorm(shape.width)
        self.attention = Attention(shape)
        self.norm2 = nn.LayerNorm(shape.width)
        self.mlp = nn.Sequential(
            nn.Linear(shape.width, 4 * shape.width),
            nn.GELU(),
            nn.Linear(4 * shape.width, shape.width),
        )

    def forward(self, x: Tensor, past):
        mixed, present = self.attention(self.norm1(x), past)
        x = x + mixed
        return x + self.mlp(self.norm2(x)), present


class Tiny(nn.Module):
    def __init__(self, shape: Shape = Shape()):  # noqa: B008
        super().__init__()
        self.shape = shape
        self.tokens = nn.Embedding(shape.vocab, shape.width)
        self.positions = nn.Embedding(shape.context, shape.width)
        self.blocks = nn.ModuleList(Block(shape) for _ in range(shape.layers))
        self.norm = nn.LayerNorm(shape.width)
        self.head = nn.Linear(shape.width, shape.vocab, bias=False)

    def forward(self, ids: Tensor, cache: Cache | None = None) -> tuple[Tensor, Cache]:
        """Return next-token scores for each position, and the updated cache."""
        cache = cache or [None] * self.shape.layers
        start = 0 if cache[0] is None else cache[0][0].shape[2]
        positions = torch.arange(start, start + ids.shape[1])
        x = self.tokens(ids) + self.positions(positions)
        present: Cache = []
        for block, past in zip(self.blocks, cache, strict=True):
            x, kept = block(x, past)
            present.append(kept)
        return self.head(self.norm(x)), present


@torch.inference_mode()
def generate(model: Tiny, prompt: list[int], new_tokens: int, use_cache: bool = True) -> list[int]:
    """Greedily extend prompt. With the cache, each step feeds in one token."""
    ids = list(prompt)
    logits, cache = model(torch.tensor([ids]))  # prefill: the whole prompt
    for _ in range(new_tokens):
        next_id = int(logits[0, -1].argmax())
        ids.append(next_id)
        if use_cache:  # decode: only the newest token
            logits, cache = model(torch.tensor([[next_id]]), cache)
        else:  # start again from the first token
            logits, _ = model(torch.tensor([ids]))
    return ids


def cache_bytes(shape: Shape, length: int, value_bytes: int = 4) -> int:
    """Keys and values: two tensors per layer, each length × width numbers."""
    return 2 * shape.layers * length * shape.width * value_bytes
~~~

The mask, `allowed`, stops a token seeing what comes after it. `past` is the important argument: it holds the keys and values of earlier tokens.

<!-- file: serve/tests/test_tiny.py -->
~~~python
import torch

from serve.tiny import Shape, Tiny, cache_bytes, generate

SMALL = Shape(vocab=64, context=128, width=32, heads=4, layers=2)


def model() -> Tiny:
    torch.manual_seed(1)
    return Tiny(SMALL).eval()


def test_the_cache_changes_nothing_about_the_answer():
    m, prompt = model(), [1, 2, 3, 4, 5]
    assert generate(m, prompt, 30, use_cache=True) == generate(m, prompt, 30, use_cache=False)


def test_cached_logits_match_a_full_pass():
    m = model()
    ids = torch.tensor([[3, 1, 4, 1, 5, 9]])
    with torch.inference_mode():
        full, _ = m(ids)
        logits, cache = m(ids[:, :4])
        for i in range(4, 6):
            logits, cache = m(ids[:, i : i + 1], cache)
    assert torch.allclose(logits[0, -1], full[0, -1], atol=1e-4)


def test_a_token_cannot_see_the_future():
    m = model()
    a, b = torch.tensor([[1, 2, 3, 4]]), torch.tensor([[1, 2, 3, 9]])
    with torch.inference_mode():
        la, _ = m(a)
        lb, _ = m(b)
    assert torch.allclose(la[0, :3], lb[0, :3])
    assert not torch.allclose(la[0, 3], lb[0, 3])


def test_the_cache_grows_by_one_token_per_step():
    m = model()
    with torch.inference_mode():
        _, cache = m(torch.tensor([[1, 2, 3]]))
        _, cache = m(torch.tensor([[4]]), cache)
    keys, values = cache[0]
    assert keys.shape[2] == values.shape[2] == 4


def test_cache_bytes_matches_the_real_tensors():
    m = model()
    with torch.inference_mode():
        _, cache = m(torch.tensor([list(range(10))]))
    real = sum(t.numel() * t.element_size() for pair in cache for t in pair)
    assert real == cache_bytes(SMALL, 10)
~~~

<!-- run: cd serve && uv sync -q && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

~~~bash
cd serve
uv sync
uv run pytest -q
~~~

## The KV cache

Look at `generate`. The naive loop feeds the whole sequence through the model for each new token. But when you add a token, every earlier token's keys and values are exactly what they were: a token can't see what comes after it, so nothing new changes them. Recomputing them is pure waste.

The **KV cache** keeps them. After the first pass, each step feeds in **only the newest token**, and it attends to the stored keys and values. That splits a request into two phases:

- **Prefill:** the whole prompt goes through at once. Each of *n* tokens attends to those before it. This work is parallel, compute-heavy and grows at least with *n*².
- **Decode:** one token at a time, each attending to everything before it. Each step can only start when the last one has finished.

They're different workloads, and users feel them differently. **Prefill contributes to time to first token (TTFT), alongside queueing and transport:** how long you stare at nothing. **Decode sets inter-token latency:** how fast the words appear.

The first test is the one that matters: `generate` must return the same tokens with the cache on and off. An optimisation that changes the answer is a bug.

## Measure it

<!-- file: serve/src/serve/kvbench.py -->
~~~python
"""Time prefill and decode on one CPU core, with and without the KV cache."""

import statistics
import time

import torch

from serve.tiny import Shape, Tiny, cache_bytes, generate


def timed(work, repeats: int = 7) -> float:
    samples = []
    for _ in range(repeats):
        start = time.perf_counter()
        work()
        samples.append(time.perf_counter() - start)
    return statistics.median(samples)


@torch.inference_mode()
def main() -> None:
    torch.set_num_threads(1)
    torch.manual_seed(1)
    shape = Shape()
    model = Tiny(shape).eval()
    weights = sum(p.numel() for p in model.parameters())
    print(f"{weights / 1e6:.1f} million weights, {weights * 4 / 1e6:.0f} MB at 4 bytes each\n")

    print(f"{'prompt':>7} {'prefill ms':>11} {'decode ms':>10} {'cache MB':>9} {'ratio':>6}")
    for length in (16, 64, 256, 1024):
        ids = torch.randint(0, shape.vocab, (1, length))
        next_id = torch.tensor([[1]])
        _, cache = model(ids)
        prefill = timed(lambda ids=ids: model(ids))
        decode = timed(lambda c=cache, n=next_id: model(n, c), repeats=21)
        mb = cache_bytes(shape, length) / 1e6
        print(
            f"{length:7d} {prefill * 1000:11.1f} {decode * 1000:10.2f} {mb:9.1f} "
            f"{prefill / decode:6.0f}"
        )

    print(f"\n{'prompt + new':>13} {'cached s':>9} {'uncached s':>11} {'ratio':>6}")
    for prompt, new in ((64, 64), (64, 256), (64, 512)):
        ids = torch.randint(0, shape.vocab, (prompt,)).tolist()
        cached = timed(lambda ids=ids, new=new: generate(model, ids, new), repeats=3)
        slow = timed(lambda ids=ids, new=new: generate(model, ids, new, False), repeats=1)
        print(f"{f'{prompt} + {new}':>13} {cached:9.2f} {slow:11.2f} {slow / cached:6.1f}")


if __name__ == "__main__":
    main()
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . -->

One core, so that the numbers compare cleanly:

~~~bash
uv run python -m serve.kvbench
~~~

~~~text
6.3 million weights, 25 MB at 4 bytes each

 prompt  prefill ms  decode ms  cache MB  ratio
     16         8.6       4.49       0.2      2
     64        17.5       4.53       0.8      4
    256        91.9       5.57       3.1     17
   1024      1106.6      10.87      12.6    102

 prompt + new  cached s  uncached s  ratio
      64 + 64      0.36        1.55    4.4
     64 + 256      1.38       13.28    9.6
     64 + 512      3.11       68.79   22.1
~~~

Three runs agreed to within about 10%. Read the first table across and down:

- **Prefill grows faster than the prompt.** Four times the prompt, from 256 to 1,024 tokens, takes twelve times as long, on its way to the *n*² of attention. Doubling a prompt doesn't double your wait.
- **Decode grows far more slowly.** At 1,024 tokens, a decode step takes 11 ms, against 1,107 ms for prefill. That's about 100 times less, because it pushes one token through the model, not a thousand. It's still more than double the 4.5 ms at 16 tokens, since that one token attends to everything stored.
- **The cache is memory, not free.** It holds two tensors per layer per token. For this small model, 12.6 MB at 1,024 tokens. The formula matches the real tensors exactly, which a test checks. A real model has more layers and is far wider, and this is the number that decides how many requests fit on a GPU at once.

The second table is why this matters. To generate 512 tokens, the cache takes 3.1 seconds, and going without takes 69. That's 22 times slower, and the gap widens with length, because the uncached loop is doing *n*² work *n* times over. This is why production autoregressive servers generally cache keys and values.

## Break it

Here's a bug that a person, or an AI assistant, could easily write. In `forward`, the position of the new token has to continue from where the cache left off. Change that line to always start from zero:

~~~python
start = 0
~~~

~~~bash
uv run pytest -q
~~~

~~~text
=========================== short test summary info ============================
FAILED tests/test_tiny.py::test_the_cache_changes_nothing_about_the_answer - ...
FAILED tests/test_tiny.py::test_cached_logits_match_a_full_pass - assert False
2 failed, 3 passed in 1.87s
~~~

Nothing crashes. The model runs at full speed and streams out words, each one treated as if it were the first token of the sequence. In production you'd see quality drop slowly, with no error at all. The comparison of cached against uncached output catches it in a second. Put the line back.

**Explain it:** Why can a token's keys and values be reused? Why does prefill grow faster than the prompt? Which phase sets TTFT, and which sets inter-token latency? Your users paste in long documents and get short answers. Which phase dominates your bill? What does the KV cache cost, and what limit does that put on a GPU? Why must a test compare cached with uncached output?

**Read.** Jay Alammar, [*The Illustrated Transformer*](https://jalammar.github.io/illustrated-transformer/). Andrej Karpathy, [*Let's build GPT*](https://www.youtube.com/watch?v=kCc8FmEb1nY).

---
