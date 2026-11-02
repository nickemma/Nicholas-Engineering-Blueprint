# Phase 3 exercise: ledger, a money-transfer service

Build this **on your own**, in a new repository, after the [checkpoint](TEACHING.md#checkpoint). It's a different system from Runway, and money makes every Phase 3 idea non-negotiable:
- a balance must never be lost to a race;
- a retried transfer must never move money twice;
- an event must leave exactly when the money moves;
- a read model must be rebuildable;
- a restore must be checked against what the outside world already knows.

There's no solution in this repository. This page shows exactly what the finished system does.

## What you're building

`ledger` keeps accounts and moves money between them, using **double-entry bookkeeping**. Every movement writes two **entries** that sum to zero: −2,500 on the account money leaves, +2,500 on the account it reaches. Money is never created or destroyed by a transfer, so the books can always be checked:

> the sum of all balances = the sum of all deposits.

There are two processes and three servers:

- **`ledger-api`** owns accounts, entries and transfers in PostgreSQL. It writes a `TransferCompleted` event to an outbox in the same transaction as every transfer, and a relay sends it to Kafka.
- **`ledger-statements`** reads the Kafka topic and keeps daily totals in its own tables, with an inbox, and serves them over HTTP.
- PostgreSQL, Kafka and Redis run in Docker Compose. Redis caches account reads.

## The finished result

### HTTP contract (ledger-api)

All amounts are integers in **cents**. Never use floating point for money.

| Request | Success | Errors |
|---|---|---|
| `POST /accounts` `{"owner":"alice","currency":"CAD"}` | `201`, `{"id":1,"owner":"alice","currency":"CAD","balance_cents":0}` | `400` empty owner, or a currency that isn't 3 capital letters |
| `GET /accounts/{id}` | `200`, the account with its balance | `404` |
| `POST /accounts/{id}/deposits` `{"amount_cents":10000}`, **`Idempotency-Key` required** | `201`, `{"id":1,"account_id":1,"amount_cents":10000,"balance_cents":10000}` | `400` missing key, amount ≤ 0 or > 100,000,000; `404`; `422` key reused with a different body |
| `POST /transfers` `{"from":1,"to":2,"amount_cents":2500}`, **`Idempotency-Key` required** | `201`, `{"id":1,"from":1,"to":2,"amount_cents":2500}` | `400` as above, or `from` = `to`; `404` either account; `409` currencies differ; `422` `{"error":"insufficient funds"}`, or key reused with a different body; `503` + `Retry-After` when the database breaker is open |
| `GET /accounts/{id}/entries?limit=N` | `200`, entries newest first, at most N (default 50, max 500) | `400` bad limit; `404` |
| `GET /health` | `200` while the process is up | |
| `GET /ready` | `200` when PostgreSQL answers within 1 s | `503` |
| `GET /metrics` | Prometheus metrics, including pool, cache, outbox and breaker metrics | |

An entry looks like `{"id":3,"account_id":1,"transfer_id":1,"amount_cents":-2500,"balance_after_cents":7500,"at":"..."}`. A deposit is an entry with `"transfer_id":null`.

### HTTP contract (ledger-statements)

| Request | Success |
|---|---|
| `GET /daily?day=2026-10-05` | `200`, `[{"currency":"CAD","transfers":2,"volume_cents":4000}]`: every currency with transfers that day, sorted by currency |

### Rules

- **Entries in order.** A transfer writes the debit (the `from` account's negative entry) first, then the credit, so entry IDs are predictable.
- **Atomicity.** A transfer's two entries, both balance changes, its idempotency record and its outbox row commit in **one transaction**, or none of them do.
- **Constraints in the database, not just the code.** `balance_cents >= 0`, amounts non-zero, currency format, foreign keys from entries to accounts, and a unique `(transfer_id, account_id)`.
- **No lost updates.** One hundred concurrent transfers between the same accounts leave the books balanced. Choose your fix (row locks, an atomic `UPDATE ... SET balance_cents = balance_cents - $1 WHERE balance_cents >= $1`, or `SERIALIZABLE` with retries), and justify the choice in your README.
- **No deadlocks.** Transfers 1→2 and 2→1 running at once must not deadlock. If you lock rows, lock them in ascending account ID order. If PostgreSQL ever reports a deadlock (SQLSTATE `40P01`) or a serialization failure (`40001`), retry the whole transaction, at most 3 times, with jitter.
- **Idempotency keys live in PostgreSQL and commit in the same transaction as the transfer.** That closes the gap Runway's step 5 left open: there's no moment when the money has moved but the key isn't recorded. A retried request replays the original response with `Idempotent-Replayed: true`. Keys expire after 24 hours.
- **Events.** Every transfer writes a `TransferCompleted` v1 envelope to the outbox:

  ~~~json
  {"id":"...","type":"ledger.transfer_completed","version":1,"occurred_at":"...","payload":{"transfer_id":1,"from":1,"to":2,"amount_cents":2500,"currency":"CAD"}}
  ~~~

  A relay using `FOR UPDATE SKIP LOCKED` sends it to the Kafka topic `ledger.transfers` (3 partitions), keyed by `from` account.
- **The projection** counts each event exactly once (an inbox, in the same transaction), and can be rebuilt by running `ledger-statements` under a new `STATEMENTS_GROUP`.
- **Caching.** `GET /accounts/{id}` is cache-aside in Redis, under the key `ledger:account:v1:{id}` with a 30-second TTL. Every write to an account deletes its key after the transaction commits. Loads are coalesced with singleflight. If Redis is down, reads still succeed from PostgreSQL, and a breaker stops trying Redis after 5 failures.
- **Background tasks**, each under an advisory lock so only one instance runs each round: delete expired idempotency keys every minute, and delete sent outbox rows older than an hour, in batches of 1,000.
- **Pooling.** `DB_MAX_CONNS` (default 10) sizes the pool; the API pings at start-up and exits with a clear message if it can't connect.
- **A database breaker** opens after 5 consecutive storage failures (not `404`s or `422`s) and fails fast with `503` for 10 seconds.

### Structure

~~~text
cmd/ledger-api/          composition root: config, pool, cache, relay, tasks, HTTP
cmd/ledger-statements/   Kafka consumer, projection, HTTP
internal/money/          domain: Amount, Currency, Account, Transfer, entries, validation
internal/ledger/         use cases: open account, deposit, transfer (behind ports)
internal/pgstore/        PostgreSQL adapter, migrations, and the unit of work
internal/outbox/         outbox table writer and relay
internal/stream/         Kafka producer and consumer
internal/statements/     projection and inbox
internal/cache/          cache-aside decorator
internal/background/     task runner
internal/httpapi/        handlers, idempotency middleware, error mapping
~~~

## Sample session

Start the servers, the API and the statements service against a fresh database (`docker compose down -v` first). Then:

~~~text
$ curl -s -X POST localhost:8080/accounts -H 'Content-Type: application/json' -d '{"owner":"alice","currency":"CAD"}'
{"id":1,"owner":"alice","currency":"CAD","balance_cents":0}

$ curl -s -X POST localhost:8080/accounts -H 'Content-Type: application/json' -d '{"owner":"bob","currency":"CAD"}'
{"id":2,"owner":"bob","currency":"CAD","balance_cents":0}

$ curl -s -X POST localhost:8080/accounts/1/deposits -H 'Content-Type: application/json' -H 'Idempotency-Key: dep-1' -d '{"amount_cents":10000}'
{"id":1,"account_id":1,"amount_cents":10000,"balance_cents":10000}

$ curl -s -X POST localhost:8080/transfers -H 'Content-Type: application/json' -H 'Idempotency-Key: t-1' -d '{"from":1,"to":2,"amount_cents":2500}'
{"id":1,"from":1,"to":2,"amount_cents":2500}

$ curl -s -i -X POST localhost:8080/transfers -H 'Content-Type: application/json' -H 'Idempotency-Key: t-1' -d '{"from":1,"to":2,"amount_cents":2500}' | grep -E '^HTTP|^Idempotent|^\{'
HTTP/1.1 201 Created
Idempotent-Replayed: true
{"id":1,"from":1,"to":2,"amount_cents":2500}

$ curl -s -X POST localhost:8080/transfers -H 'Content-Type: application/json' -H 'Idempotency-Key: t-2' -d '{"from":2,"to":1,"amount_cents":9000}'
{"error":"insufficient funds"}

$ curl -s localhost:8080/accounts/1
{"id":1,"owner":"alice","currency":"CAD","balance_cents":7500}

$ curl -s 'localhost:8080/accounts/1/entries?limit=2'
[{"id":2,"account_id":1,"transfer_id":1,"amount_cents":-2500,"balance_after_cents":7500,"at":"2026-10-05T..."},{"id":1,"account_id":1,"transfer_id":null,"amount_cents":10000,"balance_after_cents":10000,"at":"2026-10-05T..."}]

$ curl -s 'localhost:8081/daily?day=2026-10-05'
[{"currency":"CAD","transfers":1,"volume_cents":2500}]
~~~

Then check the books in `psql`:

~~~text
$ docker compose exec postgres psql -U ledger -Atc "SELECT (SELECT sum(balance_cents) FROM accounts) = (SELECT sum(amount_cents) FROM entries WHERE transfer_id IS NULL)"
t
~~~

Use today's date for `day`. The timestamps and envelope IDs will differ; the IDs, amounts, balances, statuses and counts must match. The refused transfer wrote nothing that anyone can see: no entries, no event, and no change to either balance. (It may still have used up an identity value inside its rolled-back transaction. That's allowed: IDs are increasing, not consecutive.)

## Acceptance checks

You're done when all of these are true:

1. Every row of both HTTP contracts has a test.
2. The repository and key-store ports each have a **contract test** that passes against an in-memory fake and against PostgreSQL (skipped without `LEDGER_DATABASE_URL`).
3. **The race test:** 100 goroutines make 1-cent transfers from account 1 to 2 while 100 make 1-cent transfers from 2 to 1, starting from 1,000 cents each. Afterwards both balances are exactly 1,000, the books balance, and no request failed with a deadlock that wasn't retried. Run it with `-count=10`.
4. **The anomaly test:** a learning test showing your chosen fix is needed. With the fix removed, the race test loses money (or fails with a constraint violation), and the test output shows it.
5. **The atomicity test:** a refused outbox write (`CHECK (false) NOT VALID`, as in the lesson) leaves balances, entries and keys exactly as they were.
6. **The crash test:** kill `ledger-api` with SIGKILL right after a transfer commits, with a long relay interval. After a restart, the event reaches Kafka and the daily total includes it, once.
7. **The replay test:** run `ledger-statements` under a new group; its totals equal the original group's.
8. **The cache test:** after `docker compose stop redis`, `GET /accounts/{id}` still answers `200`, and `cache_requests_total{result="skipped"}` rises once the breaker opens.
9. **The plan:** `EXPLAIN ANALYZE` of `GET /accounts/{id}/entries` with 1,000,000 entries in the table shows an index scan, and your README shows the plan before and after you added the index.
10. **The drill:** a written runbook, executed once:
    - restore a `pg_dump` into a new database;
    - check that the books balance there;
    - list the transfers Kafka knows about that the restore lost;
    - move the identity sequences past the highest IDs published.
11. `go vet`, `go test -race ./...` and CI are green, with PostgreSQL, Kafka and Redis as CI service containers.

## Stretch goals

- **A hash-chained audit log.** Each event also goes into `klog`, with every record containing the SHA-256 of the previous one. Add `klog verify` to recompute the chain and report the first record that doesn't match.
- **Holds.** `POST /transfers` with `"hold":true` reserves the money for 10 minutes until `POST /transfers/{id}/capture`; a background task releases expired holds, using `FOR UPDATE SKIP LOCKED` so several instances share the work.
- **Point-in-time recovery.** Turn on WAL archiving in the Compose PostgreSQL, take a base backup, make transfers, then recover to a moment between two of them.
- **Abandoned idempotency claims.** If a request crashed mid-transaction, nothing was committed, so the key is free. But if you split the work into stages (Stripe's "atomic phases"), record progress and let a later request resume from the last committed stage.

## Hints

- Model `Amount` and `Currency` as value objects with constructors that validate, just as `Description` did in Runway. Write their table tests first.
- Write the transfer as a single function that takes a transaction (a **unit of work**) and does every write through it. Then the "one transaction" rule is visible in one place.
- Before writing code, fill in the lesson's isolation table for `ledger`: which anomaly would lose money, and which fix prevents it?
- For the race test, check the books **in SQL**, not through the API, so the cache can't hide anything.
- Revisit step 4 for the relay, step 6 for the inbox, and step 11 for the drill. The shape of each is the same; only the domain changed.
