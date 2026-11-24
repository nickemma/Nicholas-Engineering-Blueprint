# 05 An HTTP client tested without a network

> Module: Python runtime and honest measurement · Time: ~3 h · Builds on: 04; Core 01 lessons 08, 13 and 14 (the jobs API, backpressure, idempotency keys)

## The problem

Before `kload` puts load on Switchyard, it should check that Switchyard is there and behaves: healthy, accepting jobs, honouring an idempotency key, cancelling. That needs a client for Switchyard's API. A client is easy to write and easy to get subtly wrong (a status code it didn't expect, an error body it can't read, a server that never answers), and you don't want its tests to need a running server, a free port, and luck with timing.

## The mental model

~~~text
  production:  SwitchyardClient ─▶ httpx.Client ─▶ transport ─▶ TCP ─▶ Switchyard
  tests:       SwitchyardClient ─▶ httpx.Client ─▶ MockTransport(FakeSwitchyard)
                                                    └─ a Python function: request in, response out
~~~

- **httpx** is an HTTP client library. An `httpx.Client` keeps connections open, joins paths to a base URL, encodes JSON and applies timeouts. Underneath it, a **transport** actually sends the bytes.
- **`MockTransport(handler)`** replaces the network with a function you write: it receives each `httpx.Request` and returns an `httpx.Response`. Nothing leaves the process.
- **Dependency injection:** `SwitchyardClient` is *given* its `httpx.Client` instead of building one. Production passes a real one; tests pass one with a `MockTransport`. The client's code is identical in both.
- A **fake** is a small working stand-in, with state and rules, unlike a **mock** that only records which calls were made. `FakeSwitchyard` keeps jobs in a dictionary and honours idempotency keys, so a test can check behaviour.

## The pattern

**Fakes over mocks, injected.** The thing under test receives its dependency; the test hands it a fake that behaves like the real thing, including failing like it.

## Build it

### Step 1: The client

Add httpx:

~~~bash
uv add 'httpx>=0.28.1'
~~~

<!-- run: uv add 'httpx>=0.28.1' -->

Create `src/kload/client.py`:

<!-- file: src/kload/client.py -->
~~~python
"""A small client for Switchyard's HTTP API."""

from dataclasses import dataclass
from typing import Any

import httpx


class ApiError(Exception):
    """Switchyard answered with a status the caller didn't expect."""

    def __init__(self, status: int, message: str, retry_after: str | None = None) -> None:
        super().__init__(f"{status}: {message}")
        self.status = status
        self.message = message
        self.retry_after = retry_after


@dataclass(frozen=True)
class Job:
    id: int
    state: str
    description: str
    duration_ms: int
    failure_reason: str = ""

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> Job:
        return cls(
            id=data["id"],
            state=data["state"],
            description=data["description"],
            duration_ms=data["duration_ms"],
            failure_reason=data.get("failure_reason", ""),
        )


class SwitchyardClient:
    """Calls Switchyard through an httpx.Client it is given.

    The caller builds the httpx.Client (base URL, timeouts, transport), so a
    test can hand it one whose transport never touches the network.
    """

    def __init__(self, http: httpx.Client) -> None:
        self._http = http

    def health(self) -> str:
        return _check(self._http.get("/health"), 200)["status"]

    def create_job(self, description: str, duration_ms: int = 0, key: str = "") -> Job:
        headers = {"Idempotency-Key": key} if key else {}
        body = {"description": description, "duration_ms": duration_ms}
        return Job.from_json(_check(self._http.post("/jobs", json=body, headers=headers), 201))

    def get_job(self, job_id: int) -> Job:
        return Job.from_json(_check(self._http.get(f"/jobs/{job_id}"), 200))

    def cancel_job(self, job_id: int) -> Job:
        return Job.from_json(_check(self._http.post(f"/jobs/{job_id}/cancel"), 200))


def _check(response: httpx.Response, expected: int) -> dict[str, Any]:
    """Return the JSON body if the status is the expected one; raise ApiError if not."""
    if response.status_code != expected:
        match response.headers.get("content-type", "").split(";")[0]:
            case "application/json":
                message = response.json().get("error", response.text)
            case _:
                message = response.text.strip()
        raise ApiError(response.status_code, message, response.headers.get("retry-after"))
    return response.json()
~~~

- `ApiError` is a custom exception: a class that inherits from `Exception` and carries the status, Switchyard's error message, and `Retry-After` when there is one (Switchyard sends it with a `503`).
- `Job.from_json` is a **classmethod**: it's called on the class (`Job.from_json(data)`), not on a job, and builds one from Switchyard's JSON. The return type says `-> Job` inside the class `Job` itself; since Python 3.14, annotations are evaluated only when something asks for them, so the name doesn't have to exist yet.
- `_check` uses `match` on the response's content type. Switchyard's handlers answer errors in JSON, `{"error": "..."}`, but Go's router answers its own `404` and `405` in plain text, so the client must read both.

### Step 2: A fake Switchyard

Create `tests/test_client.py`:

<!-- file: tests/test_client.py -->
~~~python
import json

import httpx
import pytest

from kload.client import ApiError, Job, SwitchyardClient


class FakeSwitchyard:
    """Pretends to be Switchyard's HTTP API, just enough for these tests.

    It keeps jobs in a dict and honours Idempotency-Key, so a test can check
    behaviour, not just which calls were made.
    """

    def __init__(self) -> None:
        self.jobs: dict[int, dict] = {}
        self.keys: dict[str, int] = {}
        self.busy = False

    def __call__(self, request: httpx.Request) -> httpx.Response:
        match request.method, request.url.path.strip("/").split("/"):
            case "GET", ["health"]:
                return httpx.Response(200, json={"status": "ok", "service": "switchyard"})
            case "POST", ["jobs"]:
                return self.create(request)
            case "GET", ["jobs", job_id] if int(job_id) in self.jobs:
                return httpx.Response(200, json=self.jobs[int(job_id)])
            case "POST", ["jobs", job_id, "cancel"] if int(job_id) in self.jobs:
                self.jobs[int(job_id)]["state"] = "cancelled"
                return httpx.Response(200, json=self.jobs[int(job_id)])
            case _:
                return httpx.Response(404, json={"error": "job not found"})

    def create(self, request: httpx.Request) -> httpx.Response:
        if self.busy:
            return httpx.Response(
                503,
                json={"error": "the service is busy; retry later"},
                headers={"Retry-After": "1"},
            )
        key = request.headers.get("Idempotency-Key", "")
        if key in self.keys:
            return httpx.Response(201, json=self.jobs[self.keys[key]])
        body = json.loads(request.content)
        if not body["description"]:
            return httpx.Response(400, json={"error": "description must be 1 to 200 characters"})
        job_id = len(self.jobs) + 1
        self.jobs[job_id] = {"id": job_id, "state": "queued", **body}
        if key:
            self.keys[key] = job_id
        return httpx.Response(201, json=self.jobs[job_id])


@pytest.fixture
def fake():
    return FakeSwitchyard()


@pytest.fixture
def client(fake):
    with httpx.Client(
        base_url="http://switchyard.test", transport=httpx.MockTransport(fake)
    ) as http:
        yield SwitchyardClient(http)


def test_health(client):
    assert client.health() == "ok"


def test_create_and_get(client):
    job = client.create_job("resize", duration_ms=50)
    assert job == Job(id=1, state="queued", description="resize", duration_ms=50)
    assert client.get_job(1) == job


def test_the_same_key_returns_the_same_job(client, fake):
    first = client.create_job("resize", key="k1")
    again = client.create_job("resize", key="k1")
    assert again.id == first.id
    assert len(fake.jobs) == 1


def test_cancel(client):
    job = client.create_job("resize")
    assert client.cancel_job(job.id).state == "cancelled"


def test_busy_raises_with_retry_after(client, fake):
    fake.busy = True
    with pytest.raises(ApiError) as caught:
        client.create_job("resize")
    assert (caught.value.status, caught.value.retry_after) == (503, "1")


def test_api_error_carries_the_message(client):
    with pytest.raises(ApiError, match="400: description must be"):
        client.create_job("")


def test_unknown_job(client):
    with pytest.raises(ApiError, match="404: job not found"):
        client.get_job(99)


def test_a_plain_text_error_is_still_an_api_error():
    def router(request: httpx.Request) -> httpx.Response:
        return httpx.Response(405, text="Method Not Allowed\n")

    with httpx.Client(base_url="http://t", transport=httpx.MockTransport(router)) as http:
        with pytest.raises(ApiError, match="405: Method Not Allowed"):
            SwitchyardClient(http).health()


def test_a_stalled_server_times_out():
    def stall(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("timed out", request=request)

    with httpx.Client(base_url="http://t", transport=httpx.MockTransport(stall)) as http:
        with pytest.raises(httpx.ReadTimeout):
            SwitchyardClient(http).health()
~~~

- `FakeSwitchyard.__call__` makes an instance callable like a function, which is what `MockTransport` wants. `match` on `(method, path parts)` routes each request, with a **guard** (`if int(job_id) in self.jobs`) that falls through to the `404` case.
- The `client` fixture asks for the `fake` fixture, so a test that takes both gets the same fake its client talks to: `test_busy_raises_with_retry_after` sets `fake.busy`, then watches the client's error.
- `test_a_stalled_server_times_out` raises `httpx.ReadTimeout` from the transport: a server that accepted the connection and never answered, tested in no time at all.

~~~bash
uv run pytest -q
~~~

~~~text
..........................                                               [100%]
26 passed in 0.27s
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

### Step 3: A smoke test against the real Switchyard

A **smoke test** checks, quickly, that a running system is basically working before you do anything bigger with it. In `src/kload/cli.py`, change the imports:

<!-- edit: src/kload/cli.py -->
~~~python
import argparse
import sys
from pathlib import Path

from kload.stats import summarize
~~~

to:

~~~python
import argparse
import sys
import time
from pathlib import Path

import httpx

from kload.client import ApiError, SwitchyardClient
from kload.stats import summarize
~~~

add the command before `build_parser`:

<!-- edit: src/kload/cli.py -->
~~~python
def build_parser() -> argparse.ArgumentParser:
~~~

to:

~~~python
def cmd_smoke(args: argparse.Namespace) -> int:
    key = f"smoke-{time.time_ns()}"
    with httpx.Client(base_url=args.url, timeout=5) as http:
        client = SwitchyardClient(http)
        try:
            print(f"health: {client.health()}")
            job = client.create_job("smoke test", duration_ms=args.duration_ms, key=key)
            print(f"created job {job.id}: {job.state}")
            again = client.create_job("smoke test", duration_ms=args.duration_ms, key=key)
            print(
                f"same key again: job {again.id}"
                + (" (the same job)" if again.id == job.id else "")
            )
            job = client.cancel_job(job.id)
            print(f"cancelled job {job.id}: {job.state}")
        except (ApiError, httpx.HTTPError) as exc:
            print(f"kload: {exc}", file=sys.stderr)
            return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
~~~

and give it a subcommand:

<!-- edit: src/kload/cli.py -->
~~~python
    p.set_defaults(handler=cmd_summarize)
    return parser
~~~

to:

~~~python
    p.set_defaults(handler=cmd_summarize)

    p = sub.add_parser("smoke", help="check a running Switchyard end to end")
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--duration-ms", type=int, default=100)
    p.set_defaults(handler=cmd_smoke)
    return parser
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

Start Switchyard from core 01 in another terminal, without any workers, so that jobs stay queued and can be cancelled:

~~~bash
cd ~/blueprint/switchyard && go run ./cmd/switchyard
~~~

Then, in the `kload` folder:

~~~bash
uv run kload smoke
~~~

~~~text
health: ok
created job 1: queued
same key again: job 1 (the same job)
cancelled job 1: cancelled
~~~

Every line is one call: health, a new job, the same request again with the same idempotency key (Switchyard handed back the same job instead of making a second), and a cancel. Stop Switchyard, and run it again:

~~~bash
uv run kload smoke
~~~

~~~text
kload: [Errno 111] Connection refused
exit 1
~~~

A one-line error and exit status 1, not a traceback: `cmd_smoke` catches httpx's `HTTPError`, which every connection failure and timeout inherits from.

## Break it

**Forget the plain-text case.** In `_check`, replace the `match` with just `message = response.json().get("error", response.text)`, and run the tests:

~~~text
../../.local/share/uv/python/cpython-3.14.7-linux-x86_64-gnu/lib/python3.14/json/decoder.py:363: JSONDecodeError
=========================== short test summary info ============================
FAILED tests/test_client.py::test_a_plain_text_error_is_still_an_api_error - ...
1 failed, 8 passed in 0.16s
~~~

`test_a_plain_text_error_is_still_an_api_error` failed with a `JSONDecodeError`: the client crashed on Go's own `405` page instead of reporting it. Put the `match` back.

## Check it

~~~bash
uv run ruff format --check . && uv run ruff check . && uv run pytest -q
~~~

Then, from memory: what does `MockTransport` replace, and why does the client never notice? What makes `FakeSwitchyard` a fake rather than a mock? Which of Switchyard's errors come as JSON, and which don't?

This proves the client handles the answers the fake gives. It doesn't prove the fake matches Switchyard: the smoke test against the real service is what checks that, and it's worth running again whenever Switchyard changes.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `kload: [Errno 111] Connection refused` | Switchyard isn't running, or it's on another port | Start it; `--url http://127.0.0.1:PORT` |
| `cancelled job 1: completed`, or `409: ...` on cancel | A worker is running and finished the job first | Stop the workers, or create a longer job with `--duration-ms 60000` |
| `same key again: job 2` | Switchyard runs without the idempotency middleware | Core 01 lesson 14, step 2 |
| `TypeError: 'FakeSwitchyard' object is not callable` | `__call__` misspelled | It needs the two underscores on both sides |
| `httpx.UnsupportedProtocol` | A URL without `http://` | `--url http://127.0.0.1:8080` |
