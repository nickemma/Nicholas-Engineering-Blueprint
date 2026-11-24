"""Disposable RabbitMQ and PostgreSQL gate, including a crash before ack."""

import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid


def command(*args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, timeout=25, **kwargs)


def checked(*args, **kwargs):
    result = command(*args, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout.strip()


def wait(check, what, timeout=25):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if value := check():
            return value
        time.sleep(0.2)
    raise AssertionError("timed out: " + what)


@contextlib.contextmanager
def containers():
    stamp = uuid.uuid4().hex[:10]
    rabbit, db = f"sy-rabbit-{stamp}", f"sy-inbox-{stamp}"
    running = []
    try:
        checked("docker", "run", "-d", "--name", rabbit, "--user", "999:999", "-p", "127.0.0.1::5672",
                "-e", "RABBITMQ_DEFAULT_USER=lab", "-e", "RABBITMQ_DEFAULT_PASS=lab",
                "rabbitmq:4-management")
        running.append(rabbit)
        checked("docker", "run", "-d", "--name", db, "-p", "127.0.0.1::5432",
                "-e", "POSTGRES_PASSWORD=lab", "-e", "POSTGRES_DB=messaging", "postgres:17")
        running.append(db)
        wait(lambda: command("docker", "exec", rabbit, "rabbitmq-diagnostics", "-q",
                             "check_running").returncode == 0, "RabbitMQ ready", 60)
        wait(lambda: command("docker", "exec", db, "pg_isready", "-h", "127.0.0.1",
                             "-d", "messaging").returncode == 0, "PostgreSQL ready", 60)
        amqp = checked("docker", "port", rabbit, "5672/tcp")
        pg = checked("docker", "port", db, "5432/tcp")
        yield dict(os.environ, MESSAGING_AMQP_URL=f"amqp://lab:lab@{amqp}/",
                   MESSAGING_DATABASE_URL=f"postgres://postgres:lab@{pg}/messaging?sslmode=disable")
    except Exception:
        for name in running:
            logs = command("docker", "logs", "--tail", "25", name)
            print(f"{name}:\n{logs.stdout}{logs.stderr}", file=sys.stderr)
        raise
    finally:
        for name in running:
            command("docker", "rm", "-fv", name)


@contextlib.contextmanager
def worker(binary, env, root, *args):
    path = root / "worker.log"
    with path.open("w") as log:
        child = subprocess.Popen([binary, "work", *args], env=env, stdout=log, stderr=log)
        try:
            def ready():
                lines = path.read_text()
                if child.poll() is not None:
                    raise AssertionError(lines)
                return "worker receiving" in lines
            wait(ready, "worker ready")
            yield path
        finally:
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
                raise


def scenario(binary, check_all):
    with containers() as env, tempfile.TemporaryDirectory(prefix="sy-messages-") as tmp:
        root = Path(tmp)
        fixture = root / "command.json"

        def send(ident, job, version):
            fixture.write_text(json.dumps({"id": ident, "kind": "record-job", "version": version,
                                           "payload": {"job_id" if version == 1 else "job": job}}))
            checked(binary, "send", "-input", fixture, env=env)

        def drain(queue):
            result = checked(binary, "drain", "-queue", queue, env=env)
            return [json.loads(json.loads(line)) for line in result.splitlines()]

        def count():
            return int(checked(binary, "count", env=env))

        send("stable", "job-1", 1)
        stopped = command(binary, "work", "-crash-after-commit", env=env)
        # With a race build, os.Exit remains an intentional process stop.
        assert stopped.returncode == 70 and "before acknowledgment" in stopped.stderr, stopped.stderr
        assert count() == 1
        print("crash: committed one durable effect and stopped before publishing", flush=True)

        with worker(binary, env, root) as log:
            seen = []
            def completion():
                seen.extend(drain("switchyard.events"))
                return any(e["id"] == "stable:recorded" for e in seen)
            try:
                wait(completion, "recovered completion", 5)
            except AssertionError as failure:
                if str(failure) == "timed out: recovered completion":
                    print("FAIL acknowledged command could not be delivered again after the crash")
                    return 42
                raise
            wait(lambda: "redelivered=true" in log.read_text(), "redelivery acknowledged")
            assert count() == 1
            print("replacement: received the redelivery and published a completion; one durable effect", flush=True)
            if check_all:
                seen.clear()
                send("stable", "job-1", 2)
                wait(completion, "compatible version-2 completion")
                assert count() == 1
                send("unsupported", "job-x", 99)
                send("stable", "conflicting-job", 2)
                dead = []
                def blocked_inputs():
                    dead.extend(drain("switchyard.dead"))
                    return {x["payload"].get("job") for x in dead} >= {"job-x", "conflicting-job"}
                wait(blocked_inputs, "permanent input failures in the DLQ")
                assert count() == 1
                print("compatibility: v1 and v2 shared one effect; unsupported schema and ID conflict dead-lettered",
                      flush=True)
        if check_all:
            with worker(binary, env, root, "-refuse-job", "busy") as log:
                send("transient", "busy", 2)
                wait(lambda: any(x["id"] == "transient" for x in drain("switchyard.dead")),
                     "bounded transient redelivery budget")
                assert "lab storage fault" in log.read_text()
                assert count() == 1
                print("retry limit: repeated dependency failure exhausted the quorum queue budget", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(scenario(str(Path(sys.argv[1]).resolve()), "--crash-only" not in sys.argv[2:]))
