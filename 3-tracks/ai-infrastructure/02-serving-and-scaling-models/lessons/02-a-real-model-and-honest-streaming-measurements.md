# 02 A real model, and honest streaming measurements

The tiny model explains the work; it cannot answer a useful question. Run a small instruction model with llama.cpp. Keep the model license beside the weights. Fetch the Qwen2.5-0.5B-Instruct GGUF `q4_k_m` file from [its publisher](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/tree/main); record the repository revision and verify the bytes before starting. The historical lab used this checksum:

~~~text
74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db  qwen2.5-0.5b-instruct-q4_k_m.gguf
~~~

A checksum detects a different file. Lesson 07 adds publisher identity. This image digest is the historical CPU server; inspect its architecture and vulnerability scan before deploying it. These are manual Docker commands, outside CI.


<!-- file: experiments/llm/server.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
threads=${1:-4}
slots=${2:-1}
: "${MODELS:?set MODELS to the directory containing the GGUF file}"
image=ghcr.io/ggml-org/llama.cpp@sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b
# Stop only the container owned by this lab.
docker rm -f switchyard-llm >/dev/null 2>&1 || true
docker run -d --name switchyard-llm -p 127.0.0.1:8000:8080 \
  -v "$MODELS:/models:ro" "$image" \
  -m /models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  -c "$((4096 * slots))" -t "$threads" --parallel "$slots" --metrics --host 0.0.0.0
for attempt in $(seq 1 120); do
  if curl -fsS http://127.0.0.1:8000/health >/dev/null; then exit 0; fi
  sleep 1
done
docker logs switchyard-llm >&2
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
        if os.environ.get("SWITCHYARD_TOKEN"):
            headers["Authorization"] = "Bearer " + os.environ["SWITCHYARD_TOKEN"]
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
