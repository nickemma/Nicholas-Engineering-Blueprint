# 04 Run the pinned CPU model matrix

> Inference gateway capstone · Week 2

## The problem

A faster parser might change nothing visible to callers when the model is the bottleneck. A claim about the complete gateway needs a complete workload.

## The mental model

~~~text
fixed requests → eager or typed gateway → same CPU model and settings
                                     → per-request records and per-block throughput
~~~

## The pattern

Warm up both gateways. At concurrency one and two, run blocks in eager, typed, typed, eager order. Use the same model and prompt, keep prefix caching disabled at the gateway, and run without the profiler. Record shipped binary hashes and the verified GGUF digest. Look for speed and completion changes in the same report.

## Build it

### Alternate the variants and save outcomes

Start both gateways on loopback and keep every raw request and block summary.

Create or update `bench/matrix.py`.

<!-- file: bench/matrix.py -->
~~~python
"""Run eager and typed gateway binaries against an identical local model."""

import argparse
from contextlib import ExitStack, contextmanager
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import select
import subprocess
from urllib.parse import urlsplit

from bench import batch, endpoint, sample


@contextmanager
def gateway(binary, model, token, other):
    env = dict(os.environ, GATEWAY_MODEL_ADDR=model, GATEWAY_LISTEN="127.0.0.1:0",
               GATEWAY_A_TOKEN=token, GATEWAY_B_TOKEN=other, GATEWAY_SLOTS="2")
    with subprocess.Popen([str(binary.resolve())], env=env, stderr=subprocess.PIPE, text=True) as child:
        try:
            if not select.select([child.stderr], [], [], 8)[0]:
                raise RuntimeError("gateway startup deadline")
            _, marker, address = child.stderr.readline().strip().partition("listening on ")
            if not marker or not address.startswith("127.0.0.1:"):
                raise RuntimeError("gateway failed to listen on loopback")
            yield "http://" + address
        finally:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)


def identity(binary):
    with binary.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model_origin")
    parser.add_argument("eager", type=Path)
    parser.add_argument("typed", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    endpoint(args.model_origin)
    model_address = urlsplit(args.model_origin).netloc
    args.output.mkdir(parents=True)
    token, other = secrets.token_hex(24), secrets.token_hex(24)
    runs = []
    with ExitStack() as stack, (args.output / "requests.jsonl").open("x") as raw:
        origins = {
            "eager": stack.enter_context(gateway(args.eager, model_address, token, other)),
            "typed": stack.enter_context(gateway(args.typed, model_address, token, other)),
        }
        for name, origin in origins.items():
            warmed = sample(endpoint(origin), token, -1)
            if warmed["outcome"] != "complete":
                raise RuntimeError(f"{name} warmup failed: {warmed['status']} {warmed['outcome']}")
        for concurrency in (1, 2):
            for block, mode in enumerate(("eager", "typed", "typed", "eager"), start=1):
                rows, summary = batch(origins[mode], token, 8, concurrency)
                label = {"block": block, "variant": mode, "concurrency": concurrency}
                for row in rows:
                    raw.write(json.dumps({**label, **row}, sort_keys=True) + "\n")
                result = {**label, **summary}
                print(json.dumps(result, sort_keys=True), flush=True)
                runs.append(result)
    evidence = {
        "system": platform.platform(), "logical_cpus": len(os.sched_getaffinity(0)),
        "binary_sha256": {"eager": identity(args.eager), "typed": identity(args.typed)},
        "runs": runs,
    }
    (args.output / "runs.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    if any(row["complete"] != row["offered"] for row in runs):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
~~~

### Start a disposable pinned model server

Check the GGUF bytes before mounting the model read-only. Stop the owned container when the run exits.

Create or update `bench/local_model.py`.

<!-- file: bench/local_model.py -->
~~~python
"""Run the measured matrix with the serving lesson's pinned CPU model."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener
from uuid import uuid4


IMAGE = "sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b"
MODEL_SHA256 = "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"
SERVER = ["-m", "/model.gguf", "--alias", "switchyard", "-c", "4096", "-t", "4",
          "--parallel", "2", "--host", "0.0.0.0", "--port", "8080"]


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True, timeout=30).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("gguf", type=Path)
    parser.add_argument("eager", type=Path)
    parser.add_argument("typed", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with args.gguf.open("rb") as weights:
        if hashlib.file_digest(weights, "sha256").hexdigest() != MODEL_SHA256:
            raise ValueError("model digest mismatch")
    name = "sy-cap-model-" + uuid4().hex[:10]
    docker(
        "run", "--rm", "-d", "--pull=never", "--name", name, "-p", "127.0.0.1::8080",
        "--mount", f"type=bind,source={args.gguf.resolve()},target=/model.gguf,readonly",
        IMAGE, *SERVER,
    )
    try:
        address = docker("port", name, "8080/tcp")
        url = "http://" + address
        opener = build_opener(ProxyHandler({}))
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                with opener.open(url + "/health", timeout=2) as reply:
                    if reply.status == 200:
                        break
            except (OSError, URLError):
                time.sleep(0.2)
        else:
            raise RuntimeError("model startup deadline")
        subprocess.run(
            [sys.executable, str(Path(__file__).with_name("matrix.py")), url,
             args.eager, args.typed, args.output], check=True, timeout=240,
        )
        metadata = {"image": IMAGE, "model_sha256": MODEL_SHA256, "server_args": SERVER}
        (args.output / "model.json").write_text(json.dumps(metadata, indent=2) + "\n")
    except Exception:
        print(docker("logs", "--tail", "20", name), file=sys.stderr)
        raise
    finally:
        subprocess.run(["docker", "rm", "-f", name], timeout=15, check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
~~~

### Verify the published client profile

Use the Python OpenAI SDK pointed at the loopback gateway. Verify discovery, nonempty text, and usage on the same stream.

Create or update `bench/sdk_smoke.py`.

<!-- file: bench/sdk_smoke.py -->
~~~python
"""Check the streaming subset using the Python SDK against a local gateway."""

import os
import sys

from openai import DefaultHttpxClient
from openai import OpenAI

from bench import endpoint


def main():
    address = sys.argv[1].rstrip("/")
    endpoint(address)
    with OpenAI(base_url=address + "/v1", api_key=os.environ["GATEWAY_A_TOKEN"],
                max_retries=0, timeout=20, http_client=DefaultHttpxClient(trust_env=False)) as client:
        assert [model.id for model in client.models.list()] == ["switchyard"]
        with client.chat.completions.create(
            model="switchyard", messages=[{"role": "user", "content": "Name two small rivers."}],
            stream=True, temperature=0, max_completion_tokens=16,
            stream_options={"include_usage": True},
        ) as chunks:
            content = False
            usage = None
            for chunk in chunks:
                assert chunk.model == "switchyard"
                content |= any(bool(choice.delta.content) for choice in chunk.choices)
                if chunk.usage is not None:
                    usage = chunk.usage.completion_tokens
        assert content and usage is not None and 1 <= usage <= 16
        print(f"OpenAI SDK smoke: model discovery, text deltas, and usage succeeded ({usage} output tokens)")


if __name__ == "__main__":
    main()
~~~

## Check it

~~~bash
bash bench/build.sh ./dist
python3 bench/local_model.py /path/to/model.gguf ./dist/gateway-eager ./dist/gateway-typed ./model-run
~~~

Use the pinned image and GGUF from the [gate guide](../gate/README.md). The live model run is local and uses real CPU inference. The correctness replay avoids a model download by using fixtures. The [reference report](../evidence/README.md) records the whole-request and isolated results separately.

<!-- run: python3 -m unittest discover -s bench -v -->
