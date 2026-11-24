# 02 A schema you can change

> About 5 hours · Builds on [01 What disappears on restart](01-what-disappears-on-restart.md).

## The problem

A new database is empty. An existing one already holds jobs you have promised to keep. Switchyard needs a repeatable way to bring both databases to the schema its new code expects.

## The mental model

~~~text
empty database    -- migration 001 --> jobs table -- migration 002 --> jobs + index
existing database                                  -- migration 002 --> jobs + index
~~~

A **schema** describes the database's tables, columns, and constraints. A **migration** is an ordered change to that schema. Each applied migration gets a row in a history table, committed with the schema changes it records. The same file can then be run on a fresh database or rerun after a successful deploy.

## The pattern

Keep the rules visible at each boundary. Go checks the whole job state machine, including which transitions are legal. PostgreSQL constraints check properties of the stored row, such as a known state and a duration within the supported range. A parameterized query sends its structure and values separately, so a quote in a description is handled as a character in that value.

## Build it

Use a fresh disposable database for this lesson. If you exited the lesson 01 shell, run its network and helper setup again. If the lab database container is still running, remove it with `docker rm -f -v "$db"`. Then run `start_db -e PGDATA=/var/lib/postgresql/ephemeral`. Later you'll run migrations against the volume-backed database.

### Step 1. Write down the shape of a job

From the root of the Switchyard checkout, create `db/migrations/001_jobs.sql`. Use nanoseconds for the duration so the repository can round-trip Go's `time.Duration`, and use `timestamptz` for instants. PostgreSQL timestamps have microsecond precision. The Go adapter will account for that at its storage boundary.

<!-- file: db/migrations/001_jobs.sql -->
~~~sql
CREATE TABLE jobs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    description text NOT NULL CHECK (char_length(description) BETWEEN 1 AND 200),
    duration_ns bigint NOT NULL CHECK (duration_ns BETWEEN 0 AND 5000000000),
    state text NOT NULL CHECK (state IN ('queued', 'running', 'completed', 'failed', 'cancelled')),
    failure_reason text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL
);
~~~

The database assigns the identity column when you insert a row. The primary key also gives PostgreSQL an index for `GET /jobs/{id}`. The timestamp stores an instant and its display follows the session time zone.

### Step 2. Apply the first migration

Use a small driver for `psql`. The numbered file contains only the schema change. The driver owns the transaction and the history table. An advisory transaction lock makes two invocations of this driver wait their turn. Everyone running this migration must use the same lock.

<!-- file: db/migrate.sql -->
~~~sql
BEGIN;
SET LOCAL lock_timeout = '5s';
SELECT pg_advisory_xact_lock(30301);

CREATE TABLE IF NOT EXISTS schema_migrations (
    version integer PRIMARY KEY
);

SELECT NOT EXISTS (
    SELECT 1 FROM schema_migrations WHERE version = 1
) AS apply_001 \gset
\if :apply_001
    \ir migrations/001_jobs.sql
    INSERT INTO schema_migrations (version) VALUES (1);
\endif
COMMIT;
~~~

The database is still on the lab network. This client mounts the source files read-only so `psql` can follow the relative `\ir` include. `ON_ERROR_STOP` makes it exit on the first SQL error. Disconnecting with an open transaction rolls it back.

~~~bash
migrate() {
  docker run --rm --network "$lab" -e PGPASSWORD=lab-only \
    --mount "type=bind,source=$PWD/db,target=/migrations,readonly" postgres:17 \
    psql -X -v ON_ERROR_STOP=1 -h postgres -U switchyard -d "${1:-switchyard}" -f /migrations/migrate.sql
}

migrate
sql -c 'SELECT version FROM schema_migrations ORDER BY version;'
~~~

~~~text
BEGIN
SET
 pg_advisory_xact_lock
-----------------------

(1 row)

CREATE TABLE
CREATE TABLE
INSERT 0 1
COMMIT
1
~~~

### Step 3. Insert data through parameters

With `PREPARE`, PostgreSQL parses the statement with two parameter slots. The `EXECUTE` line below uses SQL string literal syntax to supply test data. In lesson 03 the Go driver sends these values separately from the SQL.

<!-- file: drills/job-example.sql -->
~~~sql
PREPARE add_job (text, bigint) AS
    INSERT INTO jobs (description, duration_ns, state, created_at, updated_at)
    VALUES ($1, $2, 'queued', now(), now())
    RETURNING id, description, state;

EXECUTE add_job('Resize O''Reilly''s cover', 200000000);
~~~

~~~bash
sql < drills/job-example.sql
~~~

~~~text
PREPARE
1|Resize O'Reilly's cover|queued
INSERT 0 1
~~~

Try a negative duration and read the constraint failure:

~~~bash
sql -c "INSERT INTO jobs (description, duration_ns, state, created_at, updated_at)
VALUES ('bad duration', -1, 'queued', now(), now());"
~~~

~~~text
ERROR:  new row for relation "jobs" violates check constraint "jobs_duration_ns_check"
DETAIL:  Failing row contains (2, bad duration, -1, queued, , 2026-11-21 04:09:09.074139+00, 2026-11-21 04:09:09.074139+00).
~~~

### Step 4. Add an index for pending work

The recovery lesson will look for the oldest queued job. Seed a table with mostly completed jobs and a few queued ones so the planner has a real choice. These rows are fixtures for the disposable lab.

~~~bash
sql -c "INSERT INTO jobs (description, duration_ns, state, created_at, updated_at)
SELECT 'seed ' || n, 0, CASE WHEN n % 1000 = 0 THEN 'queued' ELSE 'completed' END, now(), now()
FROM generate_series(1, 100000) AS n;"
sql -c 'ANALYZE jobs;'
sql -c "EXPLAIN (COSTS OFF) SELECT id FROM jobs WHERE state = 'queued' ORDER BY id LIMIT 10;"
~~~

~~~text
INSERT 0 100000
ANALYZE
Limit
  ->  Index Scan using jobs_pkey on jobs
        Filter: (state = 'queued'::text)
~~~

Add an index whose entries are the IDs of queued jobs. A **partial index** has a predicate. That keeps finished jobs out of the index and lets the query read pending IDs in order.

<!-- file: db/migrations/002_queued_jobs.sql -->
~~~sql
CREATE INDEX jobs_queued_id ON jobs (id) WHERE state = 'queued';
~~~

Add the new migration to the driver just before `COMMIT`:

<!-- edit: db/migrate.sql -->
~~~sql
COMMIT;
~~~

~~~sql
SELECT NOT EXISTS (
    SELECT 1 FROM schema_migrations WHERE version = 2
) AS apply_002 \gset
\if :apply_002
    \ir migrations/002_queued_jobs.sql
    INSERT INTO schema_migrations (version) VALUES (2);
\endif
COMMIT;
~~~

~~~bash
migrate
sql -c "EXPLAIN (COSTS OFF) SELECT id FROM jobs WHERE state = 'queued' ORDER BY id LIMIT 10;"
sql -c 'SELECT id, description FROM jobs WHERE id = 1;'
~~~

~~~text
BEGIN
SET
 pg_advisory_xact_lock
-----------------------

(1 row)

psql:/migrations/migrate.sql:7: NOTICE:  relation "schema_migrations" already exists, skipping
CREATE TABLE
CREATE INDEX
INSERT 0 1
COMMIT
Limit
  ->  Index Only Scan using jobs_queued_id on jobs
1|Resize O'Reilly's cover
~~~

### Step 5. Check the upgrade and the rerun

Run the driver again. The applied versions stay at two and the existing job remains. Run the final driver against a fresh database, too, to check that it applies both versions from scratch.

~~~bash
migrate
sql -c 'SELECT version FROM schema_migrations ORDER BY version;'
sql -c 'SELECT count(*) FROM jobs;'
~~~

~~~text
BEGIN
SET
 pg_advisory_xact_lock
-----------------------

(1 row)

psql:/migrations/migrate.sql:7: NOTICE:  relation "schema_migrations" already exists, skipping
CREATE TABLE
COMMIT
1
2
100001
~~~

Try the same driver on an empty database:

~~~bash
sql -c 'CREATE DATABASE fresh;'
migrate fresh
docker exec "$db" psql -XAt -U switchyard -d fresh \
  -c 'SELECT version FROM schema_migrations ORDER BY version;'
~~~

~~~text
CREATE DATABASE
BEGIN
SET
 pg_advisory_xact_lock
-----------------------

(1 row)

CREATE TABLE
CREATE TABLE
INSERT 0 1
CREATE INDEX
INSERT 0 1
COMMIT
1
2
~~~

## Check it

Run the query over a small table as well. PostgreSQL may find scanning the table cheaper when almost every row is queued or the whole table fits on a page. Explain the index choice using the captured plan and the distribution of the data.

## If it goes wrong

- If `psql` cannot find an included file, run from the Switchyard root and check that the mount contains `migrate.sql` and `migrations/`.
- If a migration fails, read the first error before rerunning. Its history row should be absent after rollback. Keep a migration file stable once applied and put the next change in a new version.
- If the lock times out, check for another migration or a long transaction before retrying.

<!-- run: if [[ -n "${SWITCHYARD_TEST_DATABASE_URL:-}" ]]; then psql "$SWITCHYARD_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f db/migrate.sql; fi -->
