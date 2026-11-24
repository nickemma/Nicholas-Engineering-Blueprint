"""Create and remove the disposable server used by the storage checks."""

import os
from pathlib import Path
import secrets
import subprocess
import sys
from uuid import uuid4

from lab.recovery import crash_recovery, docker, logical_restore, point_in_time, psql, wait


def check(name):
    workspace = Path.cwd()
    password = secrets.token_hex(24)
    archive = (
        "if test -f '/tmp/pg-archive/%f'; then cmp -s '%p' '/tmp/pg-archive/%f'; "
        "else cp '%p' '/tmp/pg-archive/%f.partial' && "
        "mv '/tmp/pg-archive/%f.partial' '/tmp/pg-archive/%f'; fi"
    )
    docker("run", "-d", "--name", name, "-p", "127.0.0.1::5432",
           "-e", f"POSTGRES_PASSWORD={password}", "-e", "POSTGRES_DB=storage",
           "postgres:17", "-c", "archive_mode=on", "-c", f"archive_command={archive}")
    try:
        # pg_isready over TCP excludes the transient init-only server.
        wait(lambda: docker("exec", name, "pg_isready", "-h", "127.0.0.1", "-d", "storage"),
             "source PostgreSQL")
        docker("exec", "--user", "postgres", name, "mkdir", "-p", "/tmp/pg-archive")
        print("PostgreSQL " + psql(name, "SHOW server_version;"), flush=True)
        for step in ("01-isolation.sql", "02-plan-fixture.sql", "03-queue.sql", "04-recovery.sql"):
            psql(name, (workspace / "sql" / step).read_text())
        address = docker("port", name, "5432/tcp")
        env = dict(os.environ, STORAGE_TEST_LIVE="1",
                   STORAGE_DATABASE_URL=f"postgres://postgres:{password}@{address}/storage?sslmode=disable")
        tests = ["go", "test", "-count=1", "-race", "-v", "./lab"]
        subprocess.run(tests, env=env, check=True, timeout=120)

        psql(name, "CREATE DATABASE negative_control;")
        original = (workspace / "sql" / "03-queue.sql").read_text()
        variant = original.replace("FOR UPDATE SKIP LOCKED", "FOR UPDATE", 1)
        assert variant != original
        psql(name, variant, db="negative_control")
        failure = subprocess.run(
            [*tests, "-run", "^TestLive$/^queue$"],
            env=dict(env, STORAGE_DATABASE_URL=env["STORAGE_DATABASE_URL"].replace("/storage?", "/negative_control?")),
            capture_output=True, text=True, timeout=120,
        )
        output = failure.stdout + failure.stderr
        print(output, end="", flush=True)
        assert failure.returncode == 1 and "claim cannot proceed: SQLSTATE 55P03" in output
        print("negative control: removing SKIP LOCKED made the second claimant time out", flush=True)

        crash_recovery(name)
        logical_restore(name)
        point_in_time(name)
    except Exception:
        logs = subprocess.run(["docker", "logs", "--tail", "25", name], capture_output=True, text=True, timeout=10)
        print(logs.stdout + logs.stderr, file=sys.stderr, flush=True)
        raise
    finally:
        subprocess.run(["docker", "rm", "-fv", name], capture_output=True, timeout=15, check=False)


if __name__ == "__main__":
    check("sy-pg-depth-" + uuid4().hex[:10])
