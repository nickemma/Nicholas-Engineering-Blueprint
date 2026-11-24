# Retention and aggregate privacy

Start with the data inventory and synthetic canary from [Core 08](../../../2-core/08-shipping-safely/lessons/04-limit-what-the-gateway-can-read-and-record.md). A deletion policy applies to every copy and every route by which a copy can return.

## Plan retention by copy

| Copy | Decision | Verification |
|---|---|---|
| Primary rows | Choose a purpose and expiry timestamp. Delete expired rows in bounded batches, and record counts per run. | Seed rows either side of the expiry boundary. Verify the expired rows disappear and the others still serve. Repeat the run and confirm it is safe to retry. |
| Cache and queue | Expire cached payloads and bound message and dead-letter retention. Check the replay policy against deleted records. | Seed a synthetic value, remove its primary row, then test cache reads, retry, and redelivery. |
| Logs, traces and exports | Limit what is collected and set expiry on each destination. | Search the sinks with the canary after expiry and check the policy on each sink. |
| Backups | State the backup lifetime and how deletion is re-applied after restore. | Restore in isolation and apply the deletion record before serving reads. Check the seeded expiry again. |

Exercise the policy with synthetic data. Pick a fixed time and run a purge twice, then restore a snapshot captured before the purge. Show that applying retention before read traffic prevents expired rows from becoming visible again. Record the oldest remaining expired item and where it persists. Review exemptions such as holds with the owner responsible for them.

## Check what an aggregate reveals

A minimum group size can block a direct small-group count. Two permitted overlapping counts can still reveal a single contribution. If the published count is 22 for a group and 21 for the same selection excluding one person, subtraction reveals that person's contribution. Repeated releases and overlapping dimensions matter as well as one query.

Compare coarse fixed releases, suppressing overlapping cuts, and differential privacy. For a private count, bound each person's contribution, account for repeated releases, and choose an explicit privacy budget using a reviewed mechanism. More privacy comes with less precision. Suppression alone does not supply a differential privacy guarantee.

## Check your decision

Write a retention matrix for one field from the tenant job contract. Give each row an owner, expiry rule, and observable test. Then propose two aggregate queries that pass a minimum group-size rule but expose information when compared. State which change you would ship and what accuracy or query flexibility it costs.

## Check the expiry boundary with a fixture

This in-memory fixture checks a strict read boundary after a restore. Choose a production deletion strategy separately and verify every sink in the inventory.

<!-- file: retention_check.py -->
~~~python
from dataclasses import dataclass


@dataclass(frozen=True)
class Record:
    key: str
    expires_at: int


def purge(records, now):
    return tuple(record for record in records if record.expires_at > now)


snapshot = (Record("expired", 9), Record("at-cutoff", 10), Record("active", 11))
after_restore = purge(snapshot, now=10)
assert after_restore == (Record("active", 11),)
assert purge(after_restore, now=10) == after_restore

subjects = {"synthetic-canary": 1, **{f"member{i}": 1 for i in range(21)}}
all_count = sum(subjects.values())
without_canary = sum(value for key, value in subjects.items() if key != "synthetic-canary")
assert all_count >= 20 and without_canary >= 20
assert all_count - without_canary == subjects["synthetic-canary"]
~~~

<!-- run: python3 retention_check.py -->

## Recover from a backup taken before expiry

This exercise uses a disposable SQLite database and a copy of its snapshot. Run deletion in one-row transactions so a stopped run can resume. Verify expiry again on the restored copy before serving it. Apply the same boundary test to your real database, cache, and queues with test data.

<!-- file: restore_retention.py -->
~~~python
import sqlite3
from contextlib import closing
from pathlib import Path
from tempfile import TemporaryDirectory


def purge(db, cutoff):
    removed = 0
    while True:
        with db:
            batch = db.execute(
                """DELETE FROM jobs WHERE id IN (
                       SELECT id FROM jobs WHERE expires_at <= ?
                       ORDER BY expires_at, id LIMIT 1
                   )""",
                (cutoff,),
            ).rowcount
        if batch == 0:
            return removed
        removed += batch


def verify(db):
    assert purge(db, 10) == 2
    assert purge(db, 10) == 0
    assert db.execute("SELECT id FROM jobs").fetchall() == [("active",)]


with TemporaryDirectory() as directory:
    root = Path(directory)
    with (
        closing(sqlite3.connect(root / "live.db")) as live,
        closing(sqlite3.connect(root / "before-expiry.db")) as snapshot,
        closing(sqlite3.connect(root / "restored.db")) as restored,
    ):
        with live:
            live.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, expires_at INTEGER NOT NULL)")
            live.executemany("INSERT INTO jobs VALUES (?, ?)",
                             [("expired", 9), ("at-cutoff", 10), ("active", 11)])
        live.backup(snapshot)
        verify(live)
        snapshot.backup(restored)
        verify(restored)
print("expiry and retry passed on live and restored disposable databases")
~~~

<!-- run: python3 restore_retention.py -->
