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
        message = response.json().get("error", response.text)
        raise ApiError(response.status_code, message, response.headers.get("retry-after"))
    return response.json()
