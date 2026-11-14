# Phase 8 teaching: AI infrastructure

At the end of Phase 7, Runway measures itself, and a model runs inside it, predicting how long jobs will take. That model is small: it answers in a millisecond, and it fits on one CPU. This phase is about the other kind, the ones that AI products run on, where one request holds a slice of an expensive machine for many seconds, and the machine costs more per hour than everything else in Runway put together.

This phase asks what it takes to run that infrastructure: serving models reliably and cheaply, training across many devices, and keeping GPUs busy.

**The goal:** an inference platform on Runway, for an open-weight language model, and a clear idea of how training splits a model across machines. Every claim comes with the experiment behind it, in the way Phase 7 taught.

**Time:** about 8 weeks. **Before you start:** finish Phases 0–7, the [Performance Bridge](../perf-bridge/README.md), the [Networking Bridge](../network-bridge/README.md), and the [maths track](../../math/README.md)'s [queueing](../../math/01-queueing/README.md) and [linear algebra](../../math/03-linear-algebra/README.md) guides. This phase leans on all of them.

## How this guide works

The same as Phase 7: type everything, file by file, and run the checks at the end of each step. The Python work is in a new project called `serve`, next to `lab`. Your numbers will differ from mine; compare the ratios and the shape.

**Hardware:** steps 1–12 use CPUs; live deployment needs Docker and kind. Step 13 needs an NVIDIA GPU. Historical measurements below came from the earlier scratch experiments; the [platform report](evidence/platform-validation/report.md) now retains live CPU API, Kubernetes, image/weight enforcement, game-day, network-recovery and Ray results. GPU commands remain learner-run procedures without measured outputs. The CPU correctness checks replay in CI. Start in a fresh directory for this phase, beside your existing Runway checkout. The gateway package is integrated into Runway in step 4; the Python lab is independent.

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
	hooks    Hooks
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
	outcome := "invalid"
	var queued time.Duration
	state := streamState{tokens: -1}
	defer func() {
		if g.hooks.Finish != nil {
			ttft := time.Duration(-1)
			if !state.first.IsZero() {
				ttft = state.first.Sub(start)
			}
			g.hooks.Finish(r.Context(), outcome, ttft, queued, state.tokens)
		}
	}()
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
		outcome = "overloaded"
		http.Error(w, "overloaded", 503)
		return
	}
	defer func() { <-g.admitted }()
	waitStart := time.Now()
	_, endQueue := g.stage(ctx, "inference.queue")
	select {
	case g.active <- struct{}{}:
		queued = time.Since(waitStart)
		endQueue()
	case <-ctx.Done():
		queued = time.Since(waitStart)
		endQueue()
		outcome = "deadline"
		http.Error(w, "queue deadline", 504)
		return
	}
	defer func() { <-g.active }()
	tokenCtx, endToken := g.stage(ctx, "inference.tokenize")
	n, err := g.tokenize(tokenCtx, input.Messages)
	endToken()
	if err != nil {
		outcome = "backend_error"
		g.failures.Add(1)
		http.Error(w, "tokenizer unavailable", 502)
		return
	}
	if n < 1 || n+input.MaxTokens > 4096 {
		http.Error(w, "invalid context", 400)
		return
	}
	reserveCtx, endReserve := g.stage(ctx, "inference.reserve")
	allowed, reserveErr := g.reserve(reserveCtx, tenant, n+input.MaxTokens)
	endReserve()
	if reserveErr != nil {
		outcome = "budget_unavailable"
		http.Error(w, "budget unavailable", 503)
		return
	}
	if !allowed {
		w.Header().Set("Retry-After", "60")
		outcome = "limited"
		http.Error(w, "token budget", 429)
		return
	}
	// Build a fresh allowlisted request: callers cannot inject a model path,
	// tools, backend URLs or a server-side chat template.
	payload, _ := json.Marshal(map[string]any{"messages": input.Messages,
		"max_tokens": input.MaxTokens, "stream": true, "temperature": 0, "cache_prompt": false, "stream_options": map[string]bool{"include_usage": true}})
	backendCtx, endBackend := g.stage(ctx, "inference.backend_stream")
	defer endBackend()
	outcome = "backend_error"
	req, err := http.NewRequestWithContext(backendCtx, http.MethodPost, g.url+"/v1/chat/completions", bytes.NewReader(payload))
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
			if err := state.accept(buf[:n]); err != nil {
				outcome = "protocol_error"
				g.failures.Add(1)
				return
			}
			// HTTP streaming requires a write deadline too: an upstream deadline
			// alone cannot unblock a write to a client that stopped reading.
			_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(5 * time.Second))
			if _, err := w.Write(buf[:n]); err != nil {
				outcome = "cancelled"
				g.failures.Add(1)
				return
			}
			if err := http.NewResponseController(w).Flush(); err != nil {
				outcome = "cancelled"
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
			if state.done {
				if state.first.IsZero() {
					outcome = "incomplete"
					g.failures.Add(1)
				} else {
					outcome = "complete"
				}
				return
			}
		}
		if readErr != nil {
			if readErr == io.EOF && state.done && !state.first.IsZero() {
				outcome = "complete"
			} else {
				outcome = "incomplete"
				if ctx.Err() != nil {
					outcome = "cancelled"
				}
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
	return LlamaTokenizerWithClient(url, &http.Client{})
}

func LlamaTokenizerWithClient(url string, client *http.Client) Tokenizer {
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
		w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"river\"}}]}\n\ndata: [DONE]\n\n"))
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
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"river\"}}]}\n\ndata: [DONE]\n\n"))
	}))
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

The telemetry hooks below are inert until Step 5 configures them. The stream observer keeps transport first byte separate from first nonempty content, requires the terminal event for successful completion, bounds SSE line buffering and uses authoritative usage rather than counting text chunks. A tokenizer transport failure is a backend error, not an invalid prompt.

<!-- file: gateway/internal/inference/observe.go -->
~~~go
package inference

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"
)

// Hooks are installed before serving. Names/outcomes are fixed strings; never
// pass prompts, credentials, answers or tenant identifiers to telemetry.
type Hooks struct {
	Stage  func(context.Context, string) (context.Context, func())
	Finish func(context.Context, string, time.Duration, time.Duration, int)
}

func (g *Gateway) UseHooks(h Hooks)                 { g.hooks = h }
func (g *Gateway) UseTransport(t http.RoundTripper) { g.client.Transport = t }
func (g *Gateway) InFlight() (active, admitted int) { return len(g.active), len(g.admitted) }
func (g *Gateway) stage(ctx context.Context, name string) (context.Context, func()) {
	if g.hooks.Stage != nil {
		return g.hooks.Stage(ctx, name)
	}
	return ctx, func() {}
}

type streamState struct {
	pending []byte
	first   time.Time
	done    bool
	tokens  int
}

func (s *streamState) accept(chunk []byte) error {
	s.pending = append(s.pending, chunk...)
	for {
		i := bytes.IndexByte(s.pending, '\n')
		if i < 0 {
			break
		}
		if i > 64<<10 {
			return errors.New("SSE line exceeds 64 KiB")
		}
		line := bytes.TrimSpace(s.pending[:i])
		s.pending = s.pending[i+1:]
		if !bytes.HasPrefix(line, []byte("data:")) {
			continue
		}
		data := bytes.TrimSpace(line[5:])
		if bytes.Equal(data, []byte("[DONE]")) {
			s.done = true
			continue
		}
		var event struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
			Usage *struct {
				Tokens int `json:"completion_tokens"`
			} `json:"usage"`
		}
		if err := json.Unmarshal(data, &event); err != nil {
			return err
		}
		if event.Usage != nil {
			s.tokens = event.Usage.Tokens
		}
		if len(event.Choices) > 0 && event.Choices[0].Delta.Content != "" && s.first.IsZero() {
			s.first = time.Now()
		}
	}
	if len(s.pending) > 64<<10 {
		return errors.New("SSE line exceeds 64 KiB")
	}
	return nil
}
~~~

<!-- file: gateway/internal/inference/observe_test.go -->
~~~go
package inference

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestContentTimingAndIncompleteStreams(t *testing.T) {
	for _, complete := range []bool{false, true} {
		t.Run(map[bool]string{false: "truncated", true: "complete"}[complete], func(t *testing.T) {
			backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				w.Write([]byte("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n"))
				http.NewResponseController(w).Flush()
				time.Sleep(80 * time.Millisecond)
				w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"river\"}}]}\n\n"))
				if complete {
					w.Write([]byte("data: {\"choices\":[],\"usage\":{\"completion_tokens\":1}}\n\ndata: [DONE]\n\n"))
				}
			}))
			defer backend.Close()
			g := New(backend.URL, identity, tokens, 1, 1, 100)
			var outcome string
			var first time.Duration
			var usage int
			g.UseHooks(Hooks{Finish: func(_ context.Context, o string, f, q time.Duration, n int) { outcome = o; first = f; usage = n }})
			if got := call(g, true).Code; got != 200 {
				t.Fatal(got)
			}
			if first < 70*time.Millisecond {
				t.Fatalf("role event incorrectly counted as first content: %v", first)
			}
			if complete && (outcome != "complete" || usage != 1) {
				t.Fatalf("%s tokens=%d", outcome, usage)
			}
			if !complete && outcome != "incomplete" {
				t.Fatalf("truncated stream counted as %s", outcome)
			}
		})
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

For traces, keep Phase 6/7's existing instrumentation: start at the authenticated API, add queue wait, template/tokenizer calls and upstream streaming spans; end the stream span only on the terminal event, EOF, cancellation or failure. Propagate the existing trace context via the instrumented HTTP transport. Never record prompts, bearer tokens, model answers or tenant IDs as unbounded metric labels. Compare the client TTFT with queue wait plus backend prefill plus network delay.

**Break it:** introduce a 2-second delay before the fake server's first content, while sending its role event immediately. Show that first-byte diagnostics can pass while the TTFT objective fails. Disable buffering at every proxy and verify with a timestamped client; a fast backend behind a buffering proxy still feels slow.

### Mount the real API and record first-content evidence

The earlier route fragment explains the boundary; this adapter connects it to the real Phase 7 `cmd/api` process. Copy the following file to `cmd/api/inference.go` in your Runway checkout, alongside the gateway and shared-reservation files already copied into `internal/inference`. It reuses Runway's JWT middleware, metric registry, trace provider and identity claims. The separate `generator` role (or `admin`) authorises generation; a job reader does not gain inference access merely by having a valid JWT.

The streaming route stays outside the jobs request-deadline middleware. Jobs retain their original write deadline; inference has a thirty-second admission/stream deadline and a per-write slow-consumer deadline. The server's outer write allowance accommodates that contract. Redis reservations fail closed across API instances; the adapter refuses to enable inference with authentication disabled.

<!-- file: runway-integration/api_inference.go -->
~~~go
package main

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"runway/internal/auth"
	"runway/internal/authz"
	"runway/internal/envconfig"
	"runway/internal/httpapi"
	"runway/internal/inference"
)

// mountInference extends the actual API composition root. Jobs retain their
// middleware/deadline; streaming has its own thirty-second admission deadline.
func mountInference(getenv envconfig.Getenv, metrics *httpapi.Metrics, authenticate func(http.Handler) http.Handler, jobs http.Handler, jobWriteTimeout time.Duration) (http.Handler, func(), error) {
	url := getenv("INFERENCE_UPSTREAM")
	if url == "" {
		return jobs, func() {}, nil
	}
	if getenv("AUTH_MODE") == "off" {
		return nil, nil, errors.New("inference requires JWT authentication")
	}
	addr := getenv("INFERENCE_REDIS_ADDR")
	if addr == "" {
		return nil, nil, errors.New("INFERENCE_REDIS_ADDR is required; shared accounting fails closed")
	}
	slots, err := envconfig.PositiveInt(getenv, "INFERENCE_SLOTS", 1)
	if err != nil {
		return nil, nil, err
	}
	queue, err := envconfig.PositiveInt(getenv, "INFERENCE_QUEUE", 8)
	if err != nil {
		return nil, nil, err
	}
	budget, err := envconfig.PositiveInt(getenv, "INFERENCE_TOKEN_BUDGET", 8192)
	if err != nil {
		return nil, nil, err
	}
	client := redis.NewClient(&redis.Options{Addr: addr})
	transport := otelhttp.NewTransport(http.DefaultTransport)
	g := inference.New(url, func(r *http.Request) (string, bool) { c, ok := auth.FromContext(r.Context()); return c.Tenant, ok }, inference.LlamaTokenizerWithClient(url, &http.Client{Transport: transport}), slots, queue, budget)
	g.UseReservation(inference.SharedReservation(client, "runway:inference:v1", budget))
	g.UseTransport(transport)
	outcomes := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "inference_outcomes_total", Help: "Authenticated generation outcomes, including rejections and incomplete streams."}, []string{"outcome"})
	good := prometheus.NewCounter(prometheus.CounterOpts{Name: "inference_good_total", Help: "Completed requests with first content observed at the gateway within one second."})
	ttft := prometheus.NewHistogram(prometheus.HistogramOpts{Name: "inference_first_content_seconds", Help: "First content at the gateway, not transport first byte; missing content excluded.", Buckets: []float64{.05, .1, .25, .5, 1, 2, 5, 10, 30}})
	waiting := prometheus.NewHistogram(prometheus.HistogramOpts{Name: "inference_queue_seconds", Help: "Time spent waiting for generation capacity.", Buckets: []float64{.001, .01, .05, .1, .25, .5, 1, 2, 5, 10, 30}})
	tokens := prometheus.NewCounter(prometheus.CounterOpts{Name: "inference_output_tokens_total", Help: "Authoritative completed output-token usage, when supplied."})
	statuses := prometheus.NewCounterVec(prometheus.CounterOpts{Name: "inference_http_total", Help: "Generation HTTP responses including authentication and authorization failures."}, []string{"code"})
	metrics.MustRegister(outcomes, good, ttft, waiting, tokens, statuses,
		prometheus.NewGaugeFunc(prometheus.GaugeOpts{Name: "inference_active", Help: "Active inference requests."}, func() float64 { a, _ := g.InFlight(); return float64(a) }),
		prometheus.NewGaugeFunc(prometheus.GaugeOpts{Name: "inference_waiting", Help: "Admitted requests waiting for active capacity."}, func() float64 { a, n := g.InFlight(); return float64(max(0, n-a)) }))
	tracer := otel.Tracer("runway.inference")
	g.UseHooks(inference.Hooks{
		Stage: func(ctx context.Context, name string) (context.Context, func()) {
			ctx, span := tracer.Start(ctx, name)
			return ctx, func() { span.End() }
		},
		Finish: func(ctx context.Context, outcome string, first, queue time.Duration, n int) {
			outcomes.WithLabelValues(outcome).Inc()
			waiting.Observe(queue.Seconds())
			if first >= 0 {
				ttft.Observe(first.Seconds())
			}
			if outcome == "complete" && first >= 0 && first <= time.Second {
				good.Inc()
			}
			if outcome == "complete" && n >= 0 {
				tokens.Add(float64(n))
			}
			span := trace.SpanFromContext(ctx)
			span.SetAttributes(attribute.String("inference.outcome", outcome), attribute.Int64("inference.queue_ms", queue.Milliseconds()))
			if first >= 0 {
				span.SetAttributes(attribute.Int64("inference.first_content_ms", first.Milliseconds()))
			}
		},
	})
	action := authz.Action("inference.generate")
	policy := authz.Policy{"generator": {action}, "admin": {action}}
	allowed := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !policy.Decide(r.Context(), action).Allow {
			http.Error(w, "permission denied", 403)
			return
		}
		g.ServeHTTP(w, r)
	})
	protected := authenticate(allowed)
	mux := http.NewServeMux()
	mux.Handle("POST /v1/chat/completions", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		recorder := &inferenceStatus{ResponseWriter: w}
		protected.ServeHTTP(recorder, r)
		code := recorder.code
		if code == 0 {
			code = 200
		}
		statuses.WithLabelValues(strconv.Itoa(code)).Inc()
	}))
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(jobWriteTimeout))
		jobs.ServeHTTP(w, r)
	}))
	return mux, func() { _ = client.Close() }, nil
}

type inferenceStatus struct {
	http.ResponseWriter
	code int
}

func (w *inferenceStatus) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *inferenceStatus) WriteHeader(code int) {
	if w.code == 0 {
		w.code = code
	}
	w.ResponseWriter.WriteHeader(code)
}
func (w *inferenceStatus) Write(b []byte) (int, error) {
	if w.code == 0 {
		w.code = 200
	}
	return w.ResponseWriter.Write(b)
}
~~~

In your existing `cmd/api/main.go`, replace the block beginning at `handler := httpapi.NewHandler(service, options...)` through the following `server := &http.Server{` with:

~~~go
handler := httpapi.NewHandler(service, options...)
handler, closeInference, err := mountInference(getenv, metrics, authenticate, handler, cfg.RequestTimeout+5*time.Second)
if err != nil { return err }
defer closeInference()
writeTimeout := cfg.RequestTimeout + 5*time.Second
if getenv("INFERENCE_UPSTREAM") != "" { writeTimeout = 35*time.Second }
server := &http.Server{
~~~

Set that server's existing `WriteTimeout` field to `writeTimeout`. All other startup/shutdown, TLS, workers, persistence and gRPC wiring stays in the existing composition root. This integration source depends on the Phase 7 module; the stdlib-only gateway replay does not pretend to compile the entire API or deploy telemetry.

Configure `INFERENCE_UPSTREAM`, `INFERENCE_REDIS_ADDR`, `INFERENCE_SLOTS`, `INFERENCE_QUEUE` and `INFERENCE_TOKEN_BUDGET` on the API process. Keep the raw model and Redis endpoints private. Register a synthetic issuer client with `generator+submitter+reader`, and another with only `reader` for the denial test. Never put their secrets or bearer tokens in committed commands/evidence.

Scrape Runway's existing `/metrics`: `inference_outcomes_total` retains overload, limited, backend, cancellation and incomplete outcomes; `inference_good_total` counts only completed requests whose first content is observed at the gateway within one second. `inference_first_content_seconds` is a latency diagnostic, not a success-only SLO denominator. `inference_waiting` and `inference_active` expose approximate admission state; waiting is clamped at zero because channel lengths are sampled separately; output tokens come from usage. Use the client measurements for user-visible transport latency.

Send the existing API OTLP exporter to a real collector and inspect `inference.queue`, `inference.tokenize`, `inference.reserve` and `inference.backend_stream` plus the enclosing HTTP span. The instrumented tokenizer/upstream HTTP clients propagate trace context. None of these hooks records prompts, answers, tenant identifiers or credentials as span attributes/metric labels.

The [platform validation report](evidence/platform-validation/report.md) records the running environment, observed outcomes and retained live checks. A local in-memory jobs mode can verify real API startup/routing without asserting that database/broker production operation was revalidated.

## Step 6: Deploy a slow-starting dependency

A model server isn't like the Runway API. Its image is hundreds of megabytes, its weights are hundreds more, and it can take seconds or minutes before it can answer. Kubernetes' defaults assume a process that's ready in a second and can be replaced at any moment. This step deploys the model into Phase 5's cluster and measures what those differences cost:

| You'll measure | Why it matters |
|---|---|
| Whether the weights in the cluster are the ones you verified | A model is code you didn't write; the bytes must match the digest from Step 2 |
| Cold start and warm start, phase by phase | Scaling up only helps if a new copy is ready before the queue overflows |
| What users see while the model Pod is replaced | "Graceful shutdown" is a claim; measure it |
| What a too-short startup allowance does | The most common way to turn a slow start into an outage |
| Scaling on queue depth | CPU use says little about a decoder; waiting requests say a lot |

You need Phase 5's kind cluster, with Phase 5's Prometheus in `observability` and Phase 6's default-deny policies in `runway`.

### Weights into the cluster

The model needs a volume, and something to copy the file into it:

<!-- file: deploy/inference/weights.yaml -->
~~~yaml
# A volume for the model weights, and a short-lived Pod to copy them in.
# Delete the loader once the copy is verified; the volume stays.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: phase8-weights
  namespace: runway
spec:
  accessModes: [ReadWriteOnce] # one node at a time: every replica lands on that node
  resources:
    requests: { storage: 1Gi }
---
apiVersion: v1
kind: Pod
metadata:
  name: weights-loader
  namespace: runway
spec:
  # The namespace refuses root Pods (Phase 5's "restricted" Pod Security).
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: loader
      image: busybox:1.37
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
      volumeMounts:
        - { name: weights, mountPath: /models }
  volumes:
    - name: weights
      persistentVolumeClaim: { claimName: phase8-weights }
~~~

Phase 5 set the `runway` namespace to the **restricted** Pod Security level, so every Pod must say it runs as a non-root user, can't gain privileges, drops all Linux capabilities and uses the default seccomp filter. Leave those settings out and the namespace refuses the Pod:

~~~text
Error from server (Forbidden): pods "pss-check" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "pss-check" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "pss-check" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "pss-check" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "pss-check" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
~~~

Copy the verified file in, then check its digest *inside* the cluster:

~~~bash
kubectl apply -f deploy/inference/weights.yaml
kubectl -n runway wait --for=condition=Ready pod/weights-loader --timeout=3m
kubectl -n runway cp models/qwen2.5-0.5b-instruct-q4_k_m.gguf weights-loader:/models/model.gguf
kubectl -n runway exec weights-loader -- sha256sum /models/model.gguf
~~~

~~~text
74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db  /models/model.gguf
~~~

That's the digest Step 2 recorded. The copy took 9 s. Delete the loader; the volume and the file stay:

~~~bash
kubectl -n runway delete pod weights-loader
~~~

The volume is `ReadWriteOnce`: it can be mounted on one node at a time. kind's storage puts it on one node (`runway-worker`, for me), so every replica of the model must run on that node. On a real cluster, that's the first thing that stops scaling. Weight distribution (a read-only copy per node, or an image that contains the weights) is part of the design, not a detail.

### The model Deployment

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
    type: Recreate # the laptop has room for few copies of the weights
  selector:
    matchLabels: { app: llm }
  template:
    metadata:
      labels: { app: llm }
      annotations: # Phase 5's Prometheus scrapes Pods that ask for it
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: /metrics
    spec:
      automountServiceAccountToken: false # the model never calls the Kubernetes API
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: server
          image: ghcr.io/ggml-org/llama.cpp@sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b
          args: ["-m", "/models/model.gguf", "--host", "0.0.0.0", "--port", "8080",
                 "-c", "4096", "-t", "2", "--parallel", "1", "--metrics"]
          ports: [{ name: http, containerPort: 8080 }]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          resources:
            requests: { cpu: "1", memory: 768Mi }
            limits: { cpu: "2", memory: 1536Mi }
          # Loading may take minutes: allow up to 120 x 5 s before giving up.
          startupProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
            failureThreshold: 120
          # After start-up: stop routing here while it can't answer.
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
          volumeMounts:
            - { name: weights, mountPath: /models, readOnly: true }
      volumes:
        - name: weights
          persistentVolumeClaim: { claimName: phase8-weights, readOnly: true }
---
apiVersion: v1
kind: Service
metadata: { name: llm, namespace: runway }
spec:
  selector: { app: llm }
  ports: [{ name: http, port: 8080, targetPort: http }]
~~~

Three probes, three questions:

- The **startup probe** asks "has it finished loading?" It allows up to 120 × 5 s = 10 minutes. Until it passes, Kubernetes runs no other probe, so a slow load isn't mistaken for a hang.
- The **readiness probe** asks "should it get traffic right now?" A Pod that fails it is taken out of the Service but not restarted.
- There's no **liveness probe**. One that's too strict would restart a model that's busy decoding a long answer. A restart costs a reload, so add one only for a failure you've actually seen, with a generous threshold.

The annotations ask Phase 5's Prometheus to scrape the server's `/metrics`. `readOnlyRootFilesystem` works because llama-server writes nothing to disk.

Phase 6's default-deny policy blocks everything until a policy allows it. The model answers the API, Prometheus and, in this lab, a probe Pod; it calls nobody:

<!-- file: deploy/inference/llm-policy.yaml -->
~~~yaml
# The namespace denies all traffic by default (Phase 6). The model answers only
# the API, Prometheus and, in this lab, the probe Pod; it calls nobody.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: llm
  namespace: runway
spec:
  podSelector: { matchLabels: { app: llm } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app: api } }
        - podSelector: { matchLabels: { role: llm-probe } }
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: observability } }
          podSelector: { matchLabels: { app: prometheus } }
      ports: [{ port: 8080 }]
  egress: []
---
# The lab's probe may reach the model, and nothing else.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: llm-probe
  namespace: runway
spec:
  podSelector: { matchLabels: { role: llm-probe } }
  policyTypes: [Ingress, Egress]
  ingress: []
  egress:
    - to: [{ podSelector: { matchLabels: { app: llm } } }]
      ports: [{ port: 8080 }]
~~~

When you wire Step 5's API into the cluster, its own egress policy needs `llm:8080` too.

### Measure start-up

Kubernetes records when each Pod was scheduled, when its container started and when it became ready. This reads them:

<!-- file: serve/src/serve/podtimes.py -->
~~~python
"""How long did a pod take to be scheduled, start and become ready? Ask Kubernetes.

  kubectl -n runway get pods -l app=llm -o json | uv run python -m serve.podtimes

Times are seconds after the pod was created. Kubernetes stores them to the second,
so differences of a second or two are noise.
"""

import json
import sys
from datetime import datetime


def _at(stamp: str | None) -> datetime | None:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")) if stamp else None


def phases(pod: dict) -> dict:
    created = _at(pod["metadata"]["creationTimestamp"])
    true = {c["type"]: c for c in pod["status"].get("conditions", []) if c["status"] == "True"}
    container = (pod["status"].get("containerStatuses") or [{}])[0]
    running = container.get("state", {}).get("running", {})

    def since(stamp):
        at = _at(stamp)
        return None if at is None else (at - created).total_seconds()

    return {
        "pod": pod["metadata"]["name"],
        "scheduled": since(true.get("PodScheduled", {}).get("lastTransitionTime")),
        "started": since(running.get("startedAt")),  # the latest start, after any restart
        "ready": since(true.get("Ready", {}).get("lastTransitionTime")),
        "restarts": container.get("restartCount", 0),
    }


def main() -> None:
    data = json.load(sys.stdin)
    pods = data["items"] if data.get("kind") == "List" else [data]
    print(f"{'pod':<26} {'scheduled':>9} {'started':>8} {'ready':>6} {'restarts':>8}")
    for p in map(phases, pods):
        cells = [
            ("-" if p[k] is None else f"{p[k]:.0f}") for k in ("scheduled", "started", "ready")
        ]
        print(f"{p['pod']:<26} {cells[0]:>9} {cells[1]:>8} {cells[2]:>6} {p['restarts']:>8}")


if __name__ == "__main__":
    main()
~~~

<!-- file: serve/tests/test_podtimes.py -->
~~~python
from serve.podtimes import phases


def pod(ready=True):
    conditions = [
        {"type": "PodScheduled", "status": "True", "lastTransitionTime": "2026-11-13T10:00:01Z"},
        {
            "type": "Ready",
            "status": "True" if ready else "False",
            "lastTransitionTime": "2026-11-13T10:00:31Z",
        },
    ]
    return {
        "metadata": {"name": "llm-1", "creationTimestamp": "2026-11-13T10:00:00Z"},
        "status": {
            "conditions": conditions,
            "containerStatuses": [
                {"restartCount": 2, "state": {"running": {"startedAt": "2026-11-13T10:00:27Z"}}}
            ],
        },
    }


def test_phases_are_seconds_after_creation():
    assert phases(pod()) == {
        "pod": "llm-1",
        "scheduled": 1,
        "started": 27,
        "ready": 31,
        "restarts": 2,
    }


def test_a_pod_that_is_not_ready_has_no_ready_time():
    assert phases(pod(ready=False))["ready"] is None
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_podtimes.py -->

Now deploy. The image isn't on any node yet, so this is a true cold start:

~~~bash
kubectl apply -f deploy/inference/llm-policy.yaml -f deploy/inference/llm.yaml
kubectl -n runway rollout status deployment/llm --timeout=10m
kubectl -n runway get pods -l app=llm -o json | (cd serve && uv run python -m serve.podtimes)
kubectl -n runway get events --field-selector reason=Pulled -o custom-columns=MESSAGE:.message
~~~

~~~text
pod                        scheduled  started  ready restarts
llm-75974b7f6c-fddvp               0      169    175        0
Successfully pulled image "ghcr.io/ggml-org/llama.cpp@sha256:e67d88af...f78b" in 2m48.799s (2m48.799s including waiting). Image size: 309499562 bytes.
~~~

Of the 175 seconds, 169 were spent pulling a 309 MB image. Loading the model took about 6 seconds. A node pulls an image once, so the next start on the same node skips that part. If a new replica lands on a node that has never run the model, it pays the whole 169 s again. That's why clusters that serve models pre-pull images onto their nodes.

### Probe from inside the cluster

To see what users see, send requests from inside the cluster, through the Service, as the API would. This needs only the standard library and Step 2's `stream.py`:

<!-- file: serve/src/serve/probe.py -->
~~~python
"""Send requests to a model server for a while, and report what users saw.

It needs only the standard library, so it runs in a plain Python container inside
the cluster, where it reaches the model through its Service like the API would.

  python -m serve.probe http://llm:8080 --seconds 60             # one at a time
  python -m serve.probe http://llm:8080 --seconds 120 --workers 6 --max-tokens 128
"""

import argparse
import json
import threading
import time
from collections import Counter

from serve.stream import chat


def outage(rows: list[dict]) -> float | None:
    """Seconds from the first failed request to the next one that succeeded."""
    rows = sorted(rows, key=lambda r: r["start"])
    first = next((r for r in rows if r["error"]), None)
    if first is None:
        return None
    back = next((r for r in rows if r["start"] > first["start"] and not r["error"]), None)
    return None if back is None else round(back["start"] - first["start"], 2)


def summarise(rows: list[dict]) -> dict:
    ok = sorted(r["ttft"] for r in rows if not r["error"])
    return {
        "requests": len(rows),
        "completed": len(ok),
        "failed": dict(Counter(r["error"] for r in rows if r["error"])),
        "ttft_p50": round(ok[len(ok) // 2], 2) if ok else None,
        "ttft_max": round(ok[-1], 2) if ok else None,
        "outage_seconds": outage(rows),
    }


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("url")
    p.add_argument("--seconds", type=float, default=60)
    p.add_argument("--workers", type=int, default=1)
    p.add_argument("--every", type=float, default=0.25, help="pause between one worker's requests")
    p.add_argument("--max-tokens", type=int, default=4)
    p.add_argument("--rows", action="store_true", help="print every request, then the summary")
    a = p.parse_args()
    prompt = "Count from one to one thousand." if a.max_tokens > 8 else "Say yes."
    epoch = time.monotonic()
    stop = epoch + a.seconds
    rows: list[dict] = []
    lock = threading.Lock()

    def worker():
        while time.monotonic() < stop:
            start = time.monotonic() - epoch
            t = chat(a.url, prompt, a.max_tokens, timeout=60)
            row = {"start": round(start, 2), "total": round(t.total, 2), "error": t.error}
            row["ttft"] = None if t.ttft is None else round(t.ttft, 2)
            with lock:
                rows.append(row)
            time.sleep(a.every)

    threads = [threading.Thread(target=worker) for _ in range(a.workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if a.rows:
        for row in sorted(rows, key=lambda r: r["start"]):
            print(json.dumps(row))
    print(json.dumps(summarise(rows)))


if __name__ == "__main__":
    main()
~~~

<!-- file: serve/tests/test_probe.py -->
~~~python
from serve.probe import outage, summarise


def test_outage_runs_from_first_failure_to_next_success():
    rows = [
        {"start": 0.0, "error": "", "ttft": 0.1},
        {"start": 0.5, "error": "status 503", "ttft": None},
        {"start": 1.0, "error": "[Errno 111] Connection refused", "ttft": None},
        {"start": 4.25, "error": "", "ttft": 0.3},
    ]
    s = summarise(rows)
    assert s["outage_seconds"] == 3.75 and s["completed"] == 2 and s["ttft_max"] == 0.3
    assert s["failed"] == {"status 503": 1, "[Errno 111] Connection refused": 1}
    assert outage(rows[:1]) is None
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_probe.py -->

It runs in a plain Python container. Its code comes from a ConfigMap, so no image needs building:

<!-- file: deploy/inference/probe.yaml -->
~~~yaml
# A Pod that sends requests to the model from inside the cluster.
# Its code comes from a ConfigMap; see the commands in the guide.
apiVersion: v1
kind: Pod
metadata:
  name: llm-probe
  namespace: runway
  labels: { role: llm-probe }
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: probe
      image: python:3.12-slim
      command: ["sleep", "infinity"]
      env:
        - { name: PYTHONPATH, value: /code }
        - { name: PYTHONDONTWRITEBYTECODE, value: "1" }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: [ALL] }
      volumeMounts:
        - { name: code, mountPath: /code/serve }
  volumes:
    - name: code
      configMap: { name: llm-probe-code }
~~~

~~~bash
kubectl -n runway create configmap llm-probe-code \
  --from-file=serve/src/serve/stream.py --from-file=serve/src/serve/probe.py
kubectl apply -f deploy/inference/probe.yaml
kubectl -n runway wait --for=condition=Ready pod/llm-probe --timeout=5m
kubectl -n runway exec llm-probe -- python -m serve.probe http://llm:8080 --seconds 5
~~~

~~~text
{"requests": 6, "completed": 6, "failed": {}, "ttft_p50": 0.55, "ttft_max": 0.63, "outage_seconds": null}
~~~

Check that the policy really is what lets it through. Remove the probe's label, and the same request has nowhere to go:

~~~bash
kubectl -n runway label pod llm-probe role-
kubectl -n runway exec llm-probe -- python -m serve.probe http://llm:8080 --seconds 1
kubectl -n runway label pod llm-probe role=llm-probe
~~~

~~~text
{"requests": 1, "completed": 0, "failed": {"timed out": 1}, "ttft_p50": null, "ttft_max": null, "outage_seconds": null}
~~~

The request waited out its full 60-second timeout: the policy dropped the connection without an answer. Put the label back before going on.

### Replace the model while users wait

Kubernetes replaces Pods all the time: node upgrades, rollouts, evictions. Delete the model Pod while three probe workers keep sending requests:

~~~bash
kubectl -n runway exec llm-probe -- \
  python -m serve.probe http://llm:8080 --seconds 60 --workers 3 --rows > replace.txt &
sleep 10
kubectl -n runway delete pod -l app=llm --wait=false
wait
tail -1 replace.txt
grep -v '"error": ""' replace.txt | head -3
~~~

~~~text
{"requests": 47, "completed": 44, "failed": {"Remote end closed connection without response": 2, "incomplete or empty stream": 1}, "ttft_p50": 1.7, "ttft_max": 2.0, "outage_seconds": 31.76}
{"start": 7.82, "total": 31.5, "error": "incomplete or empty stream", "ttft": 1.71}
{"start": 8.51, "total": 30.82, "error": "Remote end closed connection without response", "ttft": null}
{"start": 9.25, "total": 30.08, "error": "Remote end closed connection without response", "ttft": null}
~~~

The replacement Pod was ready about 5 s after it was created. But the three requests that were on the old Pod when it was deleted, one streaming and two queued behind it, hung for **30 seconds** and then failed. Kubernetes sent the server SIGTERM; it stopped generating but didn't close its connections. Kubernetes waited out the default 30-second grace period, then killed it. For those users, a routine Pod replacement was a 30-second failure.

The fix is a **preStop hook**: a command Kubernetes runs *before* it sends SIGTERM. Wait two seconds for the Service to stop sending new work here, then wait until the server's own counters show nothing in progress and nothing queued:

<!-- edit: deploy/inference/llm.yaml -->
~~~yaml
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
          volumeMounts:
~~~
~~~yaml
          readinessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 5
          # Before Kubernetes sends SIGTERM: wait for the Service to stop sending
          # new work, then for the requests already here to finish. All within
          # the 30 s grace period, after which the container is killed anyway.
          lifecycle:
            preStop:
              exec:
                command:
                  - sh
                  - -c
                  - |
                    sleep 2
                    for i in $(seq 1 50); do
                      curl -s localhost:8080/metrics |
                        grep -qE '^llamacpp:requests_(processing|deferred) [1-9]' || exit 0
                      sleep 0.5
                    done
          volumeMounts:
~~~

~~~bash
kubectl apply -f deploy/inference/llm.yaml
kubectl -n runway rollout status deployment/llm --timeout=5m
~~~

Run the same replacement again, twice:

~~~text
{"requests": 84, "completed": 84, "failed": {}, "ttft_p50": 1.76, "ttft_max": 2.33, "outage_seconds": null}
{"requests": 89, "completed": 89, "failed": {}, "ttft_p50": 1.68, "ttft_max": 1.96, "outage_seconds": null}
~~~

Every request completed, both times. There's a detail of current Kubernetes behind this. When a Service has no ready Pods, it keeps sending traffic to Pods that are shutting down but still pass their readiness probe. With the hook, the old server keeps working, so it carries the traffic until the new Pod is ready. Then it goes idle, the hook exits, and SIGTERM finds nothing to interrupt.

The hook must fit inside the grace period: 2 s plus at most 25 s of waiting, within 30 s. If your longest answer takes longer than that, raise `terminationGracePeriodSeconds`, or the kill arrives mid-answer anyway.

**Break it:** give the model less time to start than it needs. One second, one try:

~~~bash
kubectl -n runway patch deployment llm --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/periodSeconds","value":1},
  {"op":"replace","path":"/spec/template/spec/containers/0/startupProbe/failureThreshold","value":1}]'
sleep 100
kubectl -n runway get pods -l app=llm
kubectl -n runway get events --field-selector reason=Unhealthy -o custom-columns=COUNT:.count,MSG:.message
kubectl -n runway exec llm-probe -- python -m serve.probe http://llm:8080 --seconds 5
~~~

~~~text
NAME                  READY   STATUS             RESTARTS      AGE
llm-867bfcbd9-m87xt   0/1     CrashLoopBackOff   4 (38s ago)   98s
1       Startup probe failed: HTTP probe failed with statuscode: 503
6       Readiness probe failed: Get "http://10.244.2.5:8080/health": dial tcp 10.244.2.5:8080: connect: connection refused
5       Startup probe failed: HTTP probe failed with statuscode: 503
{"requests": 1, "completed": 0, "failed": {"timed out": 1}, "ttft_p50": null, "ttft_max": null, "outage_seconds": null}
~~~

The server answers 503 while it loads, so the first check fails, Kubernetes kills it, and it starts loading again: four restarts in 98 seconds, and the back-off between attempts keeps growing. And because the Deployment uses `Recreate`, the old, working Pod was removed *first*, so nothing at all was serving. A bad configuration change became a complete outage. With `RollingUpdate`, the old Pod would have kept serving while the new one failed, but that needs room for a second copy of the weights. Restore the measured allowance:

~~~bash
kubectl apply -f deploy/inference/llm.yaml
kubectl -n runway rollout status deployment/llm --timeout=5m
~~~

Mine was ready again 6 s later, and all six probe requests completed.

### Scale on queue depth

CPU is a poor scaling signal for a decoder. It's limited by memory bandwidth, and it can look much the same idle or swamped. A better signal is how many requests are waiting. llama-server exports that as `llamacpp:requests_deferred`, and Phase 5's Prometheus is already scraping it:

~~~bash
kubectl -n observability port-forward svc/prometheus 19090:9090 &
curl -s 127.0.0.1:19090/api/v1/query --data-urlencode 'query=llamacpp:requests_deferred'
~~~

The result carries `namespace="runway"` and `pod="llm-..."` labels, from Phase 5's scrape configuration. A HorizontalPodAutoscaler can't query Prometheus, though; it reads metrics from the Kubernetes API. The **Prometheus adapter** sits between them: it serves chosen Prometheus series as Kubernetes metrics.

<!-- file: deploy/inference/adapter-values.yaml -->
~~~yaml
# Values for the official Prometheus adapter chart (prometheus-community/
# prometheus-adapter 5.4.1). It turns one Prometheus series into a metric the
# Kubernetes API serves, so a HorizontalPodAutoscaler can read it.
prometheus:
  url: http://prometheus.observability.svc
  port: 9090
metricsRelistInterval: 15s # how soon a new Pod's series is found
rules:
  default: false # serve only what we ask for
  custom:
    # Requests waiting inside each model server, per Pod. Phase 5's scrape
    # config adds the namespace and pod labels the adapter maps to objects.
    - seriesQuery: 'llamacpp:requests_deferred{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: { resource: namespace }
          pod: { resource: pod }
      name:
        matches: "^llamacpp:requests_deferred$"
        as: llm_requests_waiting
      metricsQuery: sum(<<.Series>>{<<.LabelMatchers>>}) by (<<.GroupBy>>)
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits: { memory: 384Mi }
~~~

Phase 5 lets only Grafana query Prometheus. Policies add up, so a second one admits the adapter, without editing Phase 5's:

<!-- file: deploy/inference/adapter-policy.yaml -->
~~~yaml
# Phase 5 lets only Grafana query Prometheus. Policies add up, so this one
# admits the adapter as well, without editing Phase 5's file.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: prometheus-from-adapter
  namespace: observability
spec:
  podSelector: { matchLabels: { app: prometheus } }
  policyTypes: [Ingress]
  ingress:
    - from: [{ podSelector: { matchLabels: { app.kubernetes.io/name: prometheus-adapter } } }]
      ports: [{ port: 9090 }]
~~~

~~~bash
kubectl apply -f deploy/inference/adapter-policy.yaml
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install llm-adapter prometheus-community/prometheus-adapter --version 5.4.1 \
  -n observability -f deploy/inference/adapter-values.yaml --wait
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/runway/pods/*/llm_requests_waiting"
~~~

After about 20 seconds, the Kubernetes API answers with one item per model Pod: `"metricName": "llm_requests_waiting"` and `"value": "0"`.

Now the autoscaler. It aims for an average of two waiting requests per Pod:

<!-- file: deploy/inference/hpa.yaml -->
~~~yaml
# Scale the model on how many requests wait inside it, not on CPU: a decoder
# is limited by memory bandwidth, and its CPU can look the same idle or swamped.
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: llm, namespace: runway }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: llm }
  minReplicas: 1
  maxReplicas: 2 # the laptop has room for two copies of the weights
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300 # don't drop a replica that took time to load
  metrics:
    - type: Pods
      pods:
        metric: { name: llm_requests_waiting }
        target: { type: AverageValue, averageValue: "2" }
~~~

With one model Pod and six requests in flight, one is processed and five wait. The autoscaler wants `ceil(1 × 5 ÷ 2) = 3` replicas, and is capped at 2. With two Pods, each has about two waiting, which is the target, so it holds there.

This script prints what the autoscaler sees every 2 seconds:

<!-- file: deploy/inference/watch-hpa.sh -->
~~~bash
#!/bin/sh
# Print the autoscaler's view every 2 seconds: what it measured, how many
# replicas it wants, and how many model Pods are ready. Stop with Ctrl-C.
start=$(date +%s)
get() { kubectl -n runway get "$1" -o jsonpath="$2" 2>/dev/null; }
while true; do
  waiting=$(get hpa/llm '{.status.currentMetrics[0].pods.current.averageValue}')
  desired=$(get hpa/llm '{.status.desiredReplicas}')
  ready=$(get deployment/llm '{.status.readyReplicas}')
  printf '%4ss  waiting/pod=%-5s desired=%-2s ready=%s\n' \
    "$(( $(date +%s) - start ))" "${waiting:--}" "${desired:--}" "${ready:-0}"
  sleep 2
done
~~~

<!-- run: sh -n deploy/inference/watch-hpa.sh -->

Apply the autoscaler, start the watcher in a second terminal, then offer six long requests at a time for 150 seconds:

~~~bash
kubectl apply -f deploy/inference/hpa.yaml
sh deploy/inference/watch-hpa.sh            # in a second terminal
kubectl -n runway exec llm-probe -- \
  python -m serve.probe http://llm:8080 --seconds 150 --workers 6 --max-tokens 128
~~~

The watcher, from just before the load started:

~~~text
   9s  waiting/pod=0     desired=1  ready=1
  11s  waiting/pod=0     desired=1  ready=1
  14s  waiting/pod=0     desired=1  ready=1
  17s  waiting/pod=5     desired=2  ready=1
  19s  waiting/pod=5     desired=2  ready=1
  22s  waiting/pod=5     desired=2  ready=2
  25s  waiting/pod=5     desired=2  ready=2
  28s  waiting/pod=5     desired=2  ready=2
  31s  waiting/pod=4     desired=2  ready=2
  34s  waiting/pod=4     desired=2  ready=2
~~~

The load started at about 4 s. By 17 s the adapter reported five requests waiting and the autoscaler asked for a second replica, which was ready at 22 s. That's quick because the image was already on the node and the weights were in its page cache: on a node that had never run the model, add the 169-second pull from earlier. Later samples show values such as `2500m` and `1500m`: Kubernetes' way of writing 2.5 and 1.5, averages across the two Pods.

The load stopped at about 158 s. The autoscaler waited out its 300-second stabilisation window, then removed the second replica:

~~~text
 463s  waiting/pod=0     desired=2  ready=2
 466s  waiting/pod=0     desired=2  ready=2
 468s  waiting/pod=0     desired=1  ready=1
 471s  waiting/pod=0     desired=1  ready=1
 473s  waiting/pod=0     desired=1  ready=1
 475s  waiting/pod=0     desired=1  ready=1
~~~

The probe's summary, then each Pod's token counter, read from inside the cluster (run the loop before the load too, and subtract):

~~~bash
for ip in $(kubectl -n runway get pods -l app=llm -o jsonpath='{.items[*].status.podIP}'); do
  kubectl -n runway exec llm-probe -- python -c "import urllib.request
for line in urllib.request.urlopen('http://$ip:8080/metrics').read().decode().splitlines():
    if line.startswith('llamacpp:tokens_predicted_total'): print('$ip', line)"
done
~~~

~~~text
{"requests": 34, "completed": 34, "failed": {}, "ttft_p50": 25.52, "ttft_max": 56.1, "outage_seconds": null}
10.244.2.14 llamacpp:tokens_predicted_total 1280
10.244.2.13 llamacpp:tokens_predicted_total 5504
~~~

| | Requests started in the first 20 s (mostly one Pod) | Requests started after 60 s (two Pods) |
|---|---|---|
| Median time to decode one 128-token answer | 5.8 s | 8.1 s |
| Tokens per second, all Pods together (128 ÷ decode time × Pods) | about 22 | about 32 |

Before the load, the first Pod's counter read 2,432 and the second Pod didn't exist. So the old Pod generated 3,072 tokens during the run (24 answers of 128 tokens) and the new one 1,280 (10 answers). Every request completed, and both Pods did work. But two things in these numbers matter more than the scaling itself:

- **The second replica added about 40% throughput, not 100%.** Both Pods run on `runway-worker`, because the `ReadWriteOnce` volume is there, so they share its CPUs and memory bandwidth, and each decodes more slowly. A replica on another node wouldn't share them; I couldn't measure that here, because the volume pins every replica to one node. That's the weight-distribution problem from the start of this step, now measured.
- **The target decides the latency, and this one is too loose.** "Two waiting per Pod" means a request waits for about two 8-second answers before its own starts. The median wait for first content was 25.5 s, and the slowest was 56 s. Choose the target the way Step 9 chose the queue length: from the time budget. Waiting requests × time per answer must fit inside your time-to-first-token objective. For Step 5's one second, no number of waiting requests fits, so the honest conclusion is that this laptop can't offer that objective for long answers at this load. Measuring tells you that before users do.

**Done when:** the weights' digest matches inside the cluster, you have cold and warm start timelines, a Pod replacement under load completes every request, and the model scales out on queue depth and back in. Keep the outputs; Step 14's report uses them. Mine are in [evidence/2026-11-13-kubernetes](evidence/2026-11-13-kubernetes/README.md).

**What this proves, and what it doesn't.** It proves the model runs under the namespace's security rules and network policy, that replacing it no longer drops requests, and that queue depth drives scaling on this cluster. It doesn't prove anything about a cluster with many nodes: here every replica shares one node and one copy of the volume, so a second replica adds a second decoder, not more memory bandwidth from a second machine. Nor does it cover the gateway: in the full system the queue sits in Step 4's admission queue, and you'd scale on the gateway's waiting gauge instead. The [platform report](evidence/platform-validation/report.md) did that once, through the real API.

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

**Break it, with evidence:** deploy an unsigned image (admission must reject); change one byte of `model.gguf` while keeping its bundle (startup must refuse); remove the bundle (startup must refuse); replace the public key with another key (verification must fail); restore the authorised artifact (readiness must return). Capture each command, exit status and event. The [dated CPU evidence](evidence/2026-11-07/report.md) exercises the weight verification/refusal cases and recovery. The [platform validation report](evidence/platform-validation/report.md) adds live image-admission, startup-verification and rollback evidence; the local signer is still a lab trust authority. Never paste the private key into the transcript.

### Bind the verifier to the reviewed release

The live deployment uses this stricter entrypoint. It copies the input artifacts into a private `emptyDir`, verifies that copy, and opens the fixed server port only after success. The authorised manifest digest is compiled into the launcher; the image contains the public model key and public Sigstore trust root. Pod environment variables and arguments cannot select another key, model or manifest. The running model reads the verified private copy, so a later write to the source PVC does not change the file it opens.

<!-- file: deploy/inference/launcher.go -->
~~~go
// A release-bound entrypoint: copy, verify, then start the fixed model server.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

var expectedManifest string // set by the reviewed build, never from Pod env
func fatal(err error)       { fmt.Fprintln(os.Stderr, "model startup refused:", err); os.Exit(1) }
func digest(path string) (string, error) {
	f, e := os.Open(path)
	if e != nil {
		return "", e
	}
	defer f.Close()
	h := sha256.New()
	if _, e = io.Copy(h, f); e != nil {
		return "", e
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
func main() {
	names := []string{"manifest.json", "manifest.sigstore.json", "model.gguf", "weights.spdx.json", "provenance.json"}
	for _, name := range names {
		src, e := os.Open(filepath.Join("/models", name))
		if e != nil {
			fatal(e)
		}
		dst, e := os.OpenFile(filepath.Join("/verified", name), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
		if e != nil {
			src.Close()
			fatal(e)
		}
		_, e = io.Copy(dst, src)
		src.Close()
		closeErr := dst.Close()
		if e != nil {
			fatal(e)
		}
		if closeErr != nil {
			fatal(closeErr)
		}
	}
	got, e := digest("/verified/manifest.json")
	if e != nil {
		fatal(e)
	}
	if len(expectedManifest) != 64 || got != expectedManifest {
		fatal(fmt.Errorf("unauthorised manifest digest"))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/local/bin/cosign", "verify-blob", "--key", "/trust/model.pub", "--trusted-root", "/trust/trusted_root.json", "--bundle", "/verified/manifest.sigstore.json", "/verified/manifest.json")
	cmd.Env = []string{"PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/tmp"}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if e = cmd.Run(); e != nil {
		fatal(e)
	}
	var m struct {
		SHA256 map[string]string `json:"sha256"`
	}
	data, e := os.ReadFile("/verified/manifest.json")
	if e != nil {
		fatal(e)
	}
	if e = json.Unmarshal(data, &m); e != nil {
		fatal(e)
	}
	for _, name := range []string{"model.gguf", "weights.spdx.json", "provenance.json"} {
		got, e = digest(filepath.Join("/verified", name))
		if e != nil {
			fatal(e)
		}
		if got != m.SHA256[name] {
			fatal(fmt.Errorf("digest mismatch: %s", name))
		}
	}
	for _, name := range names {
		if e = os.Chmod(filepath.Join("/verified", name), 0444); e != nil {
			fatal(e)
		}
	}
	fmt.Println("verified private copy: model, SBOM, provenance and authorised manifest")
	args := []string{"/app/llama-server", "-m", "/verified/model.gguf", "--host", "0.0.0.0", "--port", "8080", "-c", "4096", "-t", "2", "--parallel", "1", "--metrics"}
	if e = syscall.Exec(args[0], args, []string{"PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/tmp", "LD_LIBRARY_PATH=/app"}); e != nil {
		fatal(e)
	}
}
~~~

<!-- run: CGO_ENABLED=0 go build -o /tmp/phase8-launcher-check deploy/inference/launcher.go -->

For the release build, set `-ldflags "-X main.expectedManifest=$MANIFEST_SHA256"` to the reviewed manifest hash. Copy the compiled launcher and checksum-verified Cosign binary to `/usr/local/bin/`, and the model public key and verified public Sigstore trust root to `/trust/model.pub` and `/trust/trusted_root.json` in your derived server image. Set its entrypoint to the launcher, clear the inherited CMD, and run as UID/GID 1000. Mount only `/models` read-only, a private disk-backed `/verified` emptyDir, and `/tmp`; grant the nonroot user access to its emptyDirs with `fsGroup`. Never put the private signing key into this build context.

Image signatures alone do not prevent a user from replacing the entrypoint. Add a namespace-scoped native `ValidatingAdmissionPolicy` that pins the approved image digest and rejects command, argument, environment, extra container and trust-path mount overrides. Use restricted Pod Security, a read-only root filesystem, no service-account token and deployment RBAC that prevents unreviewed pod exec/volume access. The [retained deployment and policy](evidence/platform-validation/report.md) show the exact tested configuration. Model provenance still has the historical publisher-revision limitation; local signing does not repair it.

The pinned live tool pair was Cosign 3.1.4 with policy-controller 0.13.1 (chart 0.10.8). Its key-based image policy uses the legacy signature format. The isolated local registry test explicitly used `--use-signing-config=false --tlog-upload=false --new-bundle-format=false --registry-referrers-mode=legacy`; it tested the pinned public key, without claiming image transparency-log publication. The model's existing Sigstore bundle was verified separately against the public trust root. Production should adopt a reviewed signing configuration and compatible bundle policy rather than inherit these lab flags.

For a private TLS registry, this chart's `webhook.registryCaBundle` expects `{name: CONFIGMAP, key: ca.crt}`, not a map of PEM filenames. Inspect the rendered mount and test a valid signature as well as rejections: a TLS error that rejects every image does not demonstrate signature enforcement. The live negative cases now cover unsigned/wrong-key images, revoked trust, a fully stopped webhook, corrupted/missing weights, and verifier overrides.

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

Steps 4 to 8 built defences. The API returns 502 when the model is gone and 503 when the shared budget can't be checked. Admission refuses work it can't serve. Cancellation frees the model when a client leaves. A **game day** tests those defences on purpose: you break one thing at a time, watch what happens, and write it down. Finding out that a defence doesn't work is much cheaper on a quiet afternoon than during a real outage.

The rules:

1. **Write down what you expect first.** For each fault: what users should see, how you'll notice, what you'll do, and what counts as fixed. A drill with no prediction can't fail, so it can't teach you anything.
2. **One fault at a time.** With two faults at once, you can't tell which one caused what. If a drill fails, stop and fix the system before starting the next one.
3. **Four timestamps:** when the fault was injected, detected, mitigated and recovered. Use a monotonic clock: Phase 7 showed that the wall clock can jump.
4. **Recovered means users are served.** Here, that's ten requests in a row through the API that stream a complete, nonempty answer. A green `/health` only says a process started. One failure among the ten restarts the count.
5. **Run every drill twice.** A fault that recovered once might have been luck.

| Fault | How you cause it | What users should see | Mitigation | Fixed when |
|---|---|---|---|---|
| Model exits | `docker kill` the model | 502, at once | Restart the same verified release | Ten good streams |
| Redis is down | `docker stop` Redis | 503: without the shared budget there's no generation (Step 4 fails closed) | Restart Redis | Ten good streams |
| Overload | 18 long requests at the same instant | Some 503s within milliseconds; admitted requests still get answers | None: admission sheds the excess | The queue drains, then ten good streams |
| Client leaves mid-answer | Reset the connection while tokens stream | Nothing: that client is gone | Cancellation reaches the model | The model's slot is idle within 8 s |
| Scraper is down | `docker stop` Prometheus | Nothing: requests still succeed | Restart Prometheus | Ten good streams |
| Model runs out of memory | Shrink the model container's limit to 32 MiB | 502 once the kernel kills the model | Restore the limit, then restart | Ten good streams |

The scraper row looks odd, since users don't notice anything. That's the point: losing monitoring doesn't hurt anyone directly, but it means you can't see when something else does. No alerts doesn't mean healthy.

### The recovery check

This part needs no Docker, so it can be tested properly. Recovery and the record of each drill go in their own module:

<!-- file: serve/src/serve/recovery.py -->
~~~python
"""Recovery is measured with real requests, and a failed drill is still a result.

Recovery means ten consecutive completed, nonempty streams through the API.
A green /health only says the process started; it does not say users are served.
"""

import time
from collections.abc import Callable
from dataclasses import dataclass, field


class Clock:
    """Seconds since the drill started, on a clock that never jumps."""

    def __init__(self) -> None:
        self.start = time.monotonic()

    def __call__(self) -> float:
        return round(time.monotonic() - self.start, 3)


@dataclass
class Case:
    fault: str
    repetition: int
    injected: float
    detected: float | None = None
    mitigated: float | None = None
    recovered: float | None = None
    during: list[dict] = field(default_factory=list)
    recovery: list[dict] = field(default_factory=list)
    notes: dict = field(default_factory=dict)
    passed: bool = False
    failure: str = ""


class NotRecovered(Exception):
    pass


def recover(probe: Callable[[], dict], clock: Callable[[], float], need=10, limit=90.0):
    """Probe until `need` requests in a row succeed. Any failure restarts the count."""
    rows, streak = [], 0
    deadline = clock() + limit
    while streak < need:
        if clock() > deadline:
            raise NotRecovered(f"{streak} of {need} consecutive successes after {limit:.0f} s")
        row = probe()
        rows.append(row)
        streak = 0 if row["error"] else streak + 1
    return rows


def run_case(name, repetition, fault, recovery, clock) -> Case:
    """Inject, mitigate, then require recovery. A failed drill is a result: keep it."""
    case = Case(name, repetition, injected=clock())
    try:
        fault(case)
        case.mitigated = clock()
        case.recovery = recovery()
        case.recovered = clock()
        case.passed = True
    except Exception as exc:
        case.failure = f"{type(exc).__name__}: {exc}"
    return case


def summary(cases: list[Case]) -> str:
    lines = [f"{'fault':<18} {'rep':>3} {'detect s':>9} {'recover s':>10}  result"]
    for c in cases:
        detect = f"{c.detected - c.injected:.2f}" if c.detected is not None else "-"
        total = f"{c.recovered - c.injected:.1f}" if c.recovered is not None else "-"
        result = "passed" if c.passed else "FAILED " + c.failure
        lines.append(f"{c.fault:<18} {c.repetition:>3} {detect:>9} {total:>10}  {result}")
    return "\n".join(lines)
~~~

`recover` accepts any `probe` function and any clock. In a real drill, the probe streams a request through the API and the clock is `Clock`. The tests pass in a list of results and a fake clock that moves on one second every time it's read, so no test waits for real time. `run_case` deliberately catches every exception: a failed drill is a result to keep, not a crash to hide. The record stores the exception's name and message.

<!-- file: serve/tests/test_recovery.py -->
~~~python
import pytest

from serve.recovery import NotRecovered, recover, run_case


class FakeClock:
    """Each reading moves time on by one second."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        self.now += 1
        return self.now


def probes(errors: list[str]):
    rows = iter(errors)
    return lambda: {"error": next(rows)}


def test_recovery_needs_consecutive_successes():
    # Five good, one failure, then ten good: the failure restarts the count.
    sequence = [""] * 5 + ["status 502"] + [""] * 10
    rows = recover(probes(sequence), FakeClock(), need=10, limit=100)
    assert len(rows) == 16


def test_recovery_gives_up_at_the_deadline():
    with pytest.raises(NotRecovered, match="0 of 10"):
        recover(lambda: {"error": "status 502"}, FakeClock(), need=10, limit=20)


def test_a_failed_drill_is_kept_with_its_reason():
    def broken(case):
        case.detected = 1.0
        raise AssertionError("expected 'status 503', got ''")

    case = run_case("redis-unavailable", 1, broken, lambda: [], FakeClock())
    assert not case.passed and case.recovered is None
    assert "expected 'status 503'" in case.failure

    ok = run_case("model-exit", 1, lambda case: None, lambda: [{"error": ""}], FakeClock())
    assert ok.passed and ok.injected < ok.mitigated < ok.recovered
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_recovery.py -->

~~~bash
cd serve
uv run pytest -q tests/test_recovery.py
~~~

All three tests pass.

**Break it:** make `recover` count *total* successes instead of successes *in a row*. Replace the `streak = 0 if ...` line with `streak += not row["error"]`, then run the tests again:

~~~text
>       assert len(rows) == 16
E       AssertionError: assert 11 == 16
1 failed, 2 passed
~~~

Five good answers, one failure and five more good ones, and it declared recovery. A service that keeps failing every few requests would pass that check. Put the line back.

### The faults

The drills themselves talk to Docker and to the running stack:

<!-- file: serve/src/serve/gameday.py -->
~~~python
"""Run a game day: inject one fault at a time, mitigate it, then prove recovery."""

import argparse
import concurrent.futures
import json
import os
import socket
import struct
import subprocess
import threading
import time
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from urllib.parse import urlsplit

from serve.recovery import Case, Clock, recover, run_case, summary
from serve.stream import chat

LONG = "Count from one to one thousand, one number per line."


@dataclass
class Lab:
    api: str
    model: str
    scraper: str
    model_container: str
    redis_container: str
    scraper_container: str
    clock: Clock

    def probe(self, max_tokens=8, prompt="Reply with the word river.") -> dict:
        started = self.clock()
        row = asdict(chat(self.api, prompt, max_tokens, timeout=35))
        del row["text"]  # keep timings and errors, not model output
        row["started"] = started
        return row

    def docker(self, *args: str) -> str:
        done = subprocess.run(["docker", *args], capture_output=True, text=True)
        if done.returncode:
            raise RuntimeError(f"docker {args[0]}: {done.stderr.strip()}")
        return done.stdout.strip()

    def model_get(self, path: str):
        with urllib.request.urlopen(self.model + path, timeout=2) as response:
            return json.load(response)

    def wait_ready(self, limit=60.0) -> None:
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            try:
                if self.model_get("/health").get("status") == "ok":
                    return
            except OSError:
                pass
            time.sleep(0.1)
        raise TimeoutError("model not ready")

    def busy_slots(self) -> int:
        return sum(1 for slot in self.model_get("/slots") if slot["is_processing"])


def expect(row: dict, error: str) -> None:
    if row["error"] != error:
        raise AssertionError(f"expected {error!r}, got {row['error']!r}")


def model_exit(lab: Lab, case: Case) -> None:
    lab.docker("kill", lab.model_container)
    case.during.append(lab.probe())
    expect(case.during[-1], "status 502")
    case.detected = lab.clock()
    lab.docker("start", lab.model_container)
    lab.wait_ready()


def redis_unavailable(lab: Lab, case: Case) -> None:
    lab.docker("stop", "-t", "1", lab.redis_container)
    case.during.append(lab.probe())
    expect(case.during[-1], "status 503")  # fail closed: no shared budget, no generation
    case.detected = lab.clock()
    lab.docker("start", lab.redis_container)


def overload(lab: Lab, case: Case, offered=18) -> None:
    gate = threading.Barrier(offered)

    def one(_):
        gate.wait()  # release every request at once
        return lab.probe(128, LONG)

    with concurrent.futures.ThreadPoolExecutor(max_workers=offered) as pool:
        case.during = list(pool.map(one, range(offered)))
    rejected = [r for r in case.during if r["error"] == "status 503"]
    if not rejected:
        raise AssertionError("no request was refused: admission is unbounded")
    case.detected = min(r["started"] + r["total"] for r in rejected)
    case.notes["rejected"] = len(rejected)
    case.notes["completed"] = sum(1 for r in case.during if not r["error"])


def client_disconnect(lab: Lab, case: Case) -> None:
    api = urlsplit(lab.api)
    body = json.dumps(
        {"messages": [{"role": "user", "content": LONG}], "stream": True, "max_tokens": 512}
    ).encode()
    head = (
        f"POST /v1/chat/completions HTTP/1.1\r\nHost: {api.hostname}\r\n"
        f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n"
        f"Authorization: Bearer {os.environ['RUNWAY_TOKEN']}\r\n\r\n"
    ).encode()
    conn = socket.create_connection((api.hostname, api.port), timeout=10)
    conn.sendall(head + body)
    received = b""
    while b"data:" not in received:
        received += conn.recv(4096)
    case.notes["busy_before"] = lab.busy_slots()
    if not case.notes["busy_before"]:
        raise AssertionError("model was not generating when the client left")
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    conn.close()  # linger 0 sends a reset, like a client that vanished
    case.notes["reset"] = lab.clock()
    deadline = time.monotonic() + 8
    while lab.busy_slots():
        if time.monotonic() > deadline:
            raise AssertionError("the abandoned request still holds a model slot")
        time.sleep(0.05)
    case.notes["slot_free"] = lab.clock()


def scraper_loss(lab: Lab, case: Case) -> None:
    lab.docker("stop", "-t", "1", lab.scraper_container)
    try:
        urllib.request.urlopen(lab.scraper + "/-/ready", timeout=2)
        raise AssertionError("scraper still answers")
    except OSError:
        case.detected = lab.clock()
    case.during.append(lab.probe())
    expect(case.during[-1], "")  # users are fine; you are blind, not down
    lab.docker("start", lab.scraper_container)


def model_oom(lab: Lab, case: Case) -> None:
    lab.docker("update", "--memory", "32m", "--memory-swap", "32m", lab.model_container)
    case.during.append(lab.probe(128, LONG))
    deadline = time.monotonic() + 15
    while json.loads(lab.docker("inspect", lab.model_container))[0]["State"]["Running"]:
        if time.monotonic() > deadline:
            raise AssertionError("model survived the memory limit")
        time.sleep(0.1)
    state = json.loads(lab.docker("inspect", lab.model_container))[0]["State"]
    case.notes["oom_killed"] = state["OOMKilled"]
    case.during.append(lab.probe())
    expect(case.during[-1], "status 502")
    case.detected = lab.clock()
    lab.docker("update", "--memory", "2g", "--memory-swap", "2g", lab.model_container)
    lab.docker("start", lab.model_container)
    lab.wait_ready()


FAULTS = {
    "model-exit": model_exit,
    "redis-unavailable": redis_unavailable,
    "overload": overload,
    "client-disconnect": client_disconnect,
    "scraper-loss": scraper_loss,
    "model-oom": model_oom,
}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--api", default="http://127.0.0.1:18081")
    p.add_argument("--model", default="http://127.0.0.1:18080")
    p.add_argument("--scraper", default="http://127.0.0.1:19090")
    p.add_argument("--model-container", default="blueprint-phase8-llm")
    p.add_argument("--redis-container", default="blueprint-phase8-redis")
    p.add_argument("--scraper-container", default="blueprint-phase8-prometheus")
    p.add_argument("--faults", default=",".join(FAULTS))
    p.add_argument("--repeat", type=int, default=2)
    p.add_argument("--out", type=Path, default=Path("results/gameday.json"))
    a = p.parse_args()
    clock = Clock()
    lab = Lab(
        a.api,
        a.model,
        a.scraper,
        a.model_container,
        a.redis_container,
        a.scraper_container,
        clock,
    )
    cases: list[Case] = []
    a.out.parent.mkdir(parents=True, exist_ok=True)
    for rep in range(1, a.repeat + 1):
        for name in a.faults.split(","):
            print(f"{clock():8.1f}  begin  {name} {rep}", flush=True)
            fault = FAULTS[name]
            case = run_case(
                name, rep, lambda c, f=fault: f(lab, c), lambda: recover(lab.probe, clock), clock
            )
            cases.append(case)
            a.out.write_text(json.dumps([asdict(c) for c in cases], indent=2) + "\n")
            print(
                f"{clock():8.1f}  {'passed' if case.passed else 'FAILED'}  {name} {rep}", flush=True
            )
            if not case.passed:
                print(summary(cases))
                raise SystemExit("stop: fix the system before injecting another fault")
    print(summary(cases))


if __name__ == "__main__":
    main()
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run python -m serve.gameday --help -->

How each drill works:

- **`model_exit` and `redis_unavailable`** kill or stop a container, send one request, check that it fails with the expected status, then restart the container. `expect` checks the exact error: a 500 where you designed a 503 means the failure took a path you didn't plan for.
- **`overload`** uses a `Barrier` to hold 18 threads until all of them are ready, so the requests arrive at the same instant. With one slot and a queue of eight, nine should be admitted and nine refused.
- **`client_disconnect`** writes the HTTP request by hand on a raw socket and waits for the first streamed event. Then it closes the socket with `SO_LINGER` set to zero. That sends a TCP reset, like a phone losing signal, instead of a polite goodbye. Finally it polls the model server's `/slots` until no slot is busy. The Go context being cancelled isn't enough: as Step 4 showed, the model server itself has to stop generating.
- **`scraper_loss`** checks that Prometheus really is down, then expects a request to *succeed*.
- **`model_oom`** lowers the memory limit below what the model needs, waits until Docker reports the container stopped with `OOMKilled`, checks for the 502, and puts the 2 GiB limit back *before* restarting. The order matters, as the second Break it shows.
- **`main`** saves the JSON after every drill, so a drill that hangs still leaves the earlier records. It also stops at the first failure.

### Run it

The drills need the live stack from Steps 4 and 5:

| Service | Address | Notes |
|---|---|---|
| Model, `blueprint-phase8-llm` | 127.0.0.1:18080 | As in Step 8, plus a 2 GiB memory limit |
| Redis, `blueprint-phase8-redis` | 127.0.0.1:16379 | Holds the shared token budget |
| Runway's API with the inference route | 127.0.0.1:18081 | From Step 5, with `INFERENCE_UPSTREAM=http://127.0.0.1:18080`, `INFERENCE_REDIS_ADDR=127.0.0.1:16379`, `INFERENCE_SLOTS=1`, `INFERENCE_QUEUE=8` and authentication required |
| Prometheus, `blueprint-phase8-prometheus` | 127.0.0.1:19090 | Scrapes the API every 2 seconds |

Prometheus needs a small config file:

<!-- file: experiments/gameday/prometheus.yaml -->
~~~yaml
global:
  scrape_interval: 2s
scrape_configs:
  - job_name: runway-api
    static_configs:
      - targets: ['127.0.0.1:18081']
~~~

Start the three containers. If Step 8's model container is still there, remove it first (`docker rm -f blueprint-phase8-llm`): it has no memory limit, and the out-of-memory drill restores 2 GiB.

~~~bash
# From the lab root; PHASE8_MODELS is the verified model directory from Step 8.
docker run -d --name blueprint-phase8-llm -p 127.0.0.1:18080:8080 \
  --memory 2g --memory-swap 2g -v "$PHASE8_MODELS:/models:ro" \
  ghcr.io/ggml-org/llama.cpp@sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b \
  -m /models/qwen2.5-0.5b-instruct-q4_k_m.gguf -c 4096 -t 4 \
  --parallel 1 --metrics --host 0.0.0.0 --port 8080
docker run -d --name blueprint-phase8-redis -p 127.0.0.1:16379:6379 redis:8
docker run -d --name blueprint-phase8-prometheus --network host \
  -v "$PWD/experiments/gameday/prometheus.yaml:/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus:v3.15.0 \
  --config.file=/etc/prometheus/prometheus.yml --web.listen-address=127.0.0.1:19090
~~~

Start the API as in Step 5. Put a token for a client with the `generator` role in `RUNWAY_TOKEN`; it's a secret, so never commit it or paste it into notes. Check that one stream works, then run the game day:

~~~bash
cd serve
uv run python -m serve.stream http://127.0.0.1:18081
uv run python -m serve.gameday
~~~

It takes about two minutes. Each drill prints a `begin` and a `passed` line, then you get a summary:

~~~text
fault              rep  detect s  recover s  result
model-exit           1      0.56        5.9  passed
redis-unavailable    1      1.05        5.3  passed
overload             1      0.03       33.0  passed
client-disconnect    1         -        3.2  passed
scraper-loss         1      0.27        3.8  passed
model-oom            1      0.62        4.7  passed
model-exit           2      0.43        4.5  passed
redis-unavailable    2      1.09        5.2  passed
overload             2      0.02       32.8  passed
client-disconnect    2         -        3.2  passed
scraper-loss         2      0.22        3.6  passed
model-oom            2      0.57        4.6  passed
~~~

Your times will differ. Here's what mine say:

- **Detection is fast because the drill is watching.** A dead model shows up in about half a second, because the drill sends a request straight after `docker kill`. In real life nobody sends that request on cue: you find out from Step 5's alerts, which take minutes. The detect column measures the system's error path, not your monitoring.
- **The Redis 503 takes half a second.** That's the 500 ms Redis timeout from Step 4's `SharedReservation`. Failing closed is right, but while Redis is down, every request waits that long before it's refused.
- **Most of the recovery time is the check itself.** Restarting the model until `/health` is ok took 1.5–2 s. The ten checks took another 3–4 s, about 0.3 s each.
- **The cancelled request freed the model's slot 0.11 s after the reset,** in both runs.
- **Docker reported `OOMKilled: true`** both times, so the memory drill really did run the model out of memory.
- **Overload took 33 s to recover, and the details show a real problem.** Nine requests were refused within 30 ms: good. The nine admitted requests are served one at a time, and a long answer takes about 4 s, so their first content arrived at 0.3, 5.1, 9.7, 14.1, 17.6, 20.9 and 24.6 s. The last two in the first run never finished: they hit the 30-second deadline, one as a 504 and one cut off mid-answer. In the second run, all nine finished, the last one just under the deadline. Over six overload runs with this setting, at least one admitted request failed in five of them.

An admitted request that then times out is the worst outcome: it used model time, and the user still got nothing. The queue is longer than the deadline can drain. One slot can serve about 30 s ÷ 4 s ≈ 7 long requests before the deadline, but one running plus eight waiting is nine.

**Your turn:** restart the API with `INFERENCE_QUEUE=5` and run only the overload drill:

~~~bash
uv run python -m serve.gameday --faults overload
~~~

~~~text
fault              rep  detect s  recover s  result
overload             1      0.03       25.5  passed
overload             2      0.02       25.3  passed
~~~

All six admitted requests finished in both runs (the slowest complete answer took 22.7 s), twelve were refused at once, and recovery took 25 s instead of 33. The model completed the same number of answers (six or seven either way), because it isn't any faster. The shorter queue only refused, straight away, requests that would otherwise have waited and failed. The right length depends on how long the answers are and on the hardware, so work it out again whenever either one changes. Keep the queue at 5 for the rest of this phase, and write the reason in the runbook.

**Break it:** in `model_oom`, delete the `docker update` line that puts back the 2 GiB limit. Run only that drill:

~~~bash
uv run python -m serve.gameday --faults model-oom --repeat 1
~~~

~~~text
     0.0  begin  model-oom 1
    61.3  FAILED  model-oom 1
stop: fix the system before injecting another fault
fault              rep  detect s  recover s  result
model-oom            1      0.80          -  FAILED TimeoutError: model not ready
~~~

The restarted model was killed again while it loaded its weights, and the drill gave up after 60 s. Restarting a process doesn't fix anything while the cause is still there. Roll back the whole release, meaning the image, the weights and their resource limits, not just the process. Fix it by hand, the way the runbook says:

~~~bash
docker update --memory 2g --memory-swap 2g blueprint-phase8-llm
docker start blueprint-phase8-llm
~~~

Then put the line back.

### The runbook

Write the runbook before the first drill, and correct it after every drill that surprised you. Mine, in order:

1. Identify the running release: image, model and chat-template digests.
2. Stop any rollout that's in progress.
3. Look at queue depth, memory use and error rates. Don't look at prompts.
4. Shed excess work.
5. Restore the last tested **image + model + template** release, including its resource limits.
6. Verify the signatures (Step 7) and wait for readiness.
7. Run the ten-request check, and compare the all-arrivals objective from Step 5.
8. Record the detection and recovery times.

Two more rules. **Never automatically retry a partly delivered answer:** the user may already have seen part of it, and would get duplicate text. In Phase 7, a failed optional prediction could fall back to a default; a generation endpoint can't pretend a partial answer is complete. And **size the queue from the deadline:** slots × deadline ÷ time per long answer is the most work you can promise to finish.

**Done when:** every fault has passed twice, `results/gameday.json` is kept, the queue is sized from your measured answer time, and the runbook matches what you actually did. My raw results for every run above are in [evidence/2026-11-13-game-day](evidence/2026-11-13-game-day/). The [platform report](evidence/platform-validation/report.md) keeps an earlier run of the same six faults, plus Kubernetes drills (rolling back corrupt weights) that this local stack doesn't cover.

**What this proves, and what it doesn't.** It proves that each failure returns the status you designed, that cancellation frees the model, that admission bounds the work, and that the stack recovers on one machine. It doesn't prove how fast your *alerts* detect a fault, how the system behaves when a whole node or the network fails, or anything about production. Two runs per fault is a small sample: the overload result changed between runs, which is exactly why you repeat them.

## Step 10: Data parallelism, with a reference you can check

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

### Checkpoint, crash, resume

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

### Across a real network link

On one machine, the ranks talk over loopback, which is almost free. Put them in two containers with a link you control, as in the [Networking Bridge](../network-bridge/README.md)'s netlab:

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

### Predict, then measure

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

**Your turn:** add a fifth row with loss, `link.sh 40ms 100mbit 1%`, and predict it first. The Networking Bridge measured what 1% loss does to a single TCP download.

### Break it: lose a rank, lose the link

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

**Done when:** the serial-parity and resume checks pass locally, your measured step and all-reduce times are in a table with your predictions next to them, and both failures ended within the timeout and resumed to a model that matches the serial one. My raw results are in [evidence/2026-11-13-training-network](evidence/2026-11-13-training-network/README.md).

**What this proves, and what it doesn't.** It proves that data-parallel training here computes the same model as one process, that a checkpoint resumes it exactly, and that a dead rank or a dead link fails the job in bounded time instead of hanging. It doesn't measure GPU training: NCCL over NVLink or InfiniBand overlaps communication with computation and uses links a thousand times faster than this one, so only the *shape* of the trade-off carries over. Two containers on one machine aren't two machines, and a job that fails cleanly and resumes from a checkpoint still loses the work since that checkpoint. Elastic training, which continues with fewer ranks, is a different design.

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

Stop Serve with Ctrl-C after recording the result. Use Serve as an alternative control plane in a separate experiment; keep Runway's auth and token admission in front of a real model deployment. The random teaching model cannot meet the quality gate.

**Break it:** commit the same task result twice with deduplication removed; then kill/recreate the actor and repeat. Explain the difference between task retries and durable commit semantics. Capture the Ray commands and versions in the report; Ray execution is manual and is not part of the CPU CI claim below.

## Step 13: CUDA, transfers, and vLLM

Read the [linear-algebra guide](../../math/03-linear-algebra/README.md) first: arithmetic intensity and the roofline explain why prefill, decode and tiny kernels hit different limits. CUDA has a host and device address space; transfer time and launch overhead are work too. Pinned host buffers allow efficient DMA, but pinning costs memory and setup, and `non_blocking=True` alone does not prove overlap. See [NVIDIA's CUDA best practices](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/).

**Evidence status:** no GPU is available in this checkout. These scripts are provided for a run on an authorised NVIDIA host. They have no measured output yet. If using a rented host, agree its budget first, record the rate, and stop/destroy the instance afterwards. First capture `nvidia-smi`, driver/CUDA versions, CPU/RAM, image/environment digest and the model revision. Use a fresh GPU-specific environment rather than the lab's CPU-only PyTorch index.

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

### What you can check without a GPU

Before you pay for a GPU, check everything that doesn't need one, so the paid hour isn't spent fixing typos. NVIDIA publishes its CUDA compiler as Python wheels, so you can install it without a GPU and without admin rights:

~~~bash
uv venv --python 3.12 .cuda-tools
uv pip install --python .cuda-tools/bin/python nvidia-cuda-nvcc==13.5.37 nvidia-cuda-runtime==13.5.37
NVCC=.cuda-tools/lib/python3.12/site-packages/nvidia/cu13/bin/nvcc
$NVCC --version | tail -2
$NVCC -O2 gpu/add.cu -o gpu/add && ./gpu/add
~~~

~~~text
Cuda compilation tools, release 13.5, V13.5.37
Build cuda_13.5.r13.5/compiler.39125733_0
CUDA driver version is insufficient for CUDA runtime version
~~~

The kernel compiles. Running it fails at the first CUDA call, and the `CHECK` macro reports why and exits with status 1, instead of carrying on and checking answers that were never computed. That's the error path working. (The CUDA 12 wheel, `nvidia-cuda-nvcc-cu12`, contains only `ptxas`, not `nvcc`; use the CUDA 13 one.)

Now the Break it without a GPU: delete `if(i<n)` and compile again. It compiles without a warning. The compiler can't know the last block is partial, which is exactly why the step runs `compute-sanitizer` on real hardware. Put the guard back.

The timing script refuses rather than inventing numbers:

~~~bash
cd serve && uv run python ../gpu/capture.py
~~~

~~~text
not measured: CUDA device unavailable
~~~

This proves the code compiles and that both programs fail cleanly without a GPU. It proves nothing about correctness or speed on one: those need the run above, on real hardware.

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
| Admission stays bounded; reservations are shared across gateway instances | Go race checks, real JWT API/shared Redis, and actual backend slot release after disconnect | Tenant scheduling fairness and production isolation remain unestablished |
| DDP updates equal global-batch SGD after failure | CPU/Gloo ranks across shaped container links; killed rank/partition, checkpoint resume and serial reference | One host; not a physical-network, GPU or RDMA scaling benchmark |
| Tensor/pipeline decompositions preserve gradients | Single-process reference and two-rank send/recv checks | Sequential pipeline; no overlap benchmark |
| Signed weights and images accept/refuse the intended release | Signed-image admission, private-copy startup gate, revoked key, webhook outage and corrupt/missing-weight cases | Lab trust authority; publisher revision unknown; no production security clearance |
| Deployment, queue-based HPA and failure recovery work live | Actual custom metric, 1→2 replicas receiving work, repeated faults and ten-request recovery contract | One-node lab; overload run missed the chosen latency objective |
| Ray runtime works | Tasks, retries/actor loss, two-worker Train parity and Serve HTTP results | In-memory actor deduplication is not durable exactly-once accounting |
| GPU/CUDA and vLLM performance | Runnable/manual procedures and local hardware preflight | Not measured; no exposed NVIDIA host |
| A configuration meets latency, quality and cost targets | Scorer plus 60-run CPU grid and frozen toy quality results | No accepted production configuration established |

Rebuild the CPU evidence from the repository root:

~~~bash
python3 scripts/check_guides.py lessons/08-ai-infrastructure/TEACHING.md
~~~

The replay extracts the inline files into a fresh temporary directory. Docker, kind, signing services, the shaped link, Ray and a GPU are manual experiments, explicitly outside that command. Run the entire repository workflow when you have the earlier phases' broker/database services available. Never relabel syntax checking as a deployed result.

Finish [the questions](learned.md), build [the independent exercise](exercises.md), and take [the self-test](../../notes/learned/08-ai-infrastructure.md). Then move to the [capstone](../../capstones/README.md): now you choose the question as well as the experiment.
