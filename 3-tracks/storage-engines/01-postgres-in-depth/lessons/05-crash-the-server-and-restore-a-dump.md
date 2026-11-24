# 05 Crash the server and restore a dump

> Postgres in depth · Week 2

## The problem

A restarted server can recover durable work from its own WAL. A lost data directory and a logical mistake require a backup plan. Run the two drills separately and identify which versions each can recover.

## The mental model

~~~text
acknowledged commit → WAL → process dies → restart the same data directory
logical snapshot → later source commit → restore selected objects into a fresh database
~~~

## The pattern

WAL records the changes needed to replay after a checkpoint. The gate verifies fsync and synchronous commit, then waits for an open transaction to perform a write before killing its disposable server. The acknowledged row must survive and the uncommitted row must be absent. A logical dump is a snapshot of selected objects. A restore reproduces that snapshot in a fresh database. [PostgreSQL SQL dump](https://www.postgresql.org/docs/17/backup-dump.html) · [PostgreSQL WAL and recovery](https://www.postgresql.org/docs/17/continuous-archiving.html)

## Build it

### Create distinguishable recovery markers

Keep explicit committed row names so the gate can compare whole contents.

Create `sql/04-recovery.sql`.

<!-- file: sql/04-recovery.sql -->
~~~sql
CREATE TABLE recovery_marks (
    name text PRIMARY KEY,
    committed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
~~~

### Automate the recovery assertions

Use a completed open-transaction statement as the crash signal. After restart, dump the marker table and compare it with the source after another commit. The same driver contains the PITR step used in the next lesson.

Create `lab/recovery.py`.

<!-- file: lab/recovery.py -->
~~~python
"""Crash, logical restore, and PITR drills for the owned gate container."""

import os
import select
import subprocess
import time


def call(*args, data=None, timeout=45):
    result = subprocess.run(args, input=data, capture_output=True, timeout=timeout)
    if result.returncode:
        detail = result.stderr.decode(errors="replace").strip()
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {detail}")
    return result.stdout


def docker(*args, **kwargs):
    return call("docker", *args, **kwargs).decode().strip()


def psql(container, statement, *, db="storage", port="5432", socket="/var/run/postgresql"):
    return docker("exec", "-i", "--user", "postgres", container, "psql", "-XAtq",
                  "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-h", socket, "-p", port,
                  "-d", db, data=statement.encode())


def wait(check, label, seconds=35):
    end = time.monotonic() + seconds
    last_failure = None
    while time.monotonic() < end:
        try:
            if check():
                return
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            last_failure = exc
        time.sleep(0.2)
    raise RuntimeError(f"timed out waiting for {label}") from last_failure


def mark_names(container, **kwargs):
    return psql(container, "SELECT string_agg(name, ',' ORDER BY name) FROM recovery_marks;", **kwargs)


def crash_recovery(container):
    assert psql(container, "SHOW fsync; SHOW synchronous_commit;") == "on\non"
    psql(container, "INSERT INTO recovery_marks (name) VALUES ('committed');")
    child = subprocess.Popen(
        ["docker", "exec", "-i", "--user", "postgres", container, "psql",
         "-XAtq", "-v", "ON_ERROR_STOP=1", "-d", "storage"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    try:
        child.stdin.write(b"BEGIN;\nINSERT INTO recovery_marks (name) VALUES ('uncommitted');\n"
                          b"\\echo transaction-open\n")
        child.stdin.flush()
        end = time.monotonic() + 8
        seen = b""
        while b"transaction-open" not in seen and time.monotonic() < end:
            if not select.select([child.stdout], [], [], max(0, end - time.monotonic()))[0]:
                break
            block = os.read(child.stdout.fileno(), 4096)
            if not block:
                break
            seen += block
        assert b"transaction-open" in seen, "did not observe the completed statement inside an open transaction"

        started = time.monotonic()
        docker("kill", "--signal=KILL", container)
        child.wait(timeout=8)
        docker("start", container)
        wait(lambda: psql(container, "SELECT 1;") == "1", "crash recovery")
        assert mark_names(container) == "committed"
        elapsed = time.monotonic() - started
        print(f"crash recovery: acknowledged row survived SIGKILL; open transaction absent; ready in {elapsed:.2f}s",
              flush=True)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=8)
        child.stdin.close()
        child.stdout.close()
        child.stderr.close()


def logical_restore(container):
    archive = call(
        "docker", "exec", "--user", "postgres", container, "pg_dump",
        "--format=custom", "--table=public.recovery_marks", "--dbname=storage",
    )
    psql(container, "INSERT INTO recovery_marks (name) VALUES ('after-logical');")
    psql(container, "CREATE DATABASE logical_restore;")
    started = time.monotonic()
    call("docker", "exec", "-i", "--user", "postgres", container, "pg_restore",
         "--exit-on-error", "--no-owner", "--dbname=logical_restore", data=archive)
    assert mark_names(container, db="logical_restore") == "committed"
    assert mark_names(container) == "after-logical,committed"
    elapsed = time.monotonic() - started
    print(f"logical restore: snapshot row present, later committed row absent; restore took {elapsed:.2f}s", flush=True)


def point_in_time(container):
    # The copy and target socket are both separate from the original PGDATA.
    docker("exec", "--user", "postgres", container, "pg_basebackup",
           "-D", "/tmp/pg-base", "-Fp", "-X", "stream", "--checkpoint=fast",
           "-h", "/var/run/postgresql", "-U", "postgres", "--no-password")
    psql(container, "INSERT INTO recovery_marks (name) VALUES ('before-target');")
    lsn = psql(container, "SELECT pg_create_restore_point('switchyard_before_delete');")
    psql(container, "DELETE FROM recovery_marks WHERE name = 'before-target';\n"
                    "INSERT INTO recovery_marks (name) VALUES ('after-target');")
    assert mark_names(container) == "after-logical,after-target,committed"
    segment = psql(container, "SELECT pg_walfile_name(pg_current_wal_lsn());")
    psql(container, "SELECT pg_switch_wal();")
    wait(lambda: docker("exec", container, "test", "-s", f"/tmp/pg-archive/{segment}") == "",
         "archived WAL")

    config = b"""restore_command = 'cp /tmp/pg-archive/%f %p'
recovery_target_name = 'switchyard_before_delete'
recovery_target_action = 'promote'
"""
    docker("exec", "-i", "--user", "postgres", container, "sh", "-c",
           "mkdir -p /tmp/pg-restore-socket && touch /tmp/pg-base/recovery.signal && "
           "cat >> /tmp/pg-base/postgresql.auto.conf", data=config)
    started = time.monotonic()
    try:
        docker("exec", "--user", "postgres", container, "pg_ctl", "-D", "/tmp/pg-base",
               "-l", "/tmp/pg-pitr.log", "-o",
               "-p 55432 -k /tmp/pg-restore-socket -c listen_addresses='' -c archive_mode=off",
               "-t", "25", "-w", "start")
        target = {"port": "55432", "socket": "/tmp/pg-restore-socket"}
        wait(lambda: psql(container, "SELECT pg_is_in_recovery();", **target) == "f", "target promotion")
        assert mark_names(container, **target) == "after-logical,before-target,committed"
        assert mark_names(container) == "after-logical,after-target,committed"
        elapsed = time.monotonic() - started
        print(f"PITR: replayed archived WAL to {lsn}; recovered the pre-delete row, excluded the later write; "
              f"target ready in {elapsed:.2f}s", flush=True)
    except Exception:
        print(docker("exec", container, "tail", "-n", "25", "/tmp/pg-pitr.log"), flush=True)
        raise
    finally:
        subprocess.run(
            ["docker", "exec", "--user", "postgres", container, "pg_ctl", "-D", "/tmp/pg-base",
             "-m", "fast", "-t", "10", "-w", "stop"],
            capture_output=True, check=False, timeout=15,
        )
~~~

## Check it

~~~bash
python3 -m py_compile lab/recovery.py
~~~

<!-- run: python3 -m py_compile lab/recovery.py -->

In the live run, the acknowledged row survived SIGKILL. A selected-table logical dump restored that row and omitted the later committed marker. Use these checks to distinguish the age of the recovered state from the time it took to restore. The measured times cover only this disposable run.
