"""Run the cache integration tests against disposable Redis and PostgreSQL."""

import os
import subprocess
import time
from uuid import uuid4


def command(*args, env=None, timeout=45):
    return subprocess.run(args, env=env, text=True, capture_output=True, timeout=timeout)


def checked(*args):
    result = command(*args)
    if result.returncode != 0:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout.strip()


def ready(*args, expected=None):
    end = time.monotonic() + 40
    while time.monotonic() < end:
        result = command(*args, timeout=5)
        if result.returncode == 0 and (expected is None or result.stdout.strip() == expected):
            return
        time.sleep(0.25)
    raise RuntimeError(f"service did not become ready: {result.stdout.strip()} {result.stderr.strip()}")


def exercise():
    stamp = uuid4().hex[:10]
    redis, db = f"sy-cache-redis-{stamp}", f"sy-cache-db-{stamp}"
    running = []
    try:
        checked("docker", "run", "-d", "--name", redis, "-p", "127.0.0.1::6379", "redis:8")
        running.append(redis)
        checked("docker", "run", "-d", "--name", db, "-p", "127.0.0.1::5432",
                "-e", "POSTGRES_PASSWORD=lab", "-e", "POSTGRES_DB=caching", "postgres:17")
        running.append(db)
        ready("docker", "exec", redis, "redis-cli", "PING", expected="PONG")
        ready("docker", "exec", db, "pg_isready", "-h", "127.0.0.1", "-d", "caching")
        redis_addr = checked("docker", "port", redis, "6379/tcp")
        pg_addr = checked("docker", "port", db, "5432/tcp")
        env = dict(
            os.environ,
            CACHE_TEST_LIVE="1",
            CACHE_REDIS_URL=f"redis://{redis_addr}/0",
            CACHE_DATABASE_URL=f"postgres://postgres:lab@{pg_addr}/caching?sslmode=disable",
        )
        subprocess.run(
            ["go", "test", "-race", "-count=1", "-v", "-run", "^TestLive$", "./internal/cache"],
            env=env, check=True, timeout=120,
        )
    except Exception:
        for name in running:
            logs = command("docker", "logs", "--tail", "15", name)
            print(logs.stdout + logs.stderr, flush=True)
        raise
    finally:
        for name in reversed(running):
            command("docker", "rm", "-fv", name)


if __name__ == "__main__":
    exercise()
