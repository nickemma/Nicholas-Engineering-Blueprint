"""Check tenant boundaries and a shared bucket with disposable services."""

import base64
import json
import os
from pathlib import Path
import secrets
import select
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
from urllib.request import Request, urlopen
from uuid import uuid4


def run(*args, data=None, env=None, timeout=45):
    return subprocess.run(args, input=data, env=env, capture_output=True, text=True, timeout=timeout)


def checked(*args, **kwargs):
    result = run(*args, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout.strip()


def ready(*args, expected=None):
    end = time.monotonic() + 45
    while time.monotonic() < end:
        result = run(*args, timeout=5)
        if result.returncode == 0 and (expected is None or result.stdout.strip() == expected):
            return
        time.sleep(0.25)
    raise RuntimeError(f"service did not become ready: {result.stderr.strip()}")


def exercise_cli(env):
    with TemporaryDirectory(prefix="sy-tenant-cli-") as tmp:
        binary = Path(tmp) / "tenant-lab"
        checked("go", "build", "-buildvcs=false", "-o", binary, "./cmd/tenant-lab", env=env, timeout=120)
        fixture = Path(tmp) / "clients.json"
        secret = secrets.token_hex(24)
        fixture.write_text(json.dumps({"smoke": {"tenant": "smoke", "role": "writer", "secret": secret}}))
        fixture.chmod(0o600)
        child = subprocess.Popen(
            [binary], env=dict(env, TENANT_CREDENTIALS_FILE=str(fixture), TENANT_LAB_ADDR="127.0.0.1:0",
                               TENANT_QUOTA_MODE="local"),
            stderr=subprocess.PIPE, text=True,
        )
        try:
            if not select.select([child.stderr], [], [], 8)[0]:
                raise AssertionError("CLI listener did not become ready")
            _, marker, addr = child.stderr.readline().strip().partition("tenant lab listening on ")
            assert marker and addr.startswith("127.0.0.1:"), "CLI failed to start on loopback"
            endpoint = f"http://{addr}"

            def request(path, method="GET", authorization="", body=None):
                headers = {"Authorization": authorization} if authorization else {}
                req = Request(endpoint + path, method=method, data=body, headers=headers)
                with urlopen(req, timeout=5) as reply:
                    return reply.status, reply.read(4096)

            status, raw = request("/jwks.json")
            keys = json.loads(raw)["keys"]
            assert status == 200 and len(keys) == 1 and "d" not in keys[0]
            basic = base64.b64encode(f"smoke:{secret}".encode()).decode()
            status, raw = request("/token", "POST", f"Basic {basic}")
            assert status == 200
            token = "Bearer " + json.loads(raw)["access_token"]
            status, _ = request("/jobs", "POST", token, b'{"id":"fixture","name":"smoke fixture"}')
            assert status == 201
            status, raw = request("/jobs/fixture", authorization=token)
            assert status == 200 and json.loads(raw) == {"id": "fixture", "name": "smoke fixture"}
            print("CLI smoke: published public keys, issued a token, and created and read a scoped job", flush=True)
        finally:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)


def exercise(schema):
    stamp = uuid4().hex[:10]
    db, redis = f"sy-tenant-db-{stamp}", f"sy-tenant-redis-{stamp}"
    admin_password, runtime_password = secrets.token_hex(24), secrets.token_hex(24)
    running = []
    try:
        checked("docker", "run", "-d", "--name", db, "-p", "127.0.0.1::5432",
                "-e", f"POSTGRES_PASSWORD={admin_password}", "-e", "POSTGRES_DB=tenancy", "postgres:17")
        running.append(db)
        checked("docker", "run", "-d", "--name", redis, "-p", "127.0.0.1::6379", "redis:8")
        running.append(redis)
        ready("docker", "exec", db, "pg_isready", "-h", "127.0.0.1", "-d", "tenancy")
        ready("docker", "exec", redis, "redis-cli", "PING", expected="PONG")
        psql = ("docker", "exec", "-i", db, "psql", "-U", "postgres", "-d", "tenancy", "-v", "ON_ERROR_STOP=1")
        checked(*psql, data=f"CREATE ROLE tenant_api LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '{runtime_password}';")
        checked(*psql, data=schema.read_text())
        checked(*psql, data="""INSERT INTO tenant_lab.jobs (tenant, id, name) VALUES
          ('acme', 'shared', 'Acme fixture'),
          ('blue', 'shared', 'Blue fixture'),
          ('blue', 'blue-only', 'Blue private fixture');
        """)
        pg_addr = checked("docker", "port", db, "5432/tcp")
        redis_addr = checked("docker", "port", redis, "6379/tcp")

        env = dict(os.environ, TENANT_TEST_LIVE="1", TENANT_TEST_PER_REPLICA="0",
                   TENANT_DB_URL=f"postgres://tenant_api:{runtime_password}@{pg_addr}/tenancy?sslmode=disable",
                   TENANT_REDIS_URL=f"redis://{redis_addr}/0")
        exercise_cli(env)
        command = ("go", "test", "-race", "-count=1", "-v", "./internal/api", "-run")
        reference = run(*command, "^TestLive$", env=env, timeout=120)
        print(reference.stdout + reference.stderr, end="", flush=True)
        reference.check_returncode()

        # Deliberately choose internal per-instance buckets in this test
        # fixture and run the same shared-budget check on the two instances.
        variant = run(*command, "^TestLive$/^shared_quota$",
                      env=dict(env, TENANT_TEST_PER_REPLICA="1"), timeout=120)
        output = variant.stdout + variant.stderr
        print(output, end="", flush=True)
        if variant.returncode != 1 or "shared quota: accepted=4, want 2; limited=12, want 14" not in output:
            raise AssertionError("quota negative control did not report the expected doubled budget")
        print("negative control: independent replicas doubled the fixture tenant's allowance", flush=True)
    finally:
        for name in reversed(running):
            run("docker", "rm", "-fv", name)


if __name__ == "__main__":
    exercise(Path(sys.argv[1]))
