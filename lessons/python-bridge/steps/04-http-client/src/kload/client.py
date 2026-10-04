"""A small client for the Phase 1 jobs API."""

from dataclasses import dataclass
from typing import Any

import httpx


class ApiError(Exception):
    """The API answered with a status the caller didn't expect."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(f"{status}: {message}")
        self.status = status
        self.message = message


@dataclass(frozen=True)
class Job:
    id: int
    state: str
    description: str
    duration_ms: int
    failure_reason: str = ""

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Job":
        return cls(
            id=data["id"],
            state=data["state"],
            description=data["description"],
            duration_ms=data["duration_ms"],
            failure_reason=data.get("failure_reason", ""),
        )


class JobsClient:
    """Calls the jobs API through an httpx.Client it is given.

    The caller builds the httpx.Client (base URL, timeouts, transport), so
    tests can pass one whose transport never touches the network.
    """

    def __init__(self, http: httpx.Client) -> None:
        self._http = http

    def health(self) -> str:
        return _check(self._http.get("/health"), 200)["status"]

    def create_job(self, description: str, duration_ms: int = 0) -> Job:
        response = self._http.post(
            "/jobs", json={"description": description, "duration_ms": duration_ms}
        )
        return Job.from_json(_check(response, 201))

    def get_job(self, job_id: int) -> Job:
        return Job.from_json(_check(self._http.get(f"/jobs/{job_id}"), 200))

    def run_job(self, job_id: int) -> Job:
        """Run a job. A 504 still returns the job, which is now failed."""
        return Job.from_json(_check(self._http.post(f"/jobs/{job_id}/run"), 200, 504))


def _check(response: httpx.Response, *expected: int) -> dict[str, Any]:
    if response.status_code not in expected:
        try:
            message = response.json().get("error", response.text)
        except ValueError:
            message = response.text.strip()
        raise ApiError(response.status_code, message)
    return response.json()
