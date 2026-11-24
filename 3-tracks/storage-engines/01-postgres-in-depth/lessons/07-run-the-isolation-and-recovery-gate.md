# 07 Run the isolation and recovery gate

> Postgres in depth · Week 3

## The problem

A restore is only useful when the recovered data meets the recovery target. A concurrent queue is only useful when another worker can make progress under a held lock. The combined gate checks both using a disposable server.

## Build it

### Run the SQL schedules in a fresh database

Give the pool enough sessions for both sides and bound database operations. The gate provisions all the SQL files before invoking the tests.

Create `lab/live_test.go`.

<!-- file: lab/live_test.go -->
~~~go
package lab

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestLive(t *testing.T) {
	if os.Getenv("STORAGE_TEST_LIVE") != "1" {
		t.Skip("use the live gate to start the disposable PostgreSQL server")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 25*time.Second)
	defer cancel()
	cfg, err := pgxpool.ParseConfig(os.Getenv("STORAGE_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	cfg.MaxConns = 6
	cfg.ConnConfig.RuntimeParams["lock_timeout"] = "400ms"
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = "5s"
	db, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	t.Run("isolation", func(t *testing.T) { isolation(t, ctx, db) })
	t.Run("plan", func(t *testing.T) { plans(t, ctx, db) })
	t.Run("queue", func(t *testing.T) { queue(t, ctx, db) })
}
~~~

## Check it

~~~bash
SWITCHYARD_PG_DEPTH_LIVE=1 bash "$blueprint/3-tracks/storage-engines/01-postgres-in-depth/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/01-postgres-in-depth/gate/run.sh" "$PWD" -->

Use the [gate guide](../gate/README.md) to save the plan JSON and compare it with the [reference](../evidence/README.md). When rebuilding from memory, make a transaction schedule and recovery target table first, then match each observed outcome to its target.

## If it goes wrong

| Symptom | Check |
|---|---|
| The second update unexpectedly commits | Check the isolation level and whether both reads happened before the first commit. |
| The planner still scans the table | Check statistics, the partial predicate, and the selectivity of the same fixture. |
| The second worker times out | Check whether the selector is skipping locked rows and whether there is another eligible job. |
| Recovery cannot reach the named target | Check the base backup, segment switch, archive completion, and target log. |
