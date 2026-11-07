# Phase 8 teaching: AI infrastructure

At the end of Phase 7, Runway measures itself, and a model runs inside it, predicting how long jobs will take. That model is small: it answers in a millisecond, and it fits on one CPU. This phase is about the other kind, the ones that AI products run on, where one request holds a slice of an expensive machine for many seconds, and the machine costs more per hour than everything else in Runway put together.

This phase asks what it takes to run that infrastructure: serving models reliably and cheaply, training across many devices, and keeping GPUs busy.

**The goal:** an inference platform on Runway, for an open-weight language model, and a clear idea of how training splits a model across machines. Every claim comes with the experiment behind it, in the way Phase 7 taught.

**Time:** about 8 weeks. **Before you start:** finish Phases 0–7, the [Performance Bridge](../perf-bridge/README.md), the [Networking Bridge](../network-bridge/README.md), and the [maths track](../../math/README.md)'s [queueing](../../math/01-queueing/README.md) and [linear algebra](../../math/03-linear-algebra/README.md) guides. This phase leans on all of them.

## How this guide works

The same as Phase 7: type everything, file by file, and run the checks at the end of each step. The Python work is in a new project called `serve`, next to `lab`. Your numbers will differ from mine; compare the ratios and the shape.

**Hardware:** steps 1–12 use CPUs; live deployment needs Docker and kind. Step 13 needs an NVIDIA GPU. Historical measurements below came from the earlier scratch experiments; cluster and GPU commands are learner-run procedures, with no invented outputs. The CPU correctness checks replay in CI. Start in a fresh directory for this phase, beside your existing Runway checkout. The gateway package is integrated into Runway in step 4; the Python lab is independent.

| Step | What you add |
|---|---|
| 1 | What a model server does: tokens, prefill, decode and the KV cache |
| 2 | A real model, streaming, and where it saturates |
| 3 | Batching and concurrency |
| 4 | The gateway on Runway: auth, limits in tokens, an admission queue, cancellation |
| 5 | Observability, and SLOs on time to first token |
| 6 | Kubernetes: slow readiness, scaling on queue depth, cold starts |
| 7 | Supply chain: signed images and signed weights |
| 8 | A performance and cost benchmark, with quality checks |
| 9 | Failure and recovery |
| 10 | Data parallelism across a real network link |
| 11 | Tensor and pipeline parallelism, and how Megatron-LM splits a model |
| 12 | Ray |
| 13 | CUDA and vLLM on a GPU |
| 14 | The report |

---

## Step 1: What a model server does

### What this step teaches

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
description = "Serve a language model on Runway"
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

### A transformer, in one file

The part to understand is **attention**. Each token makes three vectors from itself, each by a matrix multiply (the [linear algebra guide](../../math/03-linear-algebra/README.md) again): a **query** (what am I looking for?), a **key** (what do I offer?), and a **value** (what do I pass on?). A token's query is dotted with the key of every token before it. The scores become weights, and the token's output is the weighted sum of those values.

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

### The KV cache

Look at `generate`. The naive loop feeds the whole sequence through the model for each new token. But when you add a token, every earlier token's keys and values are exactly what they were: a token can't see what comes after it, so nothing new changes them. Recomputing them is pure waste.

The **KV cache** keeps them. After the first pass, each step feeds in **only the newest token**, and it attends to the stored keys and values. That splits a request into two phases:

- **Prefill:** the whole prompt goes through at once. Each of *n* tokens attends to those before it. This work is parallel, compute-heavy and grows at least with *n*².
- **Decode:** one token at a time, each attending to everything before it. Each step can only start when the last one has finished.

They're different workloads, and users feel them differently. **Prefill contributes to time to first token (TTFT), alongside queueing and transport:** how long you stare at nothing. **Decode sets inter-token latency:** how fast the words appear.

The first test is the one that matters: `generate` must return the same tokens with the cache on and off. An optimisation that changes the answer is a bug.

### Measure it

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

### Break it

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
## Step 2: A real model, and honest streaming measurements

The tiny model explains the work; it cannot answer a useful question. Run a small instruction model with llama.cpp. Keep the model license beside the weights. Fetch the Qwen2.5-0.5B-Instruct GGUF `q4_k_m` file from [its publisher](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/tree/main); record the repository revision and verify the bytes before starting. The historical lab used this checksum:

~~~text
74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db  qwen2.5-0.5b-instruct-q4_k_m.gguf
~~~

A checksum detects a different file. Step 7 adds publisher identity. This image digest is the historical CPU server; inspect its architecture and vulnerability scan before deploying it. These are manual Docker commands, outside CI.


<!-- file: experiments/llm/server.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
threads=${1:-4}
slots=${2:-1}
: "${MODELS:?set MODELS to the directory containing the GGUF file}"
image=ghcr.io/ggml-org/llama.cpp@sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b
# Stop only the container owned by this lab.
docker rm -f runway-phase8-llm >/dev/null 2>&1 || true
docker run -d --name runway-phase8-llm -p 127.0.0.1:8000:8080 \
  -v "$MODELS:/models:ro" "$image" \
  -m /models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  -c "$((4096 * slots))" -t "$threads" --parallel "$slots" --metrics --host 0.0.0.0
for attempt in $(seq 1 120); do
  if curl -fsS http://127.0.0.1:8000/health >/dev/null; then exit 0; fi
  sleep 1
done
docker logs runway-phase8-llm >&2
exit 1
~~~

~~~bash
export MODELS="$PWD/models"
mkdir -p "$MODELS"
# Place the verified model file and its license here first.
bash experiments/llm/server.sh 4 1
~~~

Read [llama.cpp's server contract](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md). A streaming response contains role events, text deltas, usage, then `[DONE]`. A text delta is **not necessarily one token**. Measure chunk gaps and name them honestly; true inter-token latency requires server token timestamps or one-token-per-event evidence. Count output tokens from usage, never from whitespace. An EOF without `[DONE]` is a failed request, even if some text arrived.


<!-- file: serve/src/serve/stream.py -->
~~~python
"""Measure SSE text chunks and authoritative token usage separately."""

import http.client
import json
import os
import time
from dataclasses import asdict, dataclass, field
from urllib.parse import urlsplit


@dataclass
class Timing:
    ttft: float | None = None
    gaps: list[float] = field(default_factory=list)
    chunks: int = 0
    output_tokens: int | None = None
    total: float = 0
    error: str = ""
    text: str = ""


def chat(url: str, prompt: str, max_tokens: int = 64, timeout: float = 60) -> Timing:
    parts = urlsplit(url)
    if parts.scheme != "http":
        raise ValueError("lab client supports http only; use the local tunnel")
    conn = http.client.HTTPConnection(parts.hostname, parts.port, timeout=timeout)
    result = Timing()
    start = last = time.perf_counter()
    done = False
    try:
        body = json.dumps(
            {
                "messages": [{"role": "user", "content": prompt}],
                "stream": True,
                "stream_options": {"include_usage": True},
                "max_tokens": max_tokens,
                "temperature": 0,
                "cache_prompt": False,
            }
        )
        headers = {"Content-Type": "application/json"}
        if os.environ.get("RUNWAY_TOKEN"):
            headers["Authorization"] = "Bearer " + os.environ["RUNWAY_TOKEN"]
        conn.request("POST", "/v1/chat/completions", body, headers)
        response = conn.getresponse()
        if response.status != 200:
            raise ValueError(f"status {response.status}")
        for line in response:
            if not line.startswith(b"data:"):
                continue
            data = line[5:].strip()
            if data == b"[DONE]":
                done = True
                break
            event = json.loads(data)
            if event.get("usage"):
                result.output_tokens = event["usage"]["completion_tokens"]
            choices = event.get("choices") or []
            text = choices[0].get("delta", {}).get("content") if choices else None
            if not text:
                continue
            now = time.perf_counter()
            if result.ttft is None:
                result.ttft = now - start
            else:
                result.gaps.append(now - last)
            last = now
            result.chunks += 1
            result.text += text
        if not done or result.ttft is None:
            raise ValueError("incomplete or empty stream")
    except (OSError, ValueError, KeyError, http.client.HTTPException) as exc:
        result.error = str(exc)
    finally:
        conn.close()
        result.total = time.perf_counter() - start
    return result


if __name__ == "__main__":
    import sys

    print(json.dumps(asdict(chat(sys.argv[1], "Explain a queue in one sentence."))))
~~~


<!-- file: serve/tests/test_stream.py -->
~~~python
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from serve.stream import chat


class Fake(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.end_headers()
        chunks = [
            b'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n',
            b'data: {"choices":[{"delta":{"content":"two tokens"}}]}\n\n',
            b'data: {"choices":[],"usage":{"completion_tokens":2}}\n\n',
        ]
        if self.path and not self.server.truncate:
            chunks.append(b"data: [DONE]\n\n")
        for chunk in chunks:
            self.wfile.write(chunk)
            self.wfile.flush()

    def log_message(self, *args):
        pass


def test_usage_is_not_chunk_count_and_truncated_stream_is_failure():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
    server.truncate = False
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"http://127.0.0.1:{server.server_port}"
        result = chat(url, "hi")
        assert result.output_tokens == 2 and result.chunks == 1
        assert result.ttft is not None and result.total > 0 and not result.error
        server.truncate = True
        assert chat(url, "hi").error == "incomplete or empty stream"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
~~~

<!-- run: cd serve && uv run pytest -q tests/test_stream.py -->

~~~bash
cd serve
uv run python -m serve.stream http://127.0.0.1:8000
~~~

Recovered historical measurements: 10, 50, 200 and 800 **words** gave TTFT of 207, 348, 957 and 3,525 ms. The old client reported text-delta gaps of 32.2, 30.5, 30.8 and 34.4 ms; it did not establish that every delta was one token. Those numbers illustrate different prompt and decode costs, not an SLO promise. Repeating one prompt with prefix caching enabled reduced TTFT from 85 to 31 ms: caching can confound a benchmark. The client above disables prompt caching.

**Break it:** remove `[DONE]` from the fake server. Explain why a transport success cannot establish completion. Shut down the real server mid-stream and retain the failed row. Restore it before continuing.

## Step 3: Batching, concurrency and the knee

Static batching admits a group, then waits for its longest output. Continuous batching can admit another request when a slot becomes free. Build a token-tick simulator to isolate that scheduling decision. A tick is an abstract unit: this model predicts neither GPU speed nor real prefill interference.


<!-- file: serve/src/serve/batching.py -->
~~~python
"""Token-tick model: all jobs arrive at zero; no prefill or hardware cost."""


def finish_times(lengths, slots, continuous):
    pending = list(enumerate(lengths))
    active = []
    finished = {}
    tick = 0
    while pending or active:
        if continuous or not active:
            while pending and len(active) < slots:
                active.append(pending.pop(0))
        tick += 1
        next_active = []
        for i, left in active:
            if left == 1:
                finished[i] = tick
            else:
                next_active.append((i, left - 1))
        active = next_active
    return finished


if __name__ == "__main__":
    lengths = [2, 8, 2, 2]
    for continuous in (False, True):
        print(continuous, finish_times(lengths, 2, continuous))
~~~


<!-- file: serve/tests/test_batching.py -->
~~~python
from serve.batching import finish_times


def test_short_requests_can_reuse_a_slot_without_waiting_for_the_long_one():
    assert finish_times([2, 8, 2, 2], 2, False) == {0: 2, 1: 8, 2: 10, 3: 10}
    assert finish_times([2, 8, 2, 2], 2, True) == {0: 2, 2: 4, 3: 6, 1: 8}
~~~

<!-- run: cd serve && uv run pytest -q tests/test_batching.py && uv run python -m serve.batching -->

The short jobs finish at ticks 2, 10 and 10 with static batches, and 2, 4 and 6 with continuous admission. The long job still finishes at tick 8. Real batching amortises reading weights but consumes more KV memory and may increase per-token latency. Concurrency is requests in flight; batch size is work executed together. They are not interchangeable.

Now offer arrivals independently of completion. A closed-loop client slows its arrivals when the server slows, hiding the queue you need to see. This client preselects Poisson arrivals, records dispatch lag when its own thread pool saturates, and keeps every request. Do not publish a server capacity estimate when dispatch lag is material.


<!-- file: serve/src/serve/load.py -->
~~~python
"""Open-loop arrivals: retain every arrival, including client-side overload."""

import argparse
import concurrent.futures
import json
import random
import time
from dataclasses import asdict

from serve.stream import chat


def run(url, rate, n, seed, workers=32):
    if rate <= 0 or n <= 0:
        raise ValueError("positive rate and count required")
    rng = random.Random(seed)
    due = 0.0
    arrivals = []
    for i in range(n):
        due += rng.expovariate(rate)
        prompt = f"Request {rng.getrandbits(64)}: Explain backpressure in two sentences."
        arrivals.append((i, due, prompt))
    start = time.monotonic()

    def one(i, due, prompt):
        lag = time.monotonic() - start - due
        result = asdict(chat(url, prompt))
        result.update(id=i, arrival=due, dispatch_lag=max(0, lag))
        if result["ttft"] is not None:
            result["ttft"] += max(0, lag)
        return result

    rows = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        pending = []
        for i, due, prompt in arrivals:
            time.sleep(max(0, start + due - time.monotonic()))
            pending.append(pool.submit(one, i, due, prompt))
        for future in pending:
            rows.append(future.result())
    return rows


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="http://127.0.0.1:8000")
    p.add_argument("--rate", type=float, required=True)
    p.add_argument("--n", type=int, default=100)
    p.add_argument("--seed", type=int, default=1)
    args = p.parse_args()
    for row in run(args.url, args.rate, args.n, args.seed):
        print(json.dumps(row))
~~~

<!-- run: cd serve && uv run python -m compileall -q src -->

~~~bash
mkdir -p results
cd serve
uv run python -m serve.load --rate 0.2 --n 100 --seed 7 > ../results/slots1-rate02.jsonl
~~~

First measure low-load mean service time S, then try arrival rates 0.3/S, 0.6/S, 0.8/S and 1.1/S. Bound each run and retain timeout rows. Repeat with 1, 2 and 4 server slots, interleaving their order across at least five runs. Keep total context per slot fixed, as `server.sh` does. Record process RSS and model settings with each run. Warm up separately; discard by arrival ID, never by completion order. Use the [queueing guide](../../math/01-queueing/README.md) to compare observed queue length L with arrival rate times time in system. M/M/1 is a reference, not an exact model of a batched server with variable prompts.

The old knee experiments include clock-contaminated and interrupted captures. They do **not** establish a publishable saturation point. Re-run the grid; do not fill in the curve from the utilisation formula. The historical thread sweep also shows why cores are not free: 8 threads improved prefill versus 4, but 16 made both prefill and chunk gaps worse.

**Break it:** run beyond capacity. Check failures, dispatch lag, TTFT, memory and queue depth together. Lower the rate and verify the queue drains. Explain why unlimited queues change overload into arbitrarily late answers.

## Step 4: Put an admission boundary on Runway

A model server is an expensive dependency. Runway authenticates before allocating its capacity. Keep Phase 6's JWT issuer, audience, expiry and tenant checks; never trust an `X-Tenant` header. The serving boundary below accepts a verified identity callback so its logic can be tested without replaying the database and broker phases.

Create a separate lab module. When integrating, copy `internal/inference` into your existing `runway` module; keep its existing `go.mod`.

<!-- file: gateway/go.mod -->
~~~text
module phase8gateway

go 1.26
~~~

Reserve prompt tokens plus the maximum output, using the **same chat template and tokenizer** as generation. Counting words is not a token limit. A reservation survives cancellation and backend failure, which is conservative but stops a retry from evading the budget. This lab uses a per-process fixed-minute budget; a multi-replica deployment must use Phase 6's atomic Redis limiter, or explicitly partition budgets. A minute boundary allows a double burst. Production billing would reconcile actual usage in a durable ledger.


<!-- file: gateway/internal/inference/gateway.go -->
~~~go
// Package inference implements bounded admission for an authenticated Runway route.
package inference

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

type Identity func(*http.Request) (string, bool)
type Tokenizer func(context.Context, json.RawMessage) (int, error)

// Reservation atomically reserves prompt plus maximum output for one verified tenant.
type Reservation func(context.Context, string, int) (bool, error)

type Gateway struct {
	reserve  Reservation
	identity Identity
	tokenize Tokenizer
	url      string
	client   *http.Client
	active   chan struct{}
	admitted chan struct{}
	mu       sync.Mutex
	usage    map[string]int
	minute   int64
	budget   int
	requests atomic.Int64
	failures atomic.Int64
	first    atomic.Int64
	fast     atomic.Int64
}

func New(url string, identity Identity, tokenize Tokenizer, slots, queue, budget int) *Gateway {
	if slots < 1 || queue < 0 || budget < 1 {
		panic("invalid capacity")
	}
	g := &Gateway{identity: identity, tokenize: tokenize, url: url,
		client: &http.Client{}, active: make(chan struct{}, slots),
		admitted: make(chan struct{}, slots+queue), usage: map[string]int{}, budget: budget}
	g.reserve = func(_ context.Context, tenant string, tokens int) (bool, error) { return g.charge(tenant, tokens), nil }
	return g
}

// UseReservation configures shared accounting before serving any requests.
// Failure must be returned, not silently replaced with a per-process budget.
func (g *Gateway) UseReservation(reserve Reservation) {
	if reserve == nil {
		panic("nil reservation")
	}
	g.reserve = reserve
}

// charge reserves prompt + maximum output before admission. Conservatively keep
// reservations on failure/cancellation so retries cannot evade the token budget.
func (g *Gateway) charge(tenant string, tokens int) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	minute := time.Now().Unix() / 60
	if g.minute != minute {
		g.usage = map[string]int{}
		g.minute = minute
	}
	if tokens > g.budget-g.usage[tenant] {
		return false
	}
	g.usage[tenant] += tokens
	return true
}

func (g *Gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	tenant, ok := g.identity(r)
	if !ok || tenant == "" {
		http.Error(w, "unauthorized", 401)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	g.requests.Add(1)
	start := time.Now()
	// The deadline includes waiting, tokenization and the full streamed answer.
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if err != nil {
		http.Error(w, "body too large", 413)
		return
	}
	var input struct {
		Messages  json.RawMessage `json:"messages"`
		MaxTokens int             `json:"max_tokens"`
		Stream    bool            `json:"stream"`
	}
	if json.Unmarshal(body, &input) != nil || input.MaxTokens < 1 || input.MaxTokens > 512 || !input.Stream {
		http.Error(w, "stream=true and max_tokens 1..512 required", 400)
		return
	}
	// Bound tokenizer work as well as generation. This is bounded admission,
	// not a strict FIFO queue: Go's semaphore does not promise tenant fairness.
	select {
	case g.admitted <- struct{}{}:
	default:
		w.Header().Set("Retry-After", "1")
		http.Error(w, "overloaded", 503)
		return
	}
	defer func() { <-g.admitted }()
	select {
	case g.active <- struct{}{}:
	case <-ctx.Done():
		http.Error(w, "queue deadline", 504)
		return
	}
	defer func() { <-g.active }()
	n, err := g.tokenize(ctx, input.Messages)
	if err != nil || n < 1 || n+input.MaxTokens > 4096 {
		http.Error(w, "invalid context", 400)
		return
	}
	allowed, reserveErr := g.reserve(ctx, tenant, n+input.MaxTokens)
	if reserveErr != nil {
		http.Error(w, "budget unavailable", 503)
		return
	}
	if !allowed {
		w.Header().Set("Retry-After", "60")
		http.Error(w, "token budget", 429)
		return
	}
	// Build a fresh allowlisted request: callers cannot inject a model path,
	// tools, backend URLs or a server-side chat template.
	payload, _ := json.Marshal(map[string]any{"messages": input.Messages,
		"max_tokens": input.MaxTokens, "stream": true, "temperature": 0, "cache_prompt": false, "stream_options": map[string]bool{"include_usage": true}})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.url+"/v1/chat/completions", bytes.NewReader(payload))
	if err != nil {
		http.Error(w, "backend configuration", 502)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	// Request context cancels the upstream HTTP request on disconnect/deadline.
	res, err := g.client.Do(req)
	if err != nil {
		g.failures.Add(1)
		http.Error(w, "backend unavailable", 502)
		return
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		g.failures.Add(1)
		http.Error(w, "backend rejected", 502)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	buf := make([]byte, 4096)
	recorded := false
	for {
		n, readErr := res.Body.Read(buf)
		if n > 0 {
			// HTTP streaming requires a write deadline too: an upstream deadline
			// alone cannot unblock a write to a client that stopped reading.
			_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(5 * time.Second))
			if _, err := w.Write(buf[:n]); err != nil {
				g.failures.Add(1)
				return
			}
			if err := http.NewResponseController(w).Flush(); err != nil {
				g.failures.Add(1)
				return
			}
			if !recorded {
				recorded = true
				g.first.Add(1)
				if time.Since(start) <= time.Second {
					g.fast.Add(1)
				}
			}
		}
		if readErr != nil {
			if readErr != io.EOF {
				g.failures.Add(1)
			}
			return
		}
	}
}

// These fixed label-free metrics cannot leak tenant IDs or prompt contents.
// First-byte is a transport diagnostic, NOT first-content-token latency.
func (g *Gateway) Metrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "inference_admitted %d\ninference_active %d\ninference_requests_total %d\ninference_transport_failures_total %d\ninference_first_byte_total %d\ninference_first_byte_fast_total %d\n",
		len(g.admitted), len(g.active), g.requests.Load(), g.failures.Load(), g.first.Load(), g.fast.Load())
}
~~~


<!-- file: gateway/internal/inference/tokenizer.go -->
~~~go
package inference

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// LlamaTokenizer uses the pinned server's chat template and tokenizer together.
// Tokenizing raw user text would omit role markers and template overhead.
func LlamaTokenizer(url string) Tokenizer {
	client := &http.Client{}
	return func(ctx context.Context, messages json.RawMessage) (int, error) {
		post := func(path string, input, output any) error {
			body, err := json.Marshal(input)
			if err != nil {
				return err
			}
			req, err := http.NewRequestWithContext(ctx, "POST", url+path, bytes.NewReader(body))
			if err != nil {
				return err
			}
			req.Header.Set("Content-Type", "application/json")
			res, err := client.Do(req)
			if err != nil {
				return err
			}
			defer res.Body.Close()
			if res.StatusCode != 200 {
				return fmt.Errorf("tokenizer status %d", res.StatusCode)
			}
			return json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(output)
		}
		var formatted struct {
			Prompt string `json:"prompt"`
		}
		if err := post("/apply-template", map[string]any{"messages": messages, "add_generation_prompt": true}, &formatted); err != nil {
			return 0, err
		}
		var result struct {
			Tokens []int `json:"tokens"`
		}
		err := post("/tokenize", map[string]any{"content": formatted.Prompt, "add_special": true}, &result)
		return len(result.Tokens), err
	}
}
~~~


<!-- file: gateway/internal/inference/gateway_test.go -->
~~~go
package inference

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const request = `{"messages":[{"role":"user","content":"hi"}],"max_tokens":8,"stream":true}`

func identity(r *http.Request) (string, bool)              { return "acme", r.Header.Get("Authorization") == "test" }
func tokens(context.Context, json.RawMessage) (int, error) { return 4, nil }
func call(g *Gateway, authorized bool) *httptest.ResponseRecorder {
	r := httptest.NewRequest("POST", "/v1/chat/completions", strings.NewReader(request))
	if authorized {
		r.Header.Set("Authorization", "test")
	}
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	return w
}
func TestAuthAndTokenReservations(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer backend.Close()
	g := New(backend.URL, identity, tokens, 1, 0, 12)
	if got := call(g, false).Code; got != 401 {
		t.Fatal(got)
	}
	if got := call(g, true).Code; got != 200 {
		t.Fatal(got)
	}
	if got := call(g, true).Code; got != 429 {
		t.Fatal(got)
	}
}
func TestDisconnectCancelsUpstreamAndReleasesSlot(t *testing.T) {
	started := make(chan struct{})
	cancelled := make(chan struct{})
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		close(started)
		<-r.Context().Done()
		close(cancelled)
	}))
	defer backend.Close()
	g := New(backend.URL, identity, tokens, 1, 0, 100)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r := httptest.NewRequest("POST", "/", strings.NewReader(request)).WithContext(ctx)
	r.Header.Set("Authorization", "test")
	done := make(chan struct{})
	go func() { g.ServeHTTP(httptest.NewRecorder(), r); close(done) }()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("backend not reached")
	}
	if got := call(g, true).Code; got != 503 {
		t.Fatal(got)
	}
	cancel()
	select {
	case <-cancelled:
	case <-time.After(2 * time.Second):
		t.Fatal("cancellation lost")
	}
	<-done
	if len(g.active) != 0 || len(g.admitted) != 0 {
		t.Fatal("capacity leaked")
	}
}
~~~

<!-- file: gateway/internal/inference/reservation_test.go -->
~~~go
package inference

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func TestSharedReservationAcrossGatewaysAndFailClosed(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("data: [DONE]\n\n")) }))
	defer backend.Close()
	var mu sync.Mutex
	remaining := 12
	reserve := func(context.Context, string, int) (bool, error) {
		mu.Lock()
		defer mu.Unlock()
		if remaining < 12 {
			return false, nil
		}
		remaining -= 12
		return true, nil
	}
	a := New(backend.URL, identity, tokens, 1, 0, 100)
	b := New(backend.URL, identity, tokens, 1, 0, 100)
	a.UseReservation(reserve)
	b.UseReservation(reserve)
	if got := call(a, true).Code; got != 200 {
		t.Fatal(got)
	}
	if got := call(b, true).Code; got != 429 {
		t.Fatal(got)
	}
	b.UseReservation(func(context.Context, string, int) (bool, error) { return false, errors.New("unavailable") })
	if got := call(b, true).Code; got != 503 {
		t.Fatal(got)
	}
}
~~~

<!-- run: cd gateway && gofmt -w internal && go vet ./... && go test -race -timeout=30s -count=1 ./... -->

Mount the package on the Phase 6 API's mux where its verifier `v` and logger already exist. This integration fragment belongs in your existing startup function (it is not a second standalone program):

~~~go
modelURL := "http://llm:8080"
g := inference.New(modelURL, func(r *http.Request) (string, bool) {
    c, ok := auth.FromContext(r.Context())
    return c.Tenant, ok
}, inference.LlamaTokenizer(modelURL), 1, 8, 8192)
mux.Handle("/v1/chat/completions", auth.Require(v, logger, g))
mux.HandleFunc("/internal/inference/metrics", g.Metrics)
~~~

Import `runway/internal/inference` and `runway/internal/auth`. Put metrics on the existing internal listener or protect them with the existing network policy. The model URL is operator configuration, never request data. TLS, JWT verification and tenant resolution stay in Runway. Confirm `/apply-template` and `/tokenize` against the pinned server before enabling the route; a changed template is a new deployment artifact. Backend context rejection is safe but does not prove your accounting is exact.

### Shared reservations in the existing Runway module

The phase-6 request bucket charges one request at a time; calling it once does not reserve an arbitrary number of model tokens. Keep its atomic Redis approach, but use a weighted reservation that charges prompt plus maximum output in one operation. The server clock defines the minute, tenant keys are isolated, and Redis failure returns 503 rather than silently multiplying capacity through local fallback.

These next two files are integration material. Copy them into `internal/inference` in your existing `runway` checkout, alongside the gateway package. The standalone `gateway` module deliberately has no Redis or JWT dependency. The live test reuses Phase 6's actual EdDSA JWT verifier and the real model server, not a replacement authentication scheme.

<!-- file: runway-integration/shared.go -->
~~~go
package inference

import (
	"context"
	"crypto/sha256"
	"fmt"
	"github.com/redis/go-redis/v9"
	"time"
)

// The Redis clock and the weighted reservation are evaluated in one operation.
// An unavailable shared ledger fails closed; conservative reservations are not refunded.
var reservationScript = redis.NewScript(`
local minute = math.floor(tonumber(redis.call('TIME')[1]) / 60)
local row = redis.call('HMGET', KEYS[1], 'minute', 'used')
local used = 0
if tonumber(row[1]) == minute then used = tonumber(row[2]) or 0 end
local cost, budget = tonumber(ARGV[1]), tonumber(ARGV[2])
if cost < 1 or cost > budget or used + cost > budget then return 0 end
redis.call('HSET', KEYS[1], 'minute', minute, 'used', used + cost)
redis.call('PEXPIRE', KEYS[1], 120000)
return 1
`)

// SharedReservation belongs in the existing runway module, which already has
// the Redis driver. It is deliberately not part of the stdlib-only lab module.
func SharedReservation(client redis.UniversalClient, prefix string, budget int) Reservation {
	if budget < 1 {
		panic("invalid shared budget")
	}
	return func(ctx context.Context, tenant string, cost int) (bool, error) {
		ctx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
		defer cancel()
		key := fmt.Sprintf("%s:%x", prefix, sha256.Sum256([]byte(tenant)))
		result, err := reservationScript.Run(ctx, client, []string{key}, cost, budget).Int()
		return result == 1, err
	}
}
~~~

<!-- file: runway-integration/live_test.go -->
~~~go
package inference_test

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/redis/go-redis/v9"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"runway/internal/auth"
	"runway/internal/inference"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestLiveRunwayJWTTokenizerAndSharedBudget(t *testing.T) {
	upstream, addr := os.Getenv("PHASE8_MODEL_URL"), os.Getenv("PHASE8_REDIS_ADDR")
	if upstream == "" || addr == "" {
		t.Skip("live model and Redis required")
	}
	client := redis.NewClient(&redis.Options{Addr: addr})
	defer client.Close()
	ctx := context.Background()
	if err := client.Ping(ctx).Err(); err != nil {
		t.Fatal(err)
	}
	messages := json.RawMessage(`[{"role":"user","content":"Reply with the word river only."}]`)
	tokenize := inference.LlamaTokenizer(upstream)
	count, err := tokenize(ctx, messages)
	if err != nil {
		t.Fatal(err)
	}
	if count < 1 {
		t.Fatal("missing prompt tokens")
	}
	key, err := auth.NewSigningKey(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	verifier := auth.Verifier{Issuer: "phase8-lab", Audience: "runway", Keys: auth.StaticKeys(auth.JWKS{Keys: []auth.JWK{key.Public()}})}
	issue := func(tenant string) string {
		token, err := auth.Sign(auth.Claims{Issuer: "phase8-lab", Audience: auth.Audience{"runway"}, Expiry: time.Now().Add(time.Hour).Unix(), Tenant: tenant}, key)
		if err != nil {
			t.Fatal(err)
		}
		return token
	}
	prefix := fmt.Sprintf("phase8:test:%d", time.Now().UnixNano())
	var servers []*httptest.Server
	for range 2 {
		g := inference.New(upstream, func(r *http.Request) (string, bool) { c, ok := auth.FromContext(r.Context()); return c.Tenant, ok }, tokenize, 1, 4, count+8)
		g.UseReservation(inference.SharedReservation(client, prefix, count+8))
		servers = append(servers, httptest.NewServer(auth.Require(verifier, slog.New(slog.NewTextHandler(io.Discard, nil)), g)))
	}
	defer func() {
		for _, server := range servers {
			server.Close()
		}
	}()
	call := func(server int, token string) (int, string) {
		req, err := http.NewRequest("POST", servers[server].URL, strings.NewReader(`{"messages":`+string(messages)+`,"max_tokens":8,"stream":true}`))
		if err != nil {
			t.Fatal(err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		req.Header.Set("X-Tenant", "another-tenant")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, err := io.ReadAll(res.Body)
		if err != nil {
			t.Fatal(err)
		}
		return res.StatusCode, string(body)
	}
	if code, _ := call(0, ""); code != 401 {
		t.Fatalf("unauthenticated: %d", code)
	}
	token := issue("acme")
	code, body := call(0, token)
	if code != 200 || !strings.Contains(body, "[DONE]") {
		t.Fatalf("completion: %d %s", code, body)
	}
	promptUsage := -1
	for _, line := range strings.Split(body, "\n") {
		var event struct {
			Usage *struct {
				PromptTokens int `json:"prompt_tokens"`
			} `json:"usage"`
		}
		if strings.HasPrefix(line, "data: ") && json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event) == nil && event.Usage != nil {
			promptUsage = event.Usage.PromptTokens
		}
	}
	if promptUsage != count {
		t.Fatalf("template/tokenizer mismatch: reserved %d, backend used %d", count, promptUsage)
	}
	if code, _ := call(1, token); code != 429 {
		t.Fatalf("replica bypass: %d", code)
	}
	if code, _ := call(1, issue("hooli")); code != 200 {
		t.Fatalf("tenant budget leaked: %d", code)
	}
	reserve := inference.SharedReservation(client, prefix+":concurrent", 8)
	var wg sync.WaitGroup
	var allowed atomic.Int64
	for range 20 {
		wg.Go(func() {
			ok, err := reserve(ctx, "acme", 1)
			if err != nil {
				t.Error(err)
			}
			if ok {
				allowed.Add(1)
			}
		})
	}
	wg.Wait()
	if allowed.Load() != 8 {
		t.Fatalf("atomic budget: %d", allowed.Load())
	}
	t.Logf("verified JWT auth, real prompt tokenization (%d tokens), streamed completion, two gateways sharing one tenant budget, separate tenant budgets and 20 concurrent reservations", count)
}
~~~

Mount the route as above, then configure it before serving:

~~~go
g.UseReservation(inference.SharedReservation(redisClient, "runway:inference", 8192))
~~~

Here `redisClient` is the existing Redis client from Runway's startup. All replicas must share its authoritative service and budget configuration. This is conservative fixed-minute accounting, not durable billing; a minute boundary permits a burst. Neither shared accounting nor a semaphore establishes tenant scheduling fairness.

~~~bash
# In the existing Runway checkout, with a local model and Redis running:
PHASE8_MODEL_URL=http://127.0.0.1:18080 PHASE8_REDIS_ADDR=127.0.0.1:16379 \
  go test -race -timeout=60s -run TestLiveRunwayJWTTokenizerAndSharedBudget -v ./internal/inference
~~~

The test checks that the real tokenizer/template reservation exactly matches backend prompt usage, completion, unauthenticated rejection, two gateways sharing one tenant budget, separate budgets for another tenant, and twenty concurrent weighted reservations. Ephemeral signing keys/tokens remain in test memory. It does not establish cluster deployment, GPU cancellation or complete API startup integration.

**Run it:** export Phase 6's acme bearer token as `RUNWAY_TOKEN`, point the load client at Runway's local tunnel instead of the raw server, and stream a request, then remove the bearer token (401), exceed the reservation budget (429), exceed admission capacity (503 with Retry-After), and disconnect while generating. The upstream slot must return to idle, not merely the Go channel. The unit test proves HTTP cancellation propagation; the real server experiment proves whether the backend honours it. Keep that distinction in the report.

**Break it:** replace the request context with `context.Background()`. The disconnect test must fail. Restore it. Predict what happens if a tenant opens all admitted requests: this semaphore is bounded but does not provide tenant fairness. Apply Phase 6's per-tenant admission limits before exposing it to mutually untrusted tenants.

## Step 5: Observe the user contract

The gateway exports active and admitted gauges, attempts, transport failures and first-byte diagnostics. A role-only SSE event may arrive before any text, so **first byte is not TTFT**. The synthetic client measures first nonempty content; use its raw rows for the user-facing objective. An EOF that lacks `[DONE]` is a failure in that objective even when HTTP is 200.

Write the objective before measuring: for this lab, at least 99% of offered valid requests should complete and receive their first content within 1 second, measured over a fixed workload and window. This is a chosen target, not a measured achievement. Rejections, timeouts and incomplete streams consume that budget. Keep success-only latency plots as diagnostics, alongside this all-arrivals denominator.

Scrape `/internal/inference/metrics` on the internal listener. Plot admitted minus active as waiting, active versus slots, rejection responses from Runway's existing HTTP metrics, backend token throughput and process RSS. A useful symptom is sustained waiting plus a falling share of good requests. CPU utilisation alone misses a memory-bandwidth-bound decoder.

For traces, keep Phase 6/7's existing instrumentation: start at the authenticated API, add queue wait, template/tokenizer calls and upstream streaming spans; end the stream span only on EOF, cancellation or failure. Propagate the existing trace context via the instrumented HTTP transport. Never record prompts, bearer tokens, model answers or tenant IDs as unbounded metric labels. Compare the client TTFT with queue wait plus backend prefill plus network delay.

**Break it:** introduce a 2-second delay before the fake server's first content, while sending its role event immediately. Show that first-byte diagnostics can pass while the TTFT objective fails. Disable buffering at every proxy and verify with a timestamped client; a fast backend behind a buffering proxy still feels slow.

## Step 6: Deploy a slow-starting dependency

Use Phase 5's kind cluster and Phase 6's namespace and network policies. First provision a `phase8-weights` PVC with at least 1 GiB and populate `model.gguf` with the verified file. Storage classes and access modes vary: use a local-path provisioner in kind, and remember that a ReadWriteOnce volume may prevent replicas on different nodes. Weight distribution is part of scaling, not a detail to ignore. This manifest starts at one replica and is a learner-run deployment, not a claim that a cluster was tested here.


<!-- file: deploy/inference/llm.yaml -->
~~~yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm
  namespace: runway
spec:
  replicas: 1
  strategy:
    type: Recreate # the laptop has capacity for one set of weights
  selector:
    matchLabels: {app: llm}
  template:
    metadata:
      labels: {app: llm}
    spec:
      containers:
        - name: server
          image: ghcr.io/ggml-org/llama.cpp@sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b
          args: ["-m", "/models/model.gguf", "--host", "0.0.0.0", "--port", "8080", "-c", "4096", "-t", "2", "--parallel", "1", "--metrics"]
          ports: [{name: http, containerPort: 8080}]
          resources:
            requests: {cpu: "1", memory: 768Mi}
            limits: {cpu: "2", memory: 1536Mi}
          startupProbe:
            httpGet: {path: /health, port: http}
            periodSeconds: 5
            failureThreshold: 120
          readinessProbe:
            httpGet: {path: /health, port: http}
            periodSeconds: 5
          volumeMounts:
            - {name: weights, mountPath: /models, readOnly: true}
      volumes:
        - name: weights
          persistentVolumeClaim: {claimName: phase8-weights}
---
apiVersion: v1
kind: Service
metadata: {name: llm, namespace: runway}
spec:
  selector: {app: llm}
  ports: [{port: 8080, targetPort: http}]
~~~

~~~bash
kubectl apply -f deploy/inference/llm.yaml
kubectl -n runway rollout status deployment/llm --timeout=10m
kubectl -n runway port-forward service/llm 8000:8080
~~~

A **startup probe** grants ten minutes for loading; readiness stops routing until loading completes. An aggressive liveness probe would repeatedly kill a healthy but loading model. The health endpoint is not a throughput test: a busy healthy decoder can still miss every latency target. Keep Phase 6's deny-by-default policy and permit only API-to-llm:8080 plus monitoring. Exposing the raw server bypasses JWT and limits.

Measure cold start from pod creation to readiness and first completed request. Then recreate the pod with weights already cached and compare. Record image pull separately from model load. A queue that takes thirty seconds to drain cannot be saved by a replica that takes a minute to load: admission must reject excess work meanwhile.

For queue-depth scaling, export the existing gateway's `admitted - active` through the Prometheus custom-metrics adapter, then use an HPA `Object` metric on the gateway Service with `AverageValue` target 2, minReplicas 1, maxReplicas 3, and a 300-second scale-down stabilisation window. This requires the adapter, a named Service and a metric mapping; Kubernetes alone does not understand the Go metric. **Do not enable this for the one-CPU laptop or single-node-bound PVC.** Before enabling it on a real cluster, verify `kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1` exposes that Service metric, and prove the metric represents work reaching the scalable backend. A single fixed-upstream connection can strand replicas. Use the existing service discovery and verify requests reach each endpoint.

Here is the HPA object for that adapter contract. It is deliberately not applied until the custom metric exists and the cluster has capacity. Replace `api` if your gateway Service has a different name. `AverageValue` divides the aggregate waiting work by the backend replica count; verify that interpretation against the adapter's returned metric before trusting its scaling decisions.

<!-- file: deploy/inference/hpa.yaml -->
~~~yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: llm, namespace: runway}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: llm}
  minReplicas: 1
  maxReplicas: 3
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
  metrics:
    - type: Object
      object:
        describedObject: {apiVersion: v1, kind: Service, name: api}
        metric: {name: inference_waiting}
        target: {type: AverageValue, averageValue: "2"}
~~~
**Break it:** delete the server pod while offering requests below capacity. Capture unavailable duration, queue peak, rejected requests and recovery. Then set the startup allowance shorter than the measured load time and observe the restart loop. Restore the measured allowance. A zero-downtime rollout requires capacity for old and new replicas; `Recreate` deliberately makes no such promise.

## Step 7: A supply chain for code and weights

A model file is executable input to a large native parser. Pin the image digest, use a safe weight format, restrict who can publish, scan dependencies, and establish who authorised these exact bytes. A checksum alone does not identify that person. Produce two SBOMs with [Syft](https://github.com/anchore/syft): one for the image and one inventory for the model directory. Record model origin, revision, license and tokenizer/template hashes in provenance. An inventory cannot prove what training data the publisher used.

Run the following in a release directory with Syft and [Cosign](https://docs.sigstore.dev/cosign/verifying/verify/) installed. Key generation is local practice; production keeps its signing identity in the release system, separate from deployment. Replace `IMAGE` with **your own built server image by digest**, not a tag, before publishing/signing. Do not sign an upstream image as if you built it.

~~~bash
cosign generate-key-pair
syft "$IMAGE" -o spdx-json > image.spdx.json
syft dir:weights --source-name phase8-weights --source-version release-1 \
  --select-catalogers file-metadata,digest -o spdx-json > weights.spdx.json
mv weights.spdx.json weights/weights.spdx.json
# Write weights/provenance.json with origin, revision, license, template/tokenizer
# hashes, build source revision and builder identity before the next command.
python3 - <<'PYCODE'
import hashlib, json
from pathlib import Path
p = Path('weights')
names = ['model.gguf', 'weights.spdx.json', 'provenance.json']
manifest = {'sha256': {n: hashlib.file_digest((p/n).open('rb'), 'sha256').hexdigest() for n in names}}
(p/'manifest.json').write_text(json.dumps(manifest, sort_keys=True))
PYCODE
cosign sign-blob --key cosign.key --bundle weights/manifest.sigstore.json weights/manifest.json
cosign sign --key cosign.key "$IMAGE"
cosign attest --key cosign.key --predicate image.spdx.json --type spdxjson "$IMAGE"
~~~

The signed manifest binds the weights, inventory and provenance together. Verify all three before opening the server port:


<!-- file: deploy/inference/verify-weights.sh -->
~~~bash
#!/usr/bin/env bash
# Mounted key and artifacts must be read-only; invoke before exec-ing the server.
set -euo pipefail
: "${WEIGHTS_DIR:?}" "${TRUSTED_KEY:?}" "${EXPECTED_MANIFEST_SHA256:?}"
cd "$WEIGHTS_DIR"
cosign verify-blob --key "$TRUSTED_KEY" --bundle manifest.sigstore.json manifest.json
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
manifest_path = Path('manifest.json')
actual = hashlib.file_digest(manifest_path.open('rb'), 'sha256').hexdigest()
if actual != os.environ['EXPECTED_MANIFEST_SHA256']:
    raise SystemExit('unauthorised manifest digest')
manifest = json.loads(manifest_path.read_text())
for name in ('model.gguf', 'weights.spdx.json', 'provenance.json'):
    path = Path(name)
    digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
    if digest != manifest['sha256'][name]:
        raise SystemExit(f'digest mismatch: {name}')
print('verified model, SBOM and provenance')
PY
~~~

<!-- run: bash -n deploy/inference/verify-weights.sh -->

Build a derived server image containing this verifier, Python and the pinned Cosign binary. Its entrypoint runs the verifier and `exec`s llama-server only after success. Set `EXPECTED_MANIFEST_SHA256` from the reviewed release configuration (the SHA-256 of the exact authorised manifest), and mount the public trust key and artifacts read-only; the signing private key never enters the cluster. Put verification in the entrypoint, rather than just an init container that checks a mutable volume long before the server reads it. Use an immutable model artifact or a private copy if another process can change the volume: read-only in one container does not prevent another writer from changing a PVC.

Deploy [Sigstore policy-controller](https://docs.sigstore.dev/policy-controller/overview/) in the lab cluster, label `runway` for inclusion, and install a `ClusterImagePolicy` matching your registry prefix with a `key.data` authority containing `cosign.pub`. Set `no-match-policy: deny` in its config and `failurePolicy: Fail` on the validating webhook. Keep an explicit trusted policy for the verifier image too. Test on a disposable namespace first; a policy that matches no workload is not enforcement.

Create the image policy from this template. Replace both the registry glob and the entire key placeholder before applying; a placeholder is not a trust root. Install and enable policy-controller first, following its version-matched chart instructions. The registry policy must cover every container and init container admitted to the enforced namespace; scope the disposable test namespace accordingly.

<!-- file: deploy/inference/image-policy.template.yaml -->
~~~yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: runway-inference
spec:
  images:
    - glob: "ghcr.io/YOUR_ORG/runway-inference**"
  authorities:
    - key:
        data: |
          REPLACE_WITH_CONTENTS_OF_COSIGN_PUB
~~~
~~~bash
# After replacing the template values and installing the controller:
kubectl label namespace runway policy.sigstore.dev/include=true --overwrite
kubectl apply -f deploy/inference/image-policy.template.yaml
# Verify fail-closed webhook/no-match settings before the negative cases.
~~~

Admission verifies **images**. The entrypoint verifies **weights**; admission does not inspect arbitrary PVC bytes. Both must pass. Also bind the allowed model manifest digest into the deployment's reviewed release configuration: a valid signature for an older authorised model is otherwise a possible rollback. Archive the release bundle, SBOMs, scan results and manifest digest. Key compromise and revocation need a separate trust-key rotation runbook.

**Break it, with evidence:** deploy an unsigned image (admission must reject); change one byte of `model.gguf` while keeping its bundle (startup must refuse); remove the bundle (startup must refuse); replace the public key with another key (verification must fail); restore the authorised artifact (readiness must return). Capture each command, exit status and event. The [dated CPU evidence](evidence/2026-11-07/report.md) exercises the weight verification/refusal cases and recovery. Unsigned container-image admission and complete deployed enforcement are still **not measured**; do not call the supply-chain exercise complete from the weight checks alone. Never paste the private key into the transcript.

## Step 8: Benchmark performance, cost and quality together

Write a plan first. Compare slots 1/2/4, Q4/Q8 and two thread counts. Fix prompt/output limits, randomise configuration order, repeat at least five independent runs, and retain raw arrivals, failures and usage. Include both short and long prompts with no accidental shared prefix. Record image, model and tokenizer hashes, host CPU/memory and runtime versions, load seed and wall-clock start/end. Record cold starts separately. Use Phase 7's block bootstrap for correlated measurements; a thousand requests in one run are not a thousand independent runs.

Cost per million **completed output tokens** is billed hourly price × elapsed hours × 1,000,000 / completed output tokens. Include idle time and unused reserved capacity for a deployment-cost comparison. For a rented benchmark also report model download/load costs separately. A synthetic price is an assumption, never a current vendor quote. Do not substitute chunk counts when the server omits token usage.


<!-- file: serve/src/serve/score.py -->
~~~python
"""All-arrivals objective and cost: missing evidence cannot pass a release gate."""

import argparse
import json
import math


def score(rows, seconds, hourly, quality):
    if not rows or seconds <= 0 or hourly < 0:
        raise ValueError("rows, positive duration and nonnegative price required")
    valid = [r for r in rows if not r["error"] and r["ttft"] is not None]
    good = [r for r in valid if r["ttft"] <= 1]
    tokens_known = all(r.get("output_tokens") is not None for r in valid)
    tokens = sum(r["output_tokens"] for r in valid) if tokens_known else None
    # A one-sided 95% Wilson lower bound; requests are treated as independent.
    # Correlated overload requires run/block resampling as in Phase 7 instead.
    n, p, z = len(rows), len(good) / len(rows), 1.645
    lower = (p + z * z / (2 * n) - z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / (
        1 + z * z / n
    )
    return {
        "offered": n,
        "completed": len(valid),
        "good_fraction": p,
        "good_lower95": lower,
        "output_tokens": tokens,
        "cost_per_million": hourly * seconds / 3600 * 1e6 / tokens if tokens else None,
        "quality": quality,
        "verdict": "pass" if lower >= 0.99 and quality is True and tokens else "not established",
    }


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("rows")
    p.add_argument("--seconds", type=float, required=True)
    p.add_argument("--hourly", type=float, required=True)
    p.add_argument("--quality", choices=["pass", "fail", "unknown"], default="unknown")
    a = p.parse_args()
    rows = [json.loads(line) for line in open(a.rows)]
    quality = {"pass": True, "fail": False, "unknown": None}[a.quality]
    print(json.dumps(score(rows, a.seconds, a.hourly, quality), indent=2))
~~~


<!-- file: serve/tests/test_score.py -->
~~~python
from serve.score import score


def test_failures_stay_in_denominator_and_unknown_tokens_cannot_pass():
    good = {"error": "", "ttft": 0.1, "output_tokens": 20}
    bad = {"error": "timeout", "ttft": None, "output_tokens": None}
    result = score([good, bad], 10, 1, True)
    assert result["good_fraction"] == 0.5
    assert result["cost_per_million"] > 0
    assert result["verdict"] == "not established"
    assert score([{**good, "output_tokens": None}], 10, 1, True)["cost_per_million"] is None
    assert score([good] * 1000, 10, 1, None)["verdict"] == "not established"
    assert score([good] * 1000, 10, 1, True)["verdict"] == "pass"
~~~

<!-- run: cd serve && uv run pytest -q tests/test_score.py -->

~~~bash
cd serve
uv run python -m serve.score ../results/slots1-rate02.jsonl --seconds 500 --hourly 0.10
~~~

Replace 500 with the actual full run duration and 0.10 with the explicitly assumed or billed hourly cost. The command returns `not established` when quality is unknown. Its Wilson bound assumes independent requests; for the real load grid, replace it with Phase 7's interval across runs/blocks. A point estimate of 100% on ten requests cannot establish a 99% objective.

Freeze twenty held-out prompts before comparing quantisation: extraction with exact fields, grounded questions with expected facts, short arithmetic and refusal of an unsupported answer. Store the expected outputs and a scoring rubric. Score blind to configuration, check every slice, and decide the minimum acceptable score before running. Small instruction models may fail the quality target entirely. Report that result rather than loosening the target after seeing it. `--quality pass` means the retained rubric evidence passed; it is not an automatic quality measurement.

**Break it:** feed the scorer an all-timeout run and an otherwise successful run with missing usage. Neither may manufacture a finite successful cost or pass verdict. Explain how dropping failed rows would make an overloaded configuration look cheap and fast.

### A reproducible CPU grid

The [2026-11-07 experiment plan](evidence/2026-11-07/plan.md) fixes a short eight-output-token workload, twenty toy quality prompts, five repetitions and rates chosen from a separate low-load baseline. It compares Q4/Q8 and one/two slots at four threads. It does not replace the longer-context, additional-thread-count and GPU experiments above.

The runner below owns only the Docker container `blueprint-phase8-llm` on loopback port 18080. Start that container with the exact one-slot Q4 settings before invoking the runner. Use a fresh result directory: rerunning into a partial directory would append incompatible runs. Never point it at a directory containing accepted evidence. The published capture used the same algorithm with local model/output paths substituted; its environment and frozen inputs are retained beside the results.

<!-- file: serve/src/serve/experiment.py -->
~~~python
import concurrent.futures
import hashlib
import json
import os
import platform
import random
import statistics
import subprocess
import time
from dataclasses import asdict
from pathlib import Path

from serve.stream import chat

OUT = Path(os.environ["PHASE8_RESULTS"])
OUT.mkdir(parents=True, exist_ok=True)
MODEL = os.environ["PHASE8_MODELS"]
IMAGE = (
    "ghcr.io/ggml-org/llama.cpp@sha256:"
    "e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b"
)
URL = "http://127.0.0.1:18080"
NAME = "blueprint-phase8-llm"


def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + "\n")


def restart(precision, slots):
    subprocess.run(["docker", "rm", "-f", NAME], capture_output=True, check=True)
    subprocess.run(
        [
            "docker",
            "run",
            "-d",
            "--name",
            NAME,
            "-p",
            "127.0.0.1:18080:8080",
            "-v",
            MODEL + ":/models:ro",
            IMAGE,
            "-m",
            f"/models/qwen2.5-0.5b-instruct-{precision}.gguf",
            "-c",
            str(4096 * slots),
            "-t",
            "4",
            "--parallel",
            str(slots),
            "--metrics",
            "--host",
            "0.0.0.0",
        ],
        capture_output=True,
        check=True,
    )
    import urllib.request

    for _ in range(120):
        try:
            with urllib.request.urlopen(URL + "/health", timeout=1) as r:
                if r.status == 200:
                    break
        except OSError:
            time.sleep(0.5)
    else:
        raise RuntimeError("model did not become ready")
    for i in range(3):
        result = chat(URL, f"Warmup {i}: Explain backpressure briefly.", 8)
        if result.error:
            raise RuntimeError(result.error)


def measure(rate, n, seed, precision, slots, rep):
    rng = random.Random(seed)
    due = 0
    arrivals = []
    for i in range(n):
        due += rng.expovariate(rate)
        arrivals.append(
            (i, due, f"Request {rng.getrandbits(64)}: Explain backpressure in two sentences.")
        )
    start = time.monotonic()
    wall = time.time()

    def one(i, due, prompt):
        lag = max(0, time.monotonic() - start - due)
        result = asdict(chat(URL, prompt, 8, timeout=30))
        if result["ttft"] is not None:
            result["ttft"] += lag
        result.update(
            id=i,
            arrival=due,
            dispatch_lag=lag,
            precision=precision,
            slots=slots,
            rep=rep,
            rate=rate,
            seed=seed,
        )
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        futures = []
        for i, due, prompt in arrivals:
            time.sleep(max(0, start + due - time.monotonic()))
            futures.append(pool.submit(one, i, due, prompt))
        rows = [f.result() for f in futures]
    seconds = time.monotonic() - start
    wall_seconds = time.time() - wall
    with (OUT / "arrivals.jsonl").open("a") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    completed = [r for r in rows if not r["error"] and r["ttft"] is not None]
    tokens = (
        sum(r["output_tokens"] for r in completed)
        if all(r["output_tokens"] is not None for r in completed)
        else None
    )
    summary = dict(
        precision=precision,
        slots=slots,
        rep=rep,
        rate=rate,
        seed=seed,
        offered=n,
        completed=len(completed),
        good=sum(r["ttft"] <= 1 for r in completed),
        seconds=seconds,
        wall_seconds=wall_seconds,
        clock_ratio=wall_seconds / seconds,
        max_dispatch_lag=max(r["dispatch_lag"] for r in rows),
        output_tokens=tokens,
        mean_ttft=statistics.mean(r["ttft"] for r in completed) if completed else None,
        mean_completion=statistics.mean(r["total"] + r["dispatch_lag"] for r in completed)
        if completed
        else None,
    )
    with (OUT / "runs.jsonl").open("a") as f:
        f.write(json.dumps(summary) + "\n")
    print(json.dumps(summary), flush=True)


quality = []
for i in range(1, 9):
    quality.append(
        {"prompt": f"Reply with only the result: {i} + {i + 1}.", "expected": str(2 * i + 1)}
    )
for word in ("river", "stone", "cloud", "garden", "signal", "window", "paper", "engine"):
    quality.append(
        {
            "prompt": f"Copy the word inside brackets. Reply with that word only: [{word}]",
            "expected": word,
        }
    )
for city, person in [("Lima", "Ada"), ("Oslo", "Ben"), ("Accra", "Cara"), ("Kyoto", "Dan")]:
    quality.append(
        {
            "prompt": (
                f"Use only this fact: {person} lives in {city}. "
                f"Which city does {person} live in? Reply with the city only."
            ),
            "expected": city,
        }
    )
save("quality-set.json", quality)
try:
    metadata = {
        "python": platform.python_version(),
        "system": platform.system(),
        "machine": platform.machine(),
        "logical_cpus": os.cpu_count(),
        "image": IMAGE,
        "price_assumption_usd_per_hour": 0.1,
        "threads": 4,
        "context_per_slot": 4096,
        "output_limit": 8,
        "model_sha256": {
            p.name: hashlib.file_digest(p.open("rb"), "sha256").hexdigest()
            for p in Path(MODEL).glob("*.gguf")
        },
    }
    save("environment.json", metadata)
    for i in range(3):
        chat(URL, f"Warmup baseline {i}. Explain a queue.", 8)
    baseline = [
        asdict(chat(URL, f"Baseline {i}: Explain backpressure briefly.", 8)) for i in range(8)
    ]
    assert all(not r["error"] for r in baseline)
    service = statistics.mean(r["total"] for r in baseline)
    save(
        "baseline.json",
        {
            "rows": baseline,
            "mean_service_seconds": service,
            "rates": [x / service for x in (0.4, 0.8, 1.2)],
        },
    )
    print(f"baseline S={service}", flush=True)
    rng = random.Random(20261107)
    for rep in range(1, 6):
        configs = [(p, s) for p in ("q4_k_m", "q8_0") for s in (1, 2)]
        rng.shuffle(configs)
        for precision, slots in configs:
            restart(precision, slots)
            for rate_index, multiple in enumerate((0.4, 0.8, 1.2)):
                measure(
                    multiple / service, 12, 20261107 + rep * 100 + rate_index, precision, slots, rep
                )
            if rep == 1:
                scored = []
                for item in quality:
                    result = asdict(chat(URL, item["prompt"], 32))
                    normal = result["text"].strip().rstrip(".!?").strip().casefold()
                    scored.append(
                        {
                            **item,
                            **result,
                            "exact_match": not result["error"]
                            and normal == item["expected"].casefold(),
                        }
                    )
                save(
                    f"quality-{precision}-slots{slots}.json",
                    {
                        "correct": sum(r["exact_match"] for r in scored),
                        "total": len(scored),
                        "rows": scored,
                    },
                )
finally:
    subprocess.run(["docker", "rm", "-f", NAME], capture_output=True)
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . -->

~~~bash
# From the lab root; PHASE8_MODELS must contain both verified GGUF files.
export PHASE8_MODELS="$PWD/models"
export PHASE8_RESULTS="$PWD/results/cpu-grid-new"
mkdir -p "$PHASE8_RESULTS"
docker run -d --name blueprint-phase8-llm -p 127.0.0.1:18080:8080 \
  -v "$PHASE8_MODELS:/models:ro" \
  ghcr.io/ggml-org/llama.cpp@sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b \
  -m /models/qwen2.5-0.5b-instruct-q4_k_m.gguf -c 4096 -t 4 \
  --parallel 1 --metrics --host 0.0.0.0
# Wait for /health to return 200 before starting the baseline.
cd serve
uv run python -m serve.experiment
~~~

All generated requests are synthetic. The hypothetical $0.10/hour CPU price exercises the accounting only. The quality set is intentionally small: passing it cannot establish general answer quality or model safety. The [evidence report](evidence/2026-11-07/report.md) states which conclusions the capture supports and which remain unmeasured.

The report builder refuses missing/duplicate repetition blocks. Its t intervals describe run-level variability on this host, not independent users or a production acceptance guarantee. It returns missing cost/latency intervals when their required evidence is absent.

<!-- file: serve/src/serve/report.py -->
~~~python
"""Summarise independent run blocks, retaining failures and quality gates."""

import argparse
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


def interval(values):
    mean = statistics.mean(values)
    if len(values) != 5:
        raise ValueError("the preregistered report requires five repetitions per condition")
    # Two-sided 95% Student t interval for five independent run-level means.
    half = 2.7764451051977987 * statistics.stdev(values) / math.sqrt(5)
    return [mean, mean - half, mean + half]


def summarize(root):
    groups = defaultdict(list)
    rows = [json.loads(line) for line in (root / "runs.jsonl").read_text().splitlines()]
    if len(rows) != 60:
        raise ValueError("incomplete grid: expected sixty runs")
    for row in rows:
        groups[(row["precision"], row["slots"], row["rate"])].append(row)
    results = []
    for (precision, slots, rate), runs in sorted(groups.items()):
        if sorted(r["rep"] for r in runs) != [1, 2, 3, 4, 5]:
            raise ValueError("missing/duplicate repetitions")
        quality = json.loads((root / f"quality-{precision}-slots{slots}.json").read_text())
        good = interval([r["good"] / r["offered"] for r in runs])
        costs = (
            [0.10 * r["seconds"] / 3600 * 1e6 / r["output_tokens"] for r in runs]
            if all(r["output_tokens"] for r in runs)
            else None
        )
        valid_timing = all(
            abs(r["clock_ratio"] - 1) <= 0.02 and r["max_dispatch_lag"] <= 0.05 for r in runs
        )
        # A t interval on short bounded proportions is exploratory, not a
        # production 99% acceptance test. Never promote from this small grid.
        results.append(
            {
                "precision": precision,
                "slots": slots,
                "rate": rate,
                "offered": sum(r["offered"] for r in runs),
                "completed": sum(r["completed"] for r in runs),
                "good_run_fraction_mean_ci95": good,
                "mean_ttft_seconds_ci95": (
                    interval([r["mean_ttft"] for r in runs])
                    if all(r["mean_ttft"] is not None for r in runs)
                    else None
                ),
                "hypothetical_usd_per_million_output_tokens_ci95": interval(costs)
                if costs is not None
                else None,
                "quality_correct": quality["correct"],
                "quality_total": quality["total"],
                "quality_pass": quality["correct"] >= 18,
                "clock_and_dispatch_checks_pass": valid_timing,
                "production_acceptance": "not established",
            }
        )
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.directory), indent=2))
~~~

~~~bash
cd serve
uv run python -m serve.report "$PHASE8_RESULTS" > "$PHASE8_RESULTS/summary.json"
~~~

## Step 9: Failure, recovery and the game day

Write the runbook before injecting faults. Define incident start with a monotonic clock, detection, mitigation, and recovery as ten consecutive successful synthetic requests, not merely readiness. Run one fault at a time at a fixed offered load. Keep the raw trace and objective rows before, during and after each fault.

| Fault | Expected signal | Mitigation | Recovery evidence |
|---|---|---|---|
| Kill model process | Upstream failures, missing readiness | Restart known-good digest; bound admission | Requests recover; no capacity leak |
| Offer twice measured capacity | Waiting, 503, bad TTFT fraction | Reduce admission/offered rate; add proven capacity | Queue drains within deadline |
| Disconnect clients during decode | Cancelled spans; backend slots should free | Propagate cancellation; deadline backstop | Actual backend slots return idle |
| Deploy corrupt weights | Signature/hash refusal, unready pod | Roll back manifest and image together | Verified startup and completed request |
| Exhaust memory | OOMKilled, rising RSS | Reduce context/slots; restore memory budget | Stable RSS and objective over fixed window |
| Lose metrics scraper | Missing series | Repair monitoring; do not assume silence means healthy | Synthetic requests still reveal failures |

Runbook order: identify the release digests; stop further rollout; inspect queue, RSS and errors without prompts; shed excess work; restore the last tested **image+model+template** release; verify signatures; wait for readiness; run the synthetic contract; compare the all-arrivals objective; record detection and recovery times. Never automatically retry a partially delivered answer: the user may receive duplicate text. A failed optional prediction in Phase 7 could fall back; a generation endpoint cannot pretend a partial answer is complete.

**Done when:** two repetitions of every fault have transcripts, recovery times and the expected bounded behaviour. This guide supplies the procedure, not fabricated game-day timings. Leave any unrun fault explicitly `not measured` in step 14.

## Step 10: Data parallelism, with a reference you can check

Inference batches different users; training batches examples to estimate a gradient. **Data parallelism** replicates the model and gives each rank a shard of examples. DDP reduces gradients across ranks before each optimiser update. With equal-size shards and a mean loss, averaging the rank gradients must equal the gradient on the combined batch. Build that test before measuring speed. [PyTorch's DDP tutorial](https://docs.pytorch.org/tutorials/intermediate/ddp_tutorial.html) explains the process-group and model wrapper.


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

This compares four distributed SGD updates with four serial full-batch updates, then saves one atomic checkpoint. It proves gradient semantics, not training speed: the serial reference is intentionally inside the measured loop. For a speed experiment remove the reference work from both timed variants, keep global batch and update count fixed, warm up, synchronise at the boundaries and compare 1 versus 2 ranks. Report samples/s and time to a fixed validation loss, not just time per local batch. For real epochs use `DistributedSampler` and call `set_epoch`; unequal shard sizes require weighted gradient accounting.

Across [netlab](../network-bridge/README.md)'s shaped link, run the same CPU environment in each of its two containers. Use TCP on the shaped interfaces, not loopback; set `GLOO_SOCKET_IFNAME` to that interface. Start both commands against rank zero's reachable IP and the same rendezvous port:

~~~bash
# Container A
GLOO_SOCKET_IFNAME=eth0 uv run python -m torch.distributed.run --nnodes=2 --nproc-per-node=1 --node-rank=0 --master-addr=172.28.0.2 --master-port=29500 -m serve.ddp
# Container B (substitute the actual address from your netlab)
GLOO_SOCKET_IFNAME=eth0 uv run python -m torch.distributed.run --nnodes=2 --nproc-per-node=1 --node-rank=1 --master-addr=172.28.0.2 --master-port=29500 -m serve.ddp
~~~

Allow the Gloo peer connections on the isolated lab network as well as the rendezvous port. Run baseline, then netlab's 10/50/100 ms RTT and bandwidth/loss conditions. Prove packets cross the shaped interface with `ss`/packet capture. The tiny model is latency dominated; increase parameter bytes in a separate benchmark to see bandwidth dominate. Approximate ring all-reduce traffic per rank is 2(P−1)/P times gradient bytes, before protocol overhead. Do not infer RDMA or NCCL performance from CPU Gloo.

**Break it:** kill rank 1 during backward. The process-group timeout should fail the job rather than commit another checkpoint. Restore the previous checkpoint, optimiser state and step; document whether the data sampler repeats or skips examples. The guide checks atomic publication, not a complete resumable data pipeline. Capture the multi-container failure/recovery experiment separately: it has not been run here.

## Step 11: Split the model, not just the examples

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

The assertions compare each rank's weight gradients with the unsplit reference. This is real two-process communication with a sequential pipeline schedule; it does not claim overlap or speedup. Run the same program across the shaped link with step 10's launcher arguments to expose communication cost.

Read [Megatron-LM's parallelism guide](https://github.com/NVIDIA/Megatron-LM/blob/main/docs/user-guide/parallelism-guide.md), then `megatron/core/tensor_parallel/layers.py` and `pipeline_parallel/schedules.py` at a recorded commit. Find the column/row parallel linear layers, their gradient collectives, and the schedule that alternates forward/backward work. Draw which tensors cross which boundary. With p stages and m microbatches, a simple fill/drain schedule has ideal bubble fraction (p−1)/(m+p−1), assuming equal stage times and ignoring communication; increasing m trades bubbles for scheduling/activation costs. A sequential two-process exercise proves transport, not overlap.

**Break it:** swap the paired B shards, or omit the backward handoff. Show which parity assertion detects each error. Remove the `/4` and explain the gradient failure. Do not claim Megatron-scale performance from this arithmetic check.

## Step 12: Ray, and where distribution helps

Ray supplies a scheduler, remote tasks, actors and an object store. A task is a function with an object reference as its future; an actor owns mutable state. Neither automatically makes side effects exactly once. Retry a task that writes an external object only when the write is idempotent or uses a commit protocol.

Use a separate optional extra so ordinary CI does not start another runtime. Add this section to `serve/pyproject.toml`, then resolve and retain `uv.lock` in your learner repo:

<!-- append: serve/pyproject.toml -->
~~~toml
[project.optional-dependencies]
ray = ["ray[serve,train]==2.49.2"]
~~~

This is a pinned teaching version, not a claim that it is the latest release. Read the matching [Ray tasks and actors documentation](https://docs.ray.io/en/latest/ray-core/actors.html) when upgrading.


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

Stop Serve with Ctrl-C after recording the result. Use Serve as an alternative control plane in a separate experiment; keep Runway's auth and token admission in front of a real model deployment. The random teaching model cannot meet the quality gate.

**Break it:** commit the same task result twice with deduplication removed; then kill/recreate the actor and repeat. Explain the difference between task retries and durable commit semantics. Capture the Ray commands and versions in the report; Ray execution is manual and is not part of the CPU CI claim below.

## Step 13: CUDA, transfers, and vLLM

Read the [linear-algebra guide](../../math/03-linear-algebra/README.md) first: arithmetic intensity and the roofline explain why prefill, decode and tiny kernels hit different limits. CUDA has a host and device address space; transfer time and launch overhead are work too. Pinned host buffers allow efficient DMA, but pinning costs memory and setup, and `non_blocking=True` alone does not prove overlap. See [NVIDIA's CUDA best practices](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/).

**Evidence status:** no GPU is available in this checkout. These scripts are provided for the previously agreed rented-GPU run. They have no measured output yet. Rent only for the run, record the rate, and stop/destroy the instance afterwards. First capture `nvidia-smi`, driver/CUDA versions, CPU/RAM, image/environment digest and the model revision. Use a fresh GPU-specific environment rather than the lab's CPU-only PyTorch index.

~~~bash
uv venv --python 3.12 .gpu-venv
# Choose a CUDA-enabled PyTorch build compatible with the provider's driver.
# Record the resolved packages with: uv pip freeze --python .gpu-venv/bin/python
~~~

A CUDA kernel maps blocks and threads onto indices; the final block may be partial. This one deliberately uses 1,003 elements to catch an omitted bounds check:


<!-- file: gpu/add.cu -->
~~~cpp
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#define CHECK(call) do { auto e=(call); if(e!=cudaSuccess) { \
 fprintf(stderr,"%s\n",cudaGetErrorString(e)); std::exit(1); } } while(0)
__global__ void add(const float* a, const float* b, float* c, int n) {
 int i=blockIdx.x*blockDim.x+threadIdx.x;
 if(i<n) c[i]=a[i]+b[i];
}
int main() {
 constexpr int n=1003;
 float *a,*b,*c;
 CHECK(cudaMallocManaged(&a,n*sizeof(float)));
 CHECK(cudaMallocManaged(&b,n*sizeof(float)));
 CHECK(cudaMallocManaged(&c,n*sizeof(float)));
 for(int i=0;i<n;i++){a[i]=i;b[i]=2*i;}
 add<<<(n+255)/256,256>>>(a,b,c,n);
 CHECK(cudaGetLastError()); CHECK(cudaDeviceSynchronize());
 for(int i=0;i<n;i++) if(c[i]!=3*i) return 2;
 std::puts("1003 elements correct, including the partial final block");
 CHECK(cudaFree(a)); CHECK(cudaFree(b)); CHECK(cudaFree(c));
}
~~~

~~~bash
nvcc -O2 gpu/add.cu -o gpu/add
compute-sanitizer ./gpu/add
~~~

**Break it:** remove `if(i<n)` and run compute-sanitizer. Restore the guard. A successful launch is not a successful kernel: check launch errors and synchronise before reading results.

Now measure transfer **completion**, not the time to enqueue a copy. Allocate before timing, warm up, use repeated samples and check answers. PyTorch invokes CUDA here; this complements the kernel exercise above.


<!-- file: gpu/capture.py -->
~~~python
"""GPU-only evidence capture: warm up, synchronise, measure and verify."""

import json
import platform
import statistics
import time

import torch


def main():
    if not torch.cuda.is_available():
        raise SystemExit("not measured: CUDA device unavailable")
    torch.manual_seed(1)
    print(
        json.dumps(
            {
                "torch": torch.__version__,
                "cuda": torch.version.cuda,
                "gpu": torch.cuda.get_device_name(),
                "host": platform.platform(),
            }
        )
    )
    for n in (1 << 10, 1 << 20, 1 << 24):
        for pinned in (False, True):
            host = torch.ones(n, pin_memory=pinned)
            device = torch.empty(n, device="cuda")
            samples = []
            for i in range(12):
                torch.cuda.synchronize()
                start = time.perf_counter()
                device.copy_(host, non_blocking=pinned)
                torch.cuda.synchronize()  # measuring completion, not enqueue
                if i >= 2:
                    samples.append(time.perf_counter() - start)
            assert device.sum().item() == n
            print(
                json.dumps(
                    {
                        "bytes": n * 4,
                        "pinned": pinned,
                        "median_seconds": statistics.median(samples),
                    }
                )
            )
    n = 512
    a, b = torch.randn(n, n), torch.randn(n, n)
    reference = a @ b
    aa, bb = a.cuda(), b.cuda()
    torch.cuda.synchronize()
    samples = []
    for i in range(12):
        start, end = (
            torch.cuda.Event(enable_timing=True),
            torch.cuda.Event(enable_timing=True),
        )
        start.record()
        result = aa @ bb
        end.record()
        end.synchronize()
        if i >= 2:
            samples.append(start.elapsed_time(end))
    torch.testing.assert_close(result.cpu(), reference, rtol=1e-3, atol=1e-3)
    print(
        json.dumps(
            {
                "matmul_n": n,
                "median_ms": statistics.median(samples),
                "max_memory_bytes": torch.cuda.max_memory_allocated(),
            }
        )
    )


if __name__ == "__main__":
    main()
~~~

<!-- run: python3 -m py_compile gpu/capture.py -->

~~~bash
.gpu-venv/bin/python gpu/capture.py > gpu-results.jsonl
~~~

Explain why small transfers are dominated by fixed overhead, why pinning can matter for large transfers, and why the device matmul timer excludes host-device copies. Compare end-to-end time separately. A speedup without answer parity is not accepted. If a tolerance fails, investigate precision settings; do not silently widen it.

Finally run [vLLM](https://docs.vllm.ai/en/latest/serving/offline_inference/) on the same frozen prompt/quality set. In a separate environment install a pinned version supported by the provider, record its lock and model revision, then:

~~~bash
vllm serve Qwen/Qwen2.5-0.5B-Instruct --host 127.0.0.1 --port 8000 --max-model-len 4096
~~~

Use the step-3 load client through an SSH tunnel bound to loopback, at concurrency/arrival rates that fit the GPU. Repeat the performance/cost/quality grid, collecting server token usage, GPU memory and utilisation. vLLM's batching and paged KV management target different overheads from our tick simulator; explain which bottleneck moved. Compare the same precision/model when possible, and label Q4 GGUF versus FP16 as a combined engine-and-precision comparison. One GPU cannot verify multi-GPU tensor parallelism.

**Done when:** the kernel passes sanitizer, transfer and matmul parity pass, the repeated timing records exist, vLLM completes the frozen quality/performance suite, and the instance is destroyed. Until those artifacts exist, step 13 remains **not measured**, never an expected numerical output invented from a spec sheet.

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

## Step 14: A report that preserves the limits

Build a release bundle with `git rev-parse HEAD`, runtime versions, image and weight digests, template/tokenizer hashes, workload seeds, raw per-arrival results, quality rubric and scores, price assumption or invoice, startup measurements and game-day transcripts. Do not commit weight blobs, private keys or bearer tokens.

For each claim, state the planned threshold, evidence path, interval and one of `supported`, `contradicted`, `inconclusive`, `not measured`. Keep correctness checks separate from performance evidence. A simulator matching its expected schedule supports its implementation, not a claim about an LLM server. A cancellation test supports upstream HTTP cancellation, not the claim that an arbitrary backend stops GPU work.

Use this starting evidence ledger:

| Claim | Evidence provided here | Limit |
|---|---|---|
| KV caching preserves greedy outputs | Tiny-model parity test; historical timing capture | Random untrained transformer, one CPU |
| SSE measurement retains usage and detects truncation | Fake-server contract test | Chunk gaps are not guaranteed token gaps |
| Admission stays bounded; reservations are shared across gateway instances | Go race tests and real JWT/tokenizer/Redis component integration | Full API startup, fairness and actual backend slot release still need deployed checks |
| DDP updates equal global-batch SGD | Two CPU/Gloo ranks and serial reference | Not a network scaling benchmark |
| Tensor/pipeline decompositions preserve gradients | Single-process reference and two-rank send/recv checks | Sequential pipeline; no overlap benchmark |
| Signed weight manifest accepts/refuses the intended bytes | Six real verification cases in the dated report | Local test signer, not publisher identity; image admission remains unmeasured |
| Deployment, image admission and failure recovery work live | Procedure supplied | Not measured on this checkout |
| Ray runtime and GPU/vLLM performance | Runnable/manual procedures supplied | Not measured on this checkout |
| A configuration meets latency, quality and cost targets | Scorer plus 60-run CPU grid and frozen toy quality results | No accepted production configuration established |

Rebuild the CPU evidence from the repository root:

~~~bash
python3 scripts/check_guides.py lessons/08-ai-infrastructure/TEACHING.md
~~~

The replay extracts the inline files into a fresh temporary directory. Docker, kind, signing services, the shaped link, Ray and a GPU are manual experiments, explicitly outside that command. Run the entire repository workflow when you have the earlier phases' broker/database services available. Never relabel syntax checking as a deployed result.

Finish [the questions](learned.md), build [the independent exercise](exercises.md), and take [the self-test](../../notes/learned/08-ai-infrastructure.md). Then move to the [capstone](../../capstones/README.md): now you choose the question as well as the experiment.
