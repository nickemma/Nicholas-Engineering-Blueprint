# 08 Recover a transaction across two shards

> Consensus in depth · Week 4 · Builds on lesson 07

## The problem

A transfer debits an account on one shard and credits another. If the process stops between decisions, a retry needs enough durable information to finish the right outcome.

## The mental model

Prepare on each PostgreSQL participant, write the coordinator’s decision, then send that decision to both participants. Crash at two points: after both prepare and after only the first participant has received the durable commit decision.

## The pattern

In two-phase commit, a prepared PostgreSQL transaction keeps its locks and waits for a decision. In this single-coordinator lab, recovery durably records abort if the decision is absent. A saga commits each action locally and can issue a compensating action if a later action fails.

## Build it

### Step 1 — Start two isolated shards and prepare

Start two disposable PostgreSQL 17 containers. Use separate databases on the two servers, set a nonzero prepared-transaction limit, and inspect prepared state through each server’s own `psql`.

<details>
<summary>Hint 1</summary>

Prepared transaction identifiers need to stay stable across coordinator restarts.

</details>

<details>
<summary>Hint 2</summary>

Execute COMMIT PREPARED and ROLLBACK PREPARED outside a transaction block.

</details>

<details>
<summary>Implementation</summary>



</details>

### Step 2 — Recover after a coordinator crash

Keep a unique row per transfer ID for the outcome. Pause the coordinator at each boundary and kill only the child process the harness started.

<details>
<summary>Hint 1</summary>

Record a commit decision before sending the first participant commit.

</details>

<details>
<summary>Hint 2</summary>

Check balances and prepared rows after both recovery paths. Inspect the lock timeout while the first transfer remains prepared.

</details>

<details>
<summary>Implementation</summary>



</details>

### Step 3 — Compensate and retry

Run a separate saga. Commit the debit, force the destination action to fail, then issue the compensation twice using the same action ID.

<details>
<summary>Hint 1</summary>

Put the action ID and balance update in the same transaction.

</details>

<details>
<summary>Hint 2</summary>

Read both accounts before compensation to observe the intermediate state.

</details>

<details>
<summary>Implementation</summary>

Create `lab/transfer.py`.

<!-- file: lab/transfer.py -->
~~~python
"""Two disposable PostgreSQL shards and an interruptible coordinator."""

from contextlib import ExitStack
import selectors
import subprocess
import sys
import time
import uuid


def docker(*args, timeout=20):
    return subprocess.run(
        ["docker", *args], capture_output=True, text=True, timeout=timeout,
    )


def sql(node, statement, expect_failure=False):
    result = docker("exec", node, "psql", "-XAtq", "-v", "ON_ERROR_STOP=1",
                    "-v", "VERBOSITY=verbose", "-U", "postgres", "-d", "postgres", "-c", statement)
    if expect_failure:
        assert result.returncode != 0, result
        return result.stderr
    result.check_returncode()
    return result.stdout.strip()


def start(stack, name, balance):
    docker("run", "-d", "--network", "none", "--name", name, "-e", "POSTGRES_HOST_AUTH_METHOD=trust",
           "postgres:17", "-c", "max_prepared_transactions=8").check_returncode()
    stack.callback(docker, "rm", "-fv", name)
    for _ in range(100):
        ready = docker("exec", name, "pg_isready", "-h", "127.0.0.1", "-U", "postgres")
        if ready.returncode == 0:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("PostgreSQL did not become ready")
    sql(name, f"""
        CREATE TABLE account (id integer PRIMARY KEY, balance integer NOT NULL CHECK (balance >= 0));
        INSERT INTO account VALUES (1, {balance});
        CREATE TABLE actions (id text PRIMARY KEY);
        CREATE TABLE decisions (gid text PRIMARY KEY, outcome text NOT NULL CHECK (outcome IN ('commit', 'abort')));
    """)


def prepare(node, gid, amount):
    sql(node, f"BEGIN; UPDATE account SET balance = balance + ({amount}) WHERE id=1;"
              f" PREPARE TRANSACTION '{gid}';")


def decide(node, gid, outcome):
    sql(node, f"INSERT INTO decisions VALUES ('{gid}', '{outcome}') ON CONFLICT DO NOTHING;")
    return sql(node, f"SELECT outcome FROM decisions WHERE gid = '{gid}';")


def participants(source, target, gid):
    return ((source, f"{gid}_a"), (target, f"{gid}_b"))


def resolve(node, xid, outcome):
    present = sql(node, f"SELECT gid FROM pg_prepared_xacts WHERE gid = '{xid}';")
    if present:
        action = {"commit": "COMMIT", "abort": "ROLLBACK"}[outcome]
        sql(node, f"{action} PREPARED '{xid}';")


def coordinator(source, target, gid, boundary):
    prepare(source, f"{gid}_a", -20)
    prepare(target, f"{gid}_b", 20)
    if boundary == "after_first_commit":
        assert decide(source, gid, "commit") == "commit"
        resolve(source, f"{gid}_a", "commit")
    print("coordinator paused at " + boundary, flush=True)
    sys.stdin.read()  # Parent kills this process when the boundary is observed.


def interrupt(source, target, gid, boundary):
    with subprocess.Popen(
        [sys.executable, __file__, "coordinator", source, target, gid, boundary],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    ) as child:
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ)
                assert selector.select(20), "coordinator failed to reach the crash barrier"
                assert child.stdout.readline().strip() == "coordinator paused at " + boundary
        finally:
            child.kill()
            _, errors = child.communicate(timeout=10)
            if errors:
                print(errors, file=sys.stderr, end="")


def recover(source, target, gid):
    # Missing decision implies abort for this single coordinator.
    outcome = decide(source, gid, "abort")
    for node, xid in participants(source, target, gid):
        resolve(node, xid, outcome)
    return outcome


def balance(node):
    return int(sql(node, "SELECT balance FROM account WHERE id=1;"))


def assert_resolved(source, target):
    for node in (source, target):
        assert sql(node, "SELECT count(*) FROM pg_prepared_xacts;") == "0"


def prepared_transfer(source, target):
    interrupt(source, target, "before", "before_decision")
    assert (balance(source), balance(target)) == (100, 50)
    assert all(sql(node, "SELECT count(*) FROM pg_prepared_xacts;") == "1"
               for node in (source, target))
    error = sql(source, "SET lock_timeout='100ms'; UPDATE account SET balance=balance WHERE id=1;",
                expect_failure=True)
    assert "55P03" in error, error
    assert recover(source, target, "before") == "abort"
    assert recover(source, target, "before") == "abort"
    assert (balance(source), balance(target)) == (100, 50)
    assert_resolved(source, target)
    print("before decision: SQLSTATE 55P03 while prepared; recovery aborted (100, 50)")
    interrupt(source, target, "after", "after_first_commit")
    assert (balance(source), balance(target)) == (80, 50)
    assert sql(target, "SELECT count(*) FROM pg_prepared_xacts;") == "1"
    assert recover(source, target, "after") == "commit"
    assert recover(source, target, "after") == "commit"
    assert (balance(source), balance(target)) == (80, 70)
    assert_resolved(source, target)
    print("after decision: observed (80, 50); recovery committed (80, 70), no prepared transactions remain")


def effect(node, action, amount):
    sql(node, f"""
        WITH applied AS (
            INSERT INTO actions VALUES ('{action}') ON CONFLICT DO NOTHING RETURNING 1
        )
        UPDATE account SET balance = balance + ({amount}) WHERE id=1 AND EXISTS (SELECT FROM applied);
    """)


def saga(source, target):
    effect(source, "debit", -10)
    assert (balance(source), balance(target)) == (70, 70)
    assert "23514" in sql(target, "UPDATE account SET balance=-1 WHERE id=1;", expect_failure=True)
    effect(source, "compensate", 10)
    effect(source, "compensate", 10)
    assert (balance(source), balance(target)) == (80, 70)
    assert sql(source, "SELECT string_agg(id, ',' ORDER BY id) FROM actions;") == "compensate,debit"
    print("saga: observed (70, 70); destination failed; repeated compensation restored (80, 70)")


def lab():
    prefix = "sy-consensus-" + uuid.uuid4().hex[:12]
    source, target = prefix + "-a", prefix + "-b"
    with ExitStack() as stack:
        start(stack, source, 100)
        start(stack, target, 50)
        print("PostgreSQL " + sql(source, "SHOW server_version;"), flush=True)
        prepared_transfer(source, target)
        saga(source, target)


if __name__ == "__main__":
    if len(sys.argv) == 1:
        lab()
    else:
        assert sys.argv[1] == "coordinator"
        coordinator(*sys.argv[2:])
~~~

</details>

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/02-consensus-in-depth/gate/run.sh" "$PWD" transfer
~~~

Before the decision, a concurrent update saw SQLSTATE 55P03 and recovery left (100, 50). After the decision and one commit, the two shards showed (80, 50). Recovery finished at (80, 70). The saga exposed its intermediate debit and repeated compensation restored (80, 70). [Gate transcript](../evidence/gate.txt)

## If it goes wrong

If a prepared transaction survives the lab, check its GID against the decision row and check both participants. If a duplicate refund changes the balance twice, check that only a newly inserted action ID can trigger the update.
