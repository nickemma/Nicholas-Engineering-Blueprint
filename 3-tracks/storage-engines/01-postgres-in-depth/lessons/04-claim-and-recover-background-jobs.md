# 04 Claim and recover background jobs

> Postgres in depth · Week 2

## The problem

Two reapers that compete for the same due job can block one another. If a worker crashes after claiming a job, the row needs a path back to the queue and old workers need to lose write authority.

## The mental model

~~~text
queued → short claim transaction → leased with attempt token
                       expired → requeue a bounded batch
new attempt → fenced completion and effect in one transaction
~~~

## The pattern

Use `FOR UPDATE SKIP LOCKED` on an ordered eligible batch. This lets independent workers skip work already locked by another claim. It offers progress on a queue and may leave an older locked job behind. Expire a lease in a bounded scan and increment its token when claiming again. Require the current unexpired token to complete the job, and record the effect in the same database statement. [PostgreSQL locking clauses](https://www.postgresql.org/docs/17/sql-select.html#SQL-FOR-UPDATE-SHARE)

## Build it

### Implement claim, requeue, and completion

Add separate partial indexes for due queued rows and expired leases. Use the database clock by default and accept explicit fixture times in the tests.

Create `sql/03-queue.sql`.

<!-- file: sql/03-queue.sql -->
~~~sql
CREATE TABLE maintenance_job (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_at timestamptz NOT NULL,
    status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'leased', 'done')),
    attempt bigint NOT NULL DEFAULT 0 CHECK (attempt >= 0),
    lease_until timestamptz,
    CHECK ((status = 'leased') = (lease_until IS NOT NULL))
);

CREATE TABLE maintenance_effect (
    job_id bigint PRIMARY KEY REFERENCES maintenance_job(id),
    attempt bigint NOT NULL
);

CREATE INDEX maintenance_queued ON maintenance_job (run_at, id)
WHERE status = 'queued';
CREATE INDEX maintenance_expired ON maintenance_job (lease_until, id)
WHERE status = 'leased';

CREATE FUNCTION claim_job(at_time timestamptz DEFAULT NULL)
RETURNS TABLE(job_id bigint, lease_attempt bigint) LANGUAGE sql AS $$
    WITH picked AS (
        SELECT id FROM maintenance_job
        WHERE status = 'queued' AND run_at <= coalesce(at_time, statement_timestamp())
        ORDER BY run_at, id LIMIT 1
        FOR UPDATE SKIP LOCKED
    )
    UPDATE maintenance_job AS j
    SET status = 'leased', attempt = j.attempt + 1,
        lease_until = coalesce(at_time, statement_timestamp()) + interval '10 seconds'
    FROM picked WHERE j.id = picked.id
    RETURNING j.id, j.attempt;
$$;

CREATE FUNCTION finish_job(target_id bigint, token bigint, at_time timestamptz DEFAULT NULL)
RETURNS boolean LANGUAGE sql AS $$
    WITH finished AS (
        UPDATE maintenance_job
        SET status = 'done', lease_until = NULL
        WHERE id = target_id AND status = 'leased' AND attempt = token
          AND lease_until > coalesce(at_time, statement_timestamp())
        RETURNING id, attempt
    ), recorded AS (
        INSERT INTO maintenance_effect (job_id, attempt)
        SELECT id, attempt FROM finished RETURNING job_id
    )
    SELECT EXISTS (SELECT FROM recorded);
$$;

CREATE FUNCTION requeue_expired(batch_size integer, at_time timestamptz DEFAULT NULL)
RETURNS integer LANGUAGE sql AS $$
    WITH picked AS (
        SELECT id FROM maintenance_job
        WHERE status = 'leased' AND lease_until <= coalesce(at_time, statement_timestamp())
        ORDER BY lease_until, id LIMIT greatest(0, least(batch_size, 64))
        FOR UPDATE SKIP LOCKED
    ), changed AS (
        UPDATE maintenance_job AS j
        SET status = 'queued', lease_until = NULL
        FROM picked WHERE j.id = picked.id RETURNING j.id
    )
    SELECT count(*)::integer FROM changed;
$$;
~~~

### Hold a row while a second claimant runs

Keep the first transaction open until the second has committed. Then advance fixture time, reap one job, and require the replacement token.

Create `lab/queue_test.go`.

<!-- file: lab/queue_test.go -->
~~~go
package lab

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func claimed(t *testing.T, ctx context.Context, db queryRower, at time.Time) (int64, int64) {
	t.Helper()
	var id, attempt int64
	err := db.QueryRow(ctx, "SELECT * FROM claim_job($1)", at).Scan(&id, &attempt)
	if err != nil {
		t.Fatalf("claim cannot proceed: SQLSTATE %s (%v)", sqlState(err), err)
	}
	return id, attempt
}

func finished(t *testing.T, ctx context.Context, db *pgxpool.Pool, id, attempt int64, at time.Time) bool {
	t.Helper()
	var ok bool
	if err := db.QueryRow(ctx, "SELECT finish_job($1, $2, $3)", id, attempt, at).Scan(&ok); err != nil {
		t.Fatal(err)
	}
	return ok
}

func queue(t *testing.T, ctx context.Context, db *pgxpool.Pool) {
	at := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	exec(t, ctx, db, "INSERT INTO maintenance_job (run_at) VALUES ($1), ($1)", at)
	workerA := begin(t, ctx, db, pgx.ReadCommitted)
	id, old := claimed(t, ctx, workerA, at)

	// Worker A still owns the row lock in its open transaction. A second
	// physical session must claim a different record before A commits.
	other, otherToken := claimed(t, ctx, db, at)
	if id != 1 || other != 2 || old != 1 || otherToken != 1 {
		t.Fatal("claims did not return distinct first attempts")
	}
	commit(t, ctx, workerA)
	if !finished(t, ctx, db, other, otherToken, at.Add(time.Second)) {
		t.Fatal("worker B failed to complete its live attempt")
	}
	t.Log("second worker skipped the locked first row and committed an independent claim")

	later := at.Add(11 * time.Second)
	if changed := number(t, ctx, db, "SELECT requeue_expired(1, $1)", later); changed != 1 {
		t.Fatalf("reaper changed %d jobs, want 1", changed)
	}
	newID, replacement := claimed(t, ctx, db, later)
	if newID != id || replacement != old+1 {
		t.Fatal("replacement did not come back with a new attempt token")
	}
	if finished(t, ctx, db, id, old, later) ||
		!finished(t, ctx, db, id, replacement, later) ||
		finished(t, ctx, db, id, replacement, later) {
		t.Fatal("completion was not fenced to one current attempt")
	}
	if number(t, ctx, db, "SELECT count(*) FROM maintenance_effect") != 2 ||
		number(t, ctx, db, "SELECT attempt FROM maintenance_effect WHERE job_id = $1", id) != replacement {
		t.Fatal("durable effects did not match the accepted attempts")
	}
	t.Log("lease recovery: reaper reclaimed one expired job; stale and repeated completions left the effect count at two")
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


The live gate expects two committed effects for two jobs. It also replaces just the claim selector with plain `FOR UPDATE` in a separate database. The same test must hit SQLSTATE 55P03. The fencing proof covers the transactional effect table. An external effect would need its own idempotency or fencing protocol.
