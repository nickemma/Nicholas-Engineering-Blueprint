# Phase 3: Make local records durable and auditable

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: full code in `steps/`, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This is a self-study lesson. Follow it in order. Each section explains the idea, tells you exactly what to build, gives you a check, and says what that check proves. Work in a disposable practice copy with synthetic data. Keep this lesson open while learning, then close it for the Kestrel transfer at the end.

## The goal

By the end you will have:

1. A Go jobs service whose state lives in PostgreSQL rather than only in process memory.
2. A SQL transaction that saves a job change and its outbox event together.
3. Evidence that an index helps or does not help one measured query.
4. A small Rust append-only log with versioned, checksummed records and restart recovery.
5. A backup restored into a second local database.

PostgreSQL is the source of truth for the service. The Rust log is a storage experiment that teaches bytes and crash behavior; it does not replace Postgres. Nothing here proves multi-machine consistency. Phase 4 studies replication.

## Before you start

Finish Phase 2 and the [Rust Bridge](../rust-bridge/TEACHING.md). You need to understand a Go handler, a job ID, JSON, a separate worker, Rust Result/ownership, byte slices, and a test. This guide introduces the database and file-system ideas from the beginning.

Check the tools:

~~~bash
go version
rustc --version
cargo --version
docker --version
docker compose version
~~~

Each command asks one installed tool to print its version. Stop if a command is missing. The practice database contains only disposable synthetic records; never point the commands at a real database.

Create a separate practice area:

~~~bash
cd lessons/03-durable-auditable-data
mkdir -p practice
cd practice
~~~

The first command changes the current directory. mkdir -p makes the folder if it does not exist. The final command enters it. A relative filename you create from now on belongs here.

## 1. Start a disposable PostgreSQL database

PostgreSQL is a database server: a separate process that stores structured data and answers queries. A database table is like a typed collection of rows. A row is one record; a column is one named value in each record.

Create a file named compose.yaml with this content:

~~~yaml
name: kestrel-phase3
services:
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: kestrel
      POSTGRES_PASSWORD: lesson-only
      POSTGRES_DB: kestrel
    ports:
      - "127.0.0.1:55432:5432"
    volumes:
      - phase3-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U kestrel -d kestrel"]
      interval: 2s
      timeout: 2s
      retries: 20

volumes:
  phase3-data:
~~~

Compose describes one database container. The host-side port is 55432 so it does not conflict with another local PostgreSQL server; the service's internal port remains 5432. Binding to 127.0.0.1 makes it reachable from this computer only. The named volume keeps practice data when the container is replaced. The password is intentionally public and suitable only for this local throwaway lab.

Start and inspect it:

~~~bash
docker compose up -d --wait
docker compose ps
docker compose logs --tail=20 db
~~~

up creates and starts the service; -d returns you to the shell; --wait waits for the health check. ps shows whether it became healthy. logs shows the database startup messages. If it is not healthy, read the first database error in the log before changing anything.

Open the SQL prompt:

~~~bash
docker compose exec db psql -U kestrel -d kestrel
~~~

exec runs psql inside the database container. At the prompt type:

~~~sql
SELECT current_database(), now();
\q
~~~

Expect the database name kestrel and the current time, then return to the shell. SELECT asks the database to return values. The backslash-q command exits psql. This verifies a connection; it does not create an application table.

Set the local connection string in the terminal where you will run Go:

~~~bash
export DATABASE_URL='postgres://kestrel:lesson-only@127.0.0.1:55432/kestrel?sslmode=disable'
printf '%s\n' "$DATABASE_URL"
~~~

export makes the variable available to child processes started from this shell. printf prints it so you can confirm the value. This connection string is only for the local synthetic database. Do not commit it into source control.

## 2. Create and understand the schema

A schema is the declared shape and rules for stored data. A primary key uniquely identifies a row. A foreign key requires a reference to an existing row. A CHECK constraint rejects values outside a rule.

Install goose, a tool that applies ordered schema changes and records which ones ran:

~~~bash
go install github.com/pressly/goose/v3/cmd/goose@latest
export PATH="$(go env GOPATH)/bin:$PATH"
goose -version
~~~

go install builds the command. The PATH line adds Go's installed-command directory to this shell. If the final command is not found, check the path printed by go env GOPATH and add its bin folder to PATH.

Create a migrations folder and a SQL migration:

~~~bash
mkdir migrations
goose -dir migrations create create_jobs sql
ls migrations
~~~

goose creates a timestamped SQL file. Open it in your editor. Keep its generated filename and replace its contents with:

~~~sql
-- +goose Up
CREATE TABLE jobs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    state TEXT NOT NULL CHECK (state IN ('queued', 'running', 'completed', 'failed')),
    payload JSONB NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE outbox (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_id BIGINT NOT NULL REFERENCES jobs(id),
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at TIMESTAMPTZ
);

-- +goose Down
DROP TABLE outbox;
DROP TABLE jobs;
~~~

Apply and inspect the migration:

~~~bash
goose -dir migrations postgres "$DATABASE_URL" up
goose -dir migrations postgres "$DATABASE_URL" status
docker compose exec db psql -U kestrel -d kestrel -c '\dt'
~~~

up applies the migration. status reports the version. psql's \dt lists tables. You should see jobs, outbox, and goose_db_version. The last table records which schema changes have already run.

Read the schema one rule at a time. The generated id is unique. A state must be one of four values. The JSON payload must be an object. Every outbox row must point to a real job. published_at is empty until a later delivery step marks the event as published. The migration's Down section describes how to undo it; running Down drops your practice tables, so do not run it after entering data unless you intend to reset this disposable lab.

Run a rejected write:

~~~bash
docker compose exec db psql -U kestrel -d kestrel -c "INSERT INTO jobs (state, payload) VALUES ('mystery', '{}'::jsonb);"
~~~

Postgres should reject the row because the CHECK rule does not allow state mystery. A database constraint protects the data even if another code path forgets to validate it.

## 3. Connect Go to PostgreSQL

Create a Go module in practice, then add pgx, the PostgreSQL driver and Go toolkit:

~~~bash
go mod init kestrel-phase3
go get github.com/jackc/pgx/v5
~~~

Use pgx's pool so the service can safely reuse a bounded number of connections. Add a small database package and implement this startup sequence:

1. Read DATABASE_URL from the environment.
2. If it is empty, print a clear error and exit.
3. Create a pgx connection pool with pgxpool.New.
4. Call Ping with a context that expires after three seconds.
5. Close the pool when the program exits.

The pool is a manager for reusable database connections, not the database itself. Creating a pool object does not by itself prove the database is reachable; Ping does. A context deadline prevents startup from waiting forever.

The core Go calls look like this:

~~~go
ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
defer cancel()

pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
if err != nil {
    return fmt.Errorf("create database pool: %w", err)
}
defer pool.Close()

if err := pool.Ping(ctx); err != nil {
    return fmt.Errorf("connect to database: %w", err)
}
~~~

Each import names a package used by the program. context carries a deadline; defer schedules cleanup when the current function returns; fmt.Errorf adds operation context to an error; %w keeps the original error available to callers.

Build and run a temporary connection check. It should exit successfully when Compose is healthy. Stop the database with docker compose stop db and run the check again. It should exit with the connection error you added, not panic or hang. Start the database again with docker compose start db.

## 4. Make one job transition atomic

A transaction groups database statements into one all-or-nothing change. Before commit, a transaction's writes can still be rolled back. Commit asks Postgres to make them visible as one completed transaction. If the process disconnects before commit, Postgres rolls back the still-open transaction.

Define these application values:

~~~text
Job: id, state, payload, created_at, updated_at
Outbox event: id, job_id, event_type, payload, created_at, published_at
~~~

Implement CreateJob in Go:

1. Begin a transaction with the request context.
2. Insert one jobs row with state queued and the caller's JSON payload as a parameter.
3. Read the generated ID using RETURNING id.
4. Build an event value containing that job ID and the event type job.queued.
5. Insert that event into outbox using the same transaction.
6. Commit only if both inserts succeed. On any error, roll back and return an error.

Postgres positional parameters look like $1, $2, and so on. Pass input as arguments to the query API. Never build SQL by concatenating user text. The insert shape is:

~~~sql
INSERT INTO jobs (state, payload)
VALUES ('queued', $1::jsonb)
RETURNING id, state, created_at, updated_at;
~~~

For a state transition, use one conditional UPDATE:

~~~sql
UPDATE jobs
SET state = 'completed', updated_at = now()
WHERE id = $1 AND state IN ('queued', 'running')
RETURNING id, state, updated_at;
~~~

If UPDATE returns no row, report that no permitted transition occurred. Do not claim success. Insert the matching event and commit the transaction only after both writes succeed.

This is the transactional outbox idea: the business-state change and the intent to publish its event are committed together. If the database transaction rolls back, neither is present. A later relay may publish an outbox row more than once, so consumers still need idempotency.

### Prove rollback with psql

Run one transaction that inserts a synthetic job, then roll it back:

~~~sql
BEGIN;
INSERT INTO jobs (state, payload) VALUES ('queued', '{"demo":true}'::jsonb);
ROLLBACK;
SELECT count(*) FROM jobs;
~~~

The final count should be zero. BEGIN opened a transaction; ROLLBACK discarded its uncommitted work. Now repeat with COMMIT instead of ROLLBACK; the count should increase to one. Save the two results.

### Make SQL injection a concrete test

An SQL injection happens when untrusted text is treated as part of the SQL program rather than as a data value. Parameterized queries keep the SQL structure separate from each value.

Submit this string as a JSON payload value:

~~~json
{"note":"'; DROP TABLE jobs; --"}
~~~

The job should be created with that text as data. Then list the jobs table. It must still exist. The test demonstrates why the application passes payload as a parameter. Do not try to “sanitize” input by deleting quote characters; a parameterized query is the control.

## 5. Wire the durable store into the HTTP service

Reuse your Phase 2 API contract. Replace the in-memory map with the PostgreSQL repository. Keep the HTTP handler responsible for HTTP status/JSON. Keep the repository responsible for SQL and transaction errors.

Implement these observable routes:

| Request | Result |
|---|---|
| POST /jobs with a valid object | 201, generated ID, state queued |
| GET /jobs/{id} for a stored ID | 200, data read from Postgres |
| GET /jobs/{id} for an absent ID | 404 |
| POST /jobs/{id}/complete | 200 and a persisted state change |
| malformed JSON or invalid state transition | documented 400 or 409 |

Use the request context for database operations. Set a server timeout and request-size bound as in Phase 1. Do not send SQL or connection-string details to the caller; log the internal error without logging the submitted record.

Start the service and use curl to create a job. Stop the Go process, start it again, and fetch the same ID. It should still exist because Postgres is a separate process with its own persistent data directory. This proves persistence across an application-process restart on this machine. It does not prove data survives storage-device destruction or a multi-node failure.

Check the saved event:

~~~bash
docker compose exec db psql -U kestrel -d kestrel -c 'SELECT id, job_id, event_type, published_at FROM outbox ORDER BY id;'
~~~

Expect an outbox row for the created job and an empty published_at. Complete the job and confirm that the state and a second outbox event both exist.

## 6. Measure before adding an index

An index is an extra data structure that can help the database find selected rows faster. It also takes disk space and makes writes more expensive. Add one only when a real query and measurements justify it.

Load synthetic rows:

~~~sql
INSERT INTO jobs (state, payload)
SELECT CASE WHEN n % 20 = 0 THEN 'failed' ELSE 'completed' END,
       jsonb_build_object('sample', n)
FROM generate_series(1, 20000) AS n;
~~~

generate_series creates test integers. This query inserts fake records with a predictable fraction of failed jobs. It contains no health information.

Measure this query:

~~~sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, updated_at
FROM jobs
WHERE state = 'failed'
ORDER BY updated_at DESC
LIMIT 20;
~~~

EXPLAIN shows the chosen plan. ANALYZE executes the query and reports observed timing and rows. BUFFERS reports database page activity. The optimizer may choose a sequential scan or an index scan; the right choice depends on table size, selectivity, cache state, and data. Do not memorize a specific plan.

Write down the plan type, rows examined, buffers, and execution time. Add a candidate partial index for failed rows ordered by updated_at, run ANALYZE on the table, and repeat the same query. Compare the same measurement fields. Keep the index only if the evidence supports it and explain the write/storage cost. A timing from one run is noisy; repeat it and avoid claiming a universal speedup.

## 7. See what “written” means

A Go value first exists in process memory. A database write travels over a connection to PostgreSQL. PostgreSQL records changes in its write-ahead log (WAL) before it later writes changed table pages. A successful SQL COMMIT means PostgreSQL accepted the transaction under its configured durability behavior. It is not the same as merely changing a Go map.

For a file, Rust's write_all sends bytes through the operating system. The kernel may keep them in the page cache, which is memory used to cache file contents. A successful write call does not automatically mean bytes have reached stable storage. sync_data asks the operating system to synchronize file data and required metadata. The exact power-loss guarantee depends on filesystem, operating system, device, and configuration.

On Linux, use strace only to observe your own local practice process:

~~~bash
strace -e trace=openat,write,fdatasync,fsync -o trace.txt cargo run -- append sample.log hello
rg 'write|fdatasync|fsync' trace.txt
~~~

strace records selected system calls made by the process. -e selects calls and -o writes the trace to a file. rg filters those lines. Compare a run without synchronization and one with sync_data. The trace can show that a synchronization call was requested; it cannot prove the hardware honored it through every possible power failure.

Read OSTEP's crash-consistency chapter now. Use it to explain the difference among a program buffer, page cache, filesystem ordering, a database WAL, and stable storage. Do not use “fsync means indestructible” as a conclusion.

## 8. Build and recover the Rust append-only log

An append-only log writes new records at the end instead of overwriting older records in place. The toy log is independent of Postgres and is used to make recovery rules visible.

Create a Rust package in practice:

~~~bash
cargo new rust-log
cd rust-log
cargo add crc32c
cargo add proptest --dev
~~~

Cargo creates a package, and cargo add records the checksum dependency. Use the record format from the Rust Bridge:

~~~text
magic KSTR (4 bytes)
format version (1 byte)
sequence (8-byte unsigned big-endian)
payload length (4-byte unsigned big-endian)
payload (at most 1 MiB)
CRC32C (4 bytes over version through payload)
~~~

Implement, in this order:

1. A Record type with sequence and payload.
2. encode(record) that creates each field in the order above.
3. decode(bytes) that validates magic, supported version, length limit, exact boundary, and checksum before returning a record.
4. append(path, record) that opens in append mode, writes the entire encoded frame, and calls sync_data before reporting success.
5. recover(path) that reads frames from the beginning, checks increasing sequence numbers, and returns the complete valid prefix.

Use a maximum length before allocating the payload. An incomplete final header or payload is a torn tail. Report its byte offset and preserve the original file before repairing or truncating it. A complete record with a wrong checksum is corruption: fail closed and do not silently skip it.

Add tests for a valid record, two records in order, one-byte truncation at every field boundary, wrong magic, unsupported version, excessive length, changed payload, duplicate sequence, and a complete record after a corrupt one. The reader must never accept malformed data as a valid record. Derive `Debug`, `PartialEq`, and `Eq` for Record so tests can compare records.

Add these two generated-input properties in a Rust test module. `proptest` runs 1,000 cases; it saves a failing seed so the failure can be reproduced:

~~~rust
use proptest::prelude::*;

proptest! {
    #![proptest_config(ProptestConfig::with_cases(1000))]

    #[test]
    fn bounded_arbitrary_bytes_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..4096)) {
        let decoded = decode(&bytes);
        if let Ok(record) = decoded {
            prop_assert_eq!(encode(&record).expect("accepted record encodes"), bytes);
        }
    }

    #[test]
    fn generated_records_round_trip(sequence in any::<u64>(), payload in proptest::collection::vec(any::<u8>(), 0..4096)) {
        let record = Record { sequence, payload };
        let bytes = encode(&record).expect("bounded generated record encodes");
        prop_assert_eq!(decode(&bytes).expect("encoded record decodes"), record);
    }
}
~~~

Run `cargo test`. The first property checks that arbitrary short inputs never panic and that any accepted encoding is canonical. The second checks valid data across many sequences and payloads. Keep the fixed table tests too: generated tests complement them rather than replacing known boundary cases.

### Controlled crash exercise

First append one complete record and confirm it is recoverable after closing and reopening the process. Then use a test-only function that writes half of a frame and exits before sync_data. Restart the reader. It should identify the incomplete tail and recover only prior complete frames.

On your isolated practice process only, you may also start the append command in the background, record its process ID, and send SIGKILL to that exact PID during a test pause. A process ID identifies one running process. Do not send SIGKILL to an unfamiliar PID or a system service. If you are not certain which process you started, use the deterministic partial-frame test instead. A killed user process demonstrates interruption during a file update; it does not simulate a disk power failure.

Compare this with killing the Go API while a Postgres transaction is open: when the connection closes before COMMIT, PostgreSQL should roll the transaction back. Record the database rows before and after. This is application-process crash evidence; do not call it a full database-machine crash test.

### Compaction

The log grows forever unless old versions can be summarized. Compaction writes a new file containing the latest state for each job, validates it, synchronizes it, and then atomically renames it over the old snapshot according to a documented recovery protocol.

Implement compaction only after append and recovery tests pass:

1. Replay the valid log into a map of latest state keyed by job ID.
2. Write those current values, in a deterministic order, to a new temporary file.
3. Sync the new file.
4. Re-open and validate the new file using the normal recovery code.
5. Rename it into place without deleting the only good copy first.
6. On Linux, synchronize the parent directory after the rename when claiming rename durability.
7. Add crash tests before and after each boundary. On restart, recover either the old valid file or the new valid file, never a silently mixed file.

The exact rename/directory durability behavior is OS/filesystem-dependent. Document the Linux environment used by your test. Read DDIA Chapter 3 and the Bigtable paper before implementing a more elaborate LSM tree; the goal here is to see sorted immutable files and compaction, not to build a production engine.

CRC32C detects accidental damage, not deliberate tampering. For an audit trail, keep database roles from updating historical event content, log policy and access decisions, and state the residual risk. A public checksum alone is not an audit security control.

## 9. Back up and restore into a different database

A backup is only useful if a restore works. Create a compressed logical backup from the local service and restore it into a new database:

~~~bash
docker compose exec -T db pg_dump -U kestrel -d kestrel -Fc > phase3.dump
docker compose exec db createdb -U kestrel kestrel_restore
docker compose exec -T db pg_restore -U kestrel -d kestrel_restore --no-owner < phase3.dump
docker compose exec db psql -U kestrel -d kestrel_restore -c 'SELECT count(*) FROM jobs;'
~~~

The first command streams a custom-format backup into phase3.dump. -T disables a pseudo-terminal so redirection is clean. createdb makes a separate restore target. pg_restore loads the backup there. Compare job counts and selected IDs with the original database. Do not restore over the source database during this exercise.

Record the backup file size, restore time, row-count comparison, and any objects not included. A successful command without a comparison is not a verified restore.

## 10. Security and cleanup

Keep credentials out of source code and logs. Restrict the database listener to loopback. Use parameterized statements. Use a database account with only the privileges needed by the application in a production design; the local compose account is deliberately convenient and must not be reused.

After you have saved evidence, stop the local service:

~~~bash
docker compose down
~~~

This stops and removes the container but keeps the named volume. To delete only this lesson's synthetic data as well, use docker compose down -v from this practice folder. The -v option removes the Compose volume; do not use it if the data matters.

## Phase completion gate

You are ready to move on when you can reproduce all of these from a clean practice directory:

- Apply a migration and explain the key, constraint, JSONB field, and foreign key.
- Create and complete a job through the Go API; restart the API and fetch it successfully.
- Show a job state change and outbox event are in one transaction.
- Test SQL-looking input as data and show the table remains.
- Compare an EXPLAIN plan before and after the candidate index and justify the final choice.
- Decode complete Rust records, reject a corrupt complete record, identify a torn tail, and recover the prior valid records.
- Explain what write, sync_data, PostgreSQL WAL/COMMIT, and backup restore each prove.
- Restore to a second database and compare the data.

Then complete [learned.md](learned.md). Close this lesson and all reference implementation code before the Kestrel rebuild. Use your own contract notes and official language/database references, not lesson code. Rebuild the persistence behavior inside your Kestrel checkout, attach test and restore evidence, and only then compare behavior with the lesson checklist.

## Read beside the build

Read each item after the matching experiment, then write one answer to the question in your notes.

| When | Read | Carry this question into the reading |
|---|---|---|
| While implementing the SQL transaction | DDIA, Chapter 7; *Understanding Distributed Systems*, Part II section on transactions | Which changes must commit or roll back together? |
| Before testing hostile SQL-looking input | *The Web Application Hacker's Handbook*, Chapter 9's SQL injection sections | How does a bound parameter keep input separate from query structure? |
| After the first schema and query work | *Readings in Database Systems*, 5th ed., “Traditional RDBMS Systems” and “Techniques Everyone Should Know” | Which workload does an index improve, and what write cost does it add? |
| Before the Rust file experiment | OSTEP, Chapters 36–37 and 39–40; CSAPP, Chapter 10 and Chapter 6 §§6.1–6.3 | Which layer owns a byte before it reaches persistent media? |
| Before crash and torn-tail tests | OSTEP, Chapters 42–44 and Appendix I on flash SSDs | What does a process crash preserve, and what state might still be incomplete? |
| Before compaction | DDIA, Chapter 3; Chang et al., “Bigtable” (2006), focusing on SSTables, memtables, and compaction | Why can old versions be retained and later merged? |
| During backup and restore | *Site Reliability Engineering*, Chapter 26 | How do you prove the restored bytes and rows mean what you expect? |
| Optional data model review | DDIA, Chapter 2 | Which relationships and queries are easiest to represent in this schema? |

Official tool references: [PostgreSQL documentation](https://www.postgresql.org/docs/current/), [pgx](https://github.com/jackc/pgx), [goose](https://github.com/pressly/goose), [Rust Book](https://doc.rust-lang.org/book/), and [CRC32C crate](https://crates.io/crates/crc32c).
