# 01 Reproduce isolation anomalies

> Postgres in depth · Week 1

## The problem

Two workers read a counter at zero and each writes its own computed value of one. Two on-call operators can also each see two active people and decide to leave. In each case the application made a reasonable decision from a stale view.

## The mental model

~~~text
counter: A reads 0 → B reads 0 → A writes 1 commits → B writes 1 commits
on-call: A reads 2 → B reads 2 → A clears alice ─────→ B clears bob
~~~

## The pattern

Schedule the two sessions explicitly. PostgreSQL Read Committed gives each statement a fresh snapshot. The client can still reuse a stale value it read earlier. Update the counter in one SQL expression. When a decision needs a same-row read followed by a write, a row lock can serialize the decision. PostgreSQL Repeatable Read can reject a same-row stale write with SQLSTATE 40001, yet both operators can update separate rows from a consistent old snapshot. Serializable detects the conflicting dependency and forces the whole transaction to retry. [PostgreSQL isolation](https://www.postgresql.org/docs/17/transaction-iso.html)

## Build it

### Create the two invariants

Seed a single counter and two operators who must leave at least one person on call.

Create `sql/01-isolation.sql`.

<!-- file: sql/01-isolation.sql -->
~~~sql
CREATE TABLE isolation_counter (
    id integer PRIMARY KEY,
    value integer NOT NULL
);
INSERT INTO isolation_counter VALUES (1, 0);

CREATE TABLE on_call (
    operator text PRIMARY KEY,
    active boolean NOT NULL
);
INSERT INTO on_call VALUES ('alice', true), ('bob', true);
~~~

### Drive the schedules in two sessions

Hold separate transactions open and control the commit order. The retry must start a new transaction and reevaluate the invariant.

Create `lab/isolation_test.go`.

<!-- file: lab/isolation_test.go -->
~~~go
package lab

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

type executor interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}

func exec(t *testing.T, ctx context.Context, db executor, sql string, args ...any) {
	t.Helper()
	if _, err := db.Exec(ctx, sql, args...); err != nil {
		t.Fatal(err)
	}
}

func begin(t *testing.T, ctx context.Context, db *pgxpool.Pool, level pgx.TxIsoLevel) pgx.Tx {
	t.Helper()
	tx, err := db.BeginTx(ctx, pgx.TxOptions{IsoLevel: level})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(ctx) })
	return tx
}

func commit(t *testing.T, ctx context.Context, tx pgx.Tx) {
	t.Helper()
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
}

func sqlState(err error) string {
	var failure *pgconn.PgError
	if errors.As(err, &failure) {
		return failure.Code
	}
	return ""
}

type queryRower interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func number(t *testing.T, ctx context.Context, db queryRower, sql string, args ...any) int64 {
	t.Helper()
	var value int64
	if err := db.QueryRow(ctx, sql, args...).Scan(&value); err != nil {
		t.Fatal(err)
	}
	return value
}

func isolation(t *testing.T, ctx context.Context, db *pgxpool.Pool) {
	const counter = "SELECT value FROM isolation_counter WHERE id = 1"
	for _, level := range []pgx.TxIsoLevel{pgx.ReadCommitted, pgx.RepeatableRead} {
		exec(t, ctx, db, "UPDATE isolation_counter SET value = 0 WHERE id = 1")
		a, b := begin(t, ctx, db, level), begin(t, ctx, db, level)
		first, second := number(t, ctx, a, counter), number(t, ctx, b, counter)
		if first != 0 || second != 0 {
			t.Fatal("the transactions must read the same starting version")
		}
		exec(t, ctx, a, "UPDATE isolation_counter SET value = $1 WHERE id = 1", first+1)
		commit(t, ctx, a)
		_, err := b.Exec(ctx, "UPDATE isolation_counter SET value = $1 WHERE id = 1", second+1)
		if level == pgx.ReadCommitted {
			if err != nil {
				t.Fatal(err)
			}
			commit(t, ctx, b)
		} else {
			if sqlState(err) != "40001" {
				t.Fatalf("repeatable-read conflict = %v, want SQLSTATE 40001", err)
			}
			if err := b.Rollback(ctx); err != nil {
				t.Fatal(err)
			}
		}
		if got := number(t, ctx, db, counter); got != 1 {
			t.Fatalf("counter = %d, want 1", got)
		}
	}
	t.Log("lost update: two READ COMMITTED writes left 1; REPEATABLE READ rejected the stale update with 40001")

	exec(t, ctx, db, "UPDATE isolation_counter SET value = 0 WHERE id = 1")
	a, b := begin(t, ctx, db, pgx.ReadCommitted), begin(t, ctx, db, pgx.ReadCommitted)
	if number(t, ctx, a, counter) != 0 || number(t, ctx, b, counter) != 0 {
		t.Fatal("atomic updates must start from the same schedule")
	}
	for _, tx := range []pgx.Tx{a, b} {
		exec(t, ctx, tx, "UPDATE isolation_counter SET value = value + 1 WHERE id = 1")
		commit(t, ctx, tx)
	}
	if got := number(t, ctx, db, counter); got != 2 {
		t.Fatalf("atomic updates left %d, want 2", got)
	}
	t.Log("atomic UPDATE kept both increments")

	const active = "SELECT count(*) FROM on_call WHERE active"
	for _, level := range []pgx.TxIsoLevel{pgx.RepeatableRead, pgx.Serializable} {
		exec(t, ctx, db, "UPDATE on_call SET active = true")
		a, b := begin(t, ctx, db, level), begin(t, ctx, db, level)
		if number(t, ctx, a, active) != 2 || number(t, ctx, b, active) != 2 {
			t.Fatal("both operators should see two active operators")
		}
		exec(t, ctx, a, "UPDATE on_call SET active = false WHERE operator = 'alice'")
		commit(t, ctx, a)
		_, err := b.Exec(ctx, "UPDATE on_call SET active = false WHERE operator = 'bob'")
		if err == nil {
			err = b.Commit(ctx)
		} else {
			_ = b.Rollback(ctx)
		}
		if level == pgx.RepeatableRead {
			if err != nil || number(t, ctx, db, active) != 0 {
				t.Fatalf("expected repeatable-read write skew, got %v", err)
			}
			continue
		}
		if sqlState(err) != "40001" {
			t.Fatalf("serializable conflict = %v, want SQLSTATE 40001", err)
		}
		retry := begin(t, ctx, db, pgx.Serializable)
		if number(t, ctx, retry, active) != 1 {
			t.Fatal("retry should see the invariant at its minimum")
		}
		// With only one operator left, keep that operator active.
		commit(t, ctx, retry)
	}
	t.Log("write skew: REPEATABLE READ left zero on-call operators; SERIALIZABLE plus a fresh retry kept one")
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


On PostgreSQL 17, the stale write schedule ends at 1 and the atomic update routine ends at 2. The on-call example leaves 0 active at Repeatable Read and 1 after the Serializable retry. The live gate in lesson 07 observes both.
