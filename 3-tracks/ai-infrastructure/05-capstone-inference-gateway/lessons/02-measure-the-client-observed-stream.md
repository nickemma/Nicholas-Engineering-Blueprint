# 02 Measure the client-observed stream

> Inference gateway capstone · Week 1

## The problem

Headers and role messages can arrive before any generated text. Counting them as a token makes a responsive transport look like a fast model.

## The mental model

~~~text
send → headers and role → first nonempty content → later content → checked [DONE]
|<----------- TTFT ------------->|
                                 |<------------ TPOT numerator ----------->|
~~~

## The pattern

Use a monotonic client clock. TTFT is send to first complete event with nonempty content. TPOT is first content to the terminal event divided by authoritative output tokens minus one. Give one-token responses TTFT and omit TPOT. Count completed output tokens per elapsed block second. A response that ends early contributes a failure and zero completed tokens. [vLLM benchmark metric definitions](https://docs.vllm.ai/en/latest/benchmarking/cli/)

Use a bounded closed-loop client. Keep every request outcome and report quantile sample counts. The time-between-content-chunks question is separate from the request's TPOT.

## Build it

### Measure a bounded block of traffic

Capture timing and usage without recording response text or credentials.

Create or update `bench/bench.py`.

<!-- file: bench/bench.py -->
~~~python
"""Measure one bounded closed-loop load run against the local gateway."""

import argparse
import concurrent.futures
import http.client
import ipaddress
import json
import math
import os
from pathlib import Path
import time
from urllib.parse import urlsplit


PAYLOAD = {
    "model": "switchyard",
    "messages": [{"role": "user", "content": "List five short river names, separated by commas."}],
    "stream": True,
    "temperature": 0,
    "max_completion_tokens": 16,
    "stream_options": {"include_usage": True},
}


def endpoint(url):
    parsed = urlsplit(url)
    try:
        local = ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        local = False
    if not local or parsed.scheme != "http" or parsed.port is None or parsed.path not in ("", "/"):
        raise ValueError("use a loopback HTTP origin with an explicit port")
    return parsed.hostname, parsed.port


def sample(address, credential, index):
    connection = http.client.HTTPConnection(*address, timeout=25)
    start = time.perf_counter_ns()
    first = None
    usage = None
    name = "eof"
    status = 0
    began = time.monotonic()
    try:
        connection.request("POST", "/v1/chat/completions", json.dumps(PAYLOAD), {
            "Authorization": "Bearer " + credential,
            "Content-Type": "application/json",
        })
        with connection.getresponse() as response:
            status = response.status
            if status != 200:
                name = "http_error"
            else:
                data = []
                event = "message"
                wire = 0
                while time.monotonic() - began < 25:
                    line = response.readline(32769)
                    if not line:
                        break
                    wire += len(line)
                    if len(line) > 32768 or wire > 512 * 1024:
                        name = "wire_limit"
                        break
                    line = line.rstrip(b"\r\n")
                    if line.startswith(b"data:"):
                        data.append(line[5:].removeprefix(b" "))
                    elif line.startswith(b"event:"):
                        event = line[6:].strip().decode()
                    elif not line and data:
                        value = b"\n".join(data)
                        at = time.perf_counter_ns()
                        if event == "error":
                            name = "stream_error"
                            break
                        if value == b"[DONE]":
                            name = "complete" if first is not None and usage is not None and usage >= 1 else "missing_content_or_usage"
                            break
                        payload = json.loads(value)
                        choices = payload.get("choices") or []
                        if choices and choices[0].get("delta", {}).get("content") and first is None:
                            first = at
                        if payload.get("usage") is not None:
                            usage = payload["usage"]["completion_tokens"]
                            if type(usage) is not int or usage > PAYLOAD["max_completion_tokens"]:
                                name = "invalid_usage"
                                break
                        data.clear()
                        event = "message"
                else:
                    name = "deadline"
    except (OSError, http.client.HTTPException, ValueError, KeyError, TypeError):
        name = "transport_or_json_error"
    finally:
        connection.close()
    end = time.perf_counter_ns()
    return {
        "sample": index, "status": status, "outcome": name, "start_ns": start, "end_ns": end,
        "output_tokens": usage if name == "complete" else None,
        "ttft_ms": (first - start) / 1e6 if name == "complete" else None,
        "tpot_ms": (at - first) / 1e6 / (usage - 1) if name == "complete" and usage > 1 else None,
    }


def nearest(values, fraction):
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * fraction) - 1] if ordered else None


def summarize(samples):
    complete = [row for row in samples if row["outcome"] == "complete"]
    seconds = (max(row["end_ns"] for row in samples) - min(row["start_ns"] for row in samples)) / 1e9
    output = sum(row["output_tokens"] for row in complete)
    result = {"offered": len(samples), "complete": len(complete), "seconds": seconds,
              "output_tokens": output, "output_tokens_per_second": output / seconds}
    for field in ("ttft_ms", "tpot_ms"):
        observed = [row[field] for row in complete if row[field] is not None]
        result[field] = {"n": len(observed), "p50": nearest(observed, .50), "p95": nearest(observed, .95)}
    return result


def batch(url, credential, count, concurrency):
    if not 1 <= concurrency <= count <= 128 or concurrency > 16:
        raise ValueError("use 1–128 requests and concurrency at most 16")
    address = endpoint(url)
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        rows = list(executor.map(lambda index: sample(address, credential, index), range(count)))
    return rows, summarize(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("origin")
    parser.add_argument("output", type=Path)
    parser.add_argument("--requests", type=int, default=8)
    parser.add_argument("--concurrency", type=int, default=2)
    args = parser.parse_args()
    samples, summary = batch(args.origin, os.environ["GATEWAY_A_TOKEN"], args.requests, args.concurrency)
    args.output.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in samples))
    print(json.dumps(summary, sort_keys=True))
    if summary["complete"] != summary["offered"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
~~~

### Verify the completion predicate

Feed content and usage followed by EOF. Confirm that it produces no successful throughput sample.

Create or update `bench/test_bench.py`.

<!-- file: bench/test_bench.py -->
~~~python
import io
import unittest
from unittest.mock import patch

import bench


class Response(io.BytesIO):
    status = 200


class Benchmark(unittest.TestCase):
    def request_with(self, wire):
        with patch("bench.http.client.HTTPConnection") as connection:
            connection.return_value.getresponse.return_value = Response(wire)
            return bench.sample(("127.0.0.1", 8080), "fixture", 1)

    def test_terminal_marker_is_required_for_goodput(self):
        content = b'data: {"choices":[{"delta":{"content":"river"}}]}\n\n'
        usage = b'data: {"choices":[],"usage":{"completion_tokens":2}}\n\n'
        result = self.request_with(content + usage + b"data: [DONE]\n\n")
        self.assertEqual(result["outcome"], "complete")
        self.assertEqual(result["output_tokens"], 2)
        self.assertGreaterEqual(result["tpot_ms"], 0)
        incomplete = self.request_with(content + usage)
        self.assertEqual(incomplete["outcome"], "eof")
        self.assertIsNone(incomplete["output_tokens"])
        self.assertIsNone(incomplete["ttft_ms"])
        print("negative control: EOF with content and usage contributed no completed tokens", flush=True)

    def test_one_token_has_ttft_but_no_tpot(self):
        content = b'data: {"choices":[{"delta":{"content":"river"}}]}\n\n'
        usage = b'data: {"choices":[],"usage":{"completion_tokens":1}}\n\n'
        result = self.request_with(content + usage + b"data: [DONE]\n\n")
        summary = bench.summarize([result])
        self.assertEqual(summary["complete"], 1)
        self.assertEqual(summary["ttft_ms"]["n"], 1)
        self.assertEqual(summary["tpot_ms"]["n"], 0)
        self.assertIsNone(summary["tpot_ms"]["p95"])


if __name__ == "__main__":
    unittest.main()
~~~

## Check it

~~~bash
python3 -m unittest discover -s bench -v
~~~

<!-- run: python3 -m unittest discover -s bench -v -->

The missing terminal marker case has no completed output tokens. A single-token stream has no TPOT sample.
