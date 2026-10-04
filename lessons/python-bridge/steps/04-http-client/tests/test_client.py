import json

import httpx
import pytest

from kload.client import ApiError, Job, JobsClient


def fake_api(request: httpx.Request) -> httpx.Response:
    """Pretends to be the Phase 1 API, just enough for these tests."""
    job = {"id": 1, "state": "queued", "description": "resize", "duration_ms": 50}
    match (request.method, request.url.path):
        case ("GET", "/health"):
            return httpx.Response(200, json={"status": "ok"})
        case ("POST", "/jobs"):
            body = json.loads(request.content)
            if not body["description"]:
                return httpx.Response(
                    400, json={"error": "description must be between 1 and 200 characters"}
                )
            return httpx.Response(201, json=job)
        case ("GET", "/jobs/1"):
            return httpx.Response(200, json=job)
        case ("POST", "/jobs/1/run"):
            return httpx.Response(200, json=job | {"state": "completed"})
        case ("POST", "/jobs/2/run"):
            failed = job | {"id": 2, "state": "failed", "failure_reason": "deadline exceeded"}
            return httpx.Response(504, json=failed)
        case _:
            return httpx.Response(404, json={"error": "job not found"})


@pytest.fixture
def client():
    http = httpx.Client(base_url="http://kestrel.test", transport=httpx.MockTransport(fake_api))
    with http:
        yield JobsClient(http)


def test_health(client):
    assert client.health() == "ok"


def test_create_job(client):
    assert client.create_job("resize", duration_ms=50) == Job(
        id=1, state="queued", description="resize", duration_ms=50
    )


def test_run_job(client):
    assert client.run_job(1).state == "completed"


def test_run_past_deadline_returns_the_failed_job(client):
    job = client.run_job(2)
    assert (job.state, job.failure_reason) == ("failed", "deadline exceeded")


def test_api_error_carries_status_and_message(client):
    with pytest.raises(ApiError) as caught:
        client.create_job("")
    assert caught.value.status == 400
    assert "description" in caught.value.message


def test_unknown_job(client):
    with pytest.raises(ApiError, match="404: job not found"):
        client.get_job(99)
