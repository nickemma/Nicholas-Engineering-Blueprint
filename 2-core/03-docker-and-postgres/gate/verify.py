"""Exercise Switchyard through HTTP, gRPC, and its lab Compose stack."""

import argparse
import http.client
import json
import subprocess
import time


class Stack:
    def __init__(self, project, probe):
        self.project = project
        self.probe = probe
        self.http = ""
        self.grpc = ""

    def compose(self, *args):
        return subprocess.check_output(
            ["docker", "compose", "-p", self.project, *args], text=True, timeout=45
        ).strip()

    def request(self, method, route, body=None, key=None):
        headers = {"Content-Type": "application/json"} if body is not None else {}
        if key is not None:
            headers["Idempotency-Key"] = key
        conn = http.client.HTTPConnection(self.http, timeout=3)
        try:
            conn.request(method, route, body, headers)
            response = conn.getresponse()
            return response.status, response.getheader("Location"), response.getheader(
                "Idempotent-Replayed"
            ), response.read()
        finally:
            conn.close()

    def ready(self):
        self.http = self.compose("port", "api", "8080")
        self.grpc = self.compose("port", "api", "9090")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                if self.request("GET", "/health")[0] == 200:
                    return
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(0.1)
        raise RuntimeError("Switchyard did not become ready")

    def lease(self):
        output = subprocess.check_output([self.probe, self.grpc, "lease"], text=True, timeout=10)
        return tuple(map(int, output.split()))

    def complete(self, job, token):
        return subprocess.run(
            [self.probe, self.grpc, "complete", str(job), str(token)],
            capture_output=True, text=True, timeout=10, check=False,
        )

    def read(self, route):
        status, _, _, data = self.request("GET", route)
        if status != 200:
            raise RuntimeError(f"{route}: HTTP {status} {data!r}")
        return json.loads(data)

    def check(self):
        self.ready()
        payload = b'{"description":"gate: recover me","duration_ms":0}'
        first = self.request("POST", "/jobs", payload, "gate-restart")
        if first[0] != 201 or first[2] is not None:
            raise RuntimeError(f"initial submission: {first!r}")
        job = json.loads(first[3])["id"]
        leased, token = self.lease()
        if leased != job or self.read(f"/jobs/{job}")["state"] != "running":
            raise RuntimeError("probe did not hold the job before crash")

        self.compose("kill", "-s", "SIGKILL", "api")
        self.compose("start", "api")
        self.ready()
        again = self.request("POST", "/jobs", payload, "gate-restart")
        if again != (201, first[1], "true", first[3]):
            raise RuntimeError(f"retry after API crash: {again!r}")
        changed = self.request(
            "POST", "/jobs", b'{"description":"changed","duration_ms":0}', "gate-restart"
        )
        if changed[0] != 422:
            raise RuntimeError(f"changed payload: {changed!r}")
        print("same key and original 201 survived SIGKILL; changed payload returned 422")

        if self.read(f"/jobs/{job}")["state"] != "queued":
            raise RuntimeError("interrupted job was not recovered to queued")
        leased, replacement = self.lease()
        if leased != job or replacement <= token:
            raise RuntimeError(f"recovery gave job {leased} token {replacement} after {token}")
        obsolete = self.complete(job, token)
        if obsolete.returncode == 0 or "FailedPrecondition" not in obsolete.stderr:
            raise RuntimeError(f"old completion did not get FailedPrecondition: {obsolete}")
        accepted = self.complete(job, replacement)
        if accepted.returncode != 0:
            raise RuntimeError(f"replacement completion was refused: {accepted.stderr}")
        if self.complete(job, replacement).returncode != 0:
            raise RuntimeError("replacement completion could not be retried")
        self.verify_completed(job)
        print(f"job {job} recovered; token {token} refused; token {replacement} recorded one effect")

        before = self.compose("ps", "-q", "postgres")
        self.compose("stop", "api", "postgres")
        self.compose("rm", "-f", "postgres")
        self.compose("up", "-d", "--wait", "postgres")
        after = self.compose("ps", "-q", "postgres")
        if not before or not after or before == after:
            raise RuntimeError("the PostgreSQL container was not replaced")
        self.compose("start", "api")
        self.ready()
        self.verify_completed(job)
        if self.request("POST", "/jobs", payload, "gate-restart") != again:
            raise RuntimeError("the retry record was lost after replacing PostgreSQL")
        print("a replacement PostgreSQL container kept the job, effect, and retry record")

        self.compose("up", "-d", "--no-deps", "worker")
        status, _, _, body = self.request("POST", "/jobs", b'{"description":"worker","duration_ms":0}')
        if status != 201:
            raise RuntimeError(f"worker smoke submission: HTTP {status} {body!r}")
        worker_job = json.loads(body)["id"]
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if self.read(f"/jobs/{worker_job}")["state"] == "completed":
                self.verify_completed(worker_job)
                print("the Compose worker completed a new job")
                return
            time.sleep(0.1)
        raise RuntimeError("the Compose worker did not complete its job")

    def verify_completed(self, job):
        if self.read(f"/jobs/{job}")["state"] != "completed":
            raise RuntimeError(f"job {job} was not completed")
        if self.read(f"/effects/{job}") != {"job_id": job, "effects": 1}:
            raise RuntimeError(f"job {job} did not have exactly one effect")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project")
    parser.add_argument("leaseprobe")
    args = parser.parse_args()
    Stack(args.project, args.leaseprobe).check()


if __name__ == "__main__":
    main()
