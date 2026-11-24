"""Check both commit boundaries and replay against disposable stores."""

from contextlib import contextmanager
import json
import os
import re
import socket
import subprocess
import sys
import time
from uuid import uuid4


def run(*args, env=None):
    return subprocess.run(args, env=env, capture_output=True, text=True, timeout=55)


def checked(*args, env=None):
    result = run(*args, env=env)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout.strip()


def ready(*args):
    end = time.monotonic() + 60
    while time.monotonic() < end:
        result = run(*args)
        if result.returncode == 0:
            return
        time.sleep(0.5)
    raise AssertionError(f"service startup timed out: {result.stderr.strip()}")


@contextmanager
def lab():
    stamp = uuid4().hex[:10]
    db, broker = f"sy-stream-db-{stamp}", f"sy-stream-kafka-{stamp}"
    running = []
    # Kafka advertises the connection address in metadata. Reserve a port
    # candidate so the advertised address matches the Docker port mapping.
    with socket.socket() as candidate:
        candidate.bind(("127.0.0.1", 0))
        port = candidate.getsockname()[1]
    try:
        checked(
            "docker", "run", "-d", "--name", db, "-p", "127.0.0.1::5432",
            "-e", "POSTGRES_PASSWORD=lab", "-e", "POSTGRES_DB=streams", "postgres:17",
        )
        running.append(db)
        settings = {
            "KAFKA_NODE_ID": "1",
            "KAFKA_PROCESS_ROLES": "broker,controller",
            "KAFKA_LISTENERS": "PLAINTEXT://:9092,CONTROLLER://:9093,INTERNAL://:19092",
            "KAFKA_ADVERTISED_LISTENERS": f"PLAINTEXT://127.0.0.1:{port},INTERNAL://localhost:19092",
            "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP": "PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT,INTERNAL:PLAINTEXT",
            "KAFKA_INTER_BROKER_LISTENER_NAME": "INTERNAL",
            "KAFKA_CONTROLLER_LISTENER_NAMES": "CONTROLLER",
            "KAFKA_CONTROLLER_QUORUM_VOTERS": "1@localhost:9093",
            "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR": "1",
            "KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS": "0",
            "KAFKA_AUTO_CREATE_TOPICS_ENABLE": "false",
            "KAFKA_HEAP_OPTS": "-Xms256M -Xmx512M",
        }
        options = [argument for key, value in settings.items() for argument in ("-e", f"{key}={value}")]
        checked(
            "docker", "run", "-d", "--name", broker, "-p", f"127.0.0.1:{port}:9092",
            *options, "apache/kafka:4.1.0",
        )
        running.append(broker)
        ready("docker", "exec", db, "pg_isready", "-h", "127.0.0.1", "-d", "streams")
        ready("docker", "exec", broker, "/opt/kafka/bin/kafka-broker-api-versions.sh",
              "--bootstrap-server", "localhost:19092")
        address = checked("docker", "port", db, "5432/tcp")
        yield db, dict(
            os.environ,
            STREAMS_DATABASE_URL=f"postgres://postgres:lab@{address}/streams?sslmode=disable",
            STREAMS_KAFKA_BROKERS=f"127.0.0.1:{port}",
            STREAMS_TOPIC=f"switchyard-history-{stamp}",
        )
    except Exception:
        for container in running:
            logs = run("docker", "logs", "--tail", "25", container)
            print(logs.stdout + logs.stderr, file=sys.stderr)
        raise
    finally:
        for container in reversed(running):
            run("docker", "rm", "-fv", container)


# Include the actual Kafka partition and record offset in the assertions.
def coordinates(output):
    return [(int(p), int(o)) for p, o in re.findall(r"partition=(\d+) offset=(\d+)", output)]


def scenario(reference, variant):
    with lab() as (db, env):
        def app(*args, binary=reference):
            return checked(binary, *args, env=env)

        def project(group, limit, binary=reference):
            return app("project", "-group", group, "-limit", str(limit), binary=binary)

        def snapshot(group):
            return json.loads(app("snapshot", "-group", group))

        def sql(statement):
            return checked("docker", "exec", db, "psql", "-U", "postgres", "-d",
                           "streams", "-v", "ON_ERROR_STOP=1", "-Atc", statement)

        app("init")
        sql("ALTER TABLE event_outbox ADD CHECK (event_id <> 'blocked')")
        refused = run(reference, "record", "-id", "blocked", "-job", "job-a", env=env)
        assert refused.returncode != 0 and "violates check constraint" in refused.stderr, refused.stderr
        assert sql("SELECT count(*) FROM job_history") == "0"
        assert app("pending") == "0"
        print("writer: rejected the outbox insert and rolled back job history", flush=True)

        app("record", "-id", "event-1", "-job", "job-a")
        app("record", "-id", "event-1", "-job", "job-a")
        assert app("pending") == "1"
        stopped = run(reference, "relay", "-crash", env=env)
        assert stopped.returncode == 70 and app("pending") == "1", stopped.stderr
        first, = coordinates(stopped.stdout)
        duplicate, = coordinates(app("relay"))
        assert duplicate == (first[0], first[1] + 1)
        assert app("pending") == "0"
        print(f"relay: resent event-1 in partition {first[0]} at offsets {first[1]} and {duplicate[1]}",
              flush=True)

        stopped = run(reference, "project", "-group", "live", "-crash", env=env)
        assert stopped.returncode == 71 and "applied=true" in stopped.stdout, stopped.stderr
        assert coordinates(stopped.stdout) == [first]
        assert snapshot("live") == {"job-a": 1}
        replayed = project("live", 2)
        assert coordinates(replayed) == [first, duplicate]
        assert replayed.count("id=event-1") == 2 and replayed.count("applied=false") == 2
        assert snapshot("live") == {"job-a": 1}
        print("projector: reread the uncommitted offset and suppressed both duplicates", flush=True)

        app("record", "-id", "event-2", "-job", "job-a")
        app("record", "-id", "event-3", "-job", "job-b")
        second, other = coordinates(app("relay", "-limit", "2"))
        assert second == (first[0], duplicate[1] + 1)
        resumed = project("live", 2)
        assert sorted(coordinates(resumed)) == sorted([second, other])
        expected = {"job-a": 2, "job-b": 1}
        assert snapshot("live") == expected
        print(f"offsets: resumed at new records {second} and {other}; live model {snapshot('live')}",
              flush=True)

        replayed = project("rebuild", 4)
        assert sorted(coordinates(replayed)) == sorted([first, duplicate, second, other])
        assert snapshot("rebuild") == expected
        print(f"replay: a fresh group rebuilt {snapshot('rebuild')} from four Kafka records", flush=True)

        project("negative", 4, binary=variant)
        broken = snapshot("negative")
        assert broken == {"job-a": 3, "job-b": 1}, broken
        print(f"negative control: the same replay invariant rejected the duplicate count {broken}",
              flush=True)


if __name__ == "__main__":
    scenario(*sys.argv[1:])
