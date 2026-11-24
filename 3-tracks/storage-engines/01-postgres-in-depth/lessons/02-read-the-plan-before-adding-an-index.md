# 02 Read the plan before adding an index

> Postgres in depth · Week 1

## The problem

A worker listing ready jobs sorts a sparse subset of a much larger table. You need to show that a proposed index reduces work for the same result.

## The mental model

~~~text
before: table scan → filter queued rows → sort → limit 16
after:  ordered partial index for queued rows → limit 16
~~~

## The pattern

Use the same query and fixture before and after the schema change. Inspect the actual plan tree and buffer counters, then compare the full ordered result. Run `EXPLAIN ANALYZE` only on a statement you intend to execute. The gate uses a read-only listing query. Timing is disabled for the per-node instrumentation so the check can focus on plan and work. [Using EXPLAIN](https://www.postgresql.org/docs/17/using-explain.html)

## Build it

### Load a selective workload

Make only 100 of 50,000 job rows eligible by status and analyze the fixture.

Create `sql/02-plan-fixture.sql`.

<!-- file: sql/02-plan-fixture.sql -->
~~~sql
CREATE TABLE job_listing (
    id bigint PRIMARY KEY,
    status text NOT NULL,
    run_at timestamptz NOT NULL,
    payload text NOT NULL
);
INSERT INTO job_listing
SELECT n,
       CASE WHEN n % 500 = 0 THEN 'queued' ELSE 'done' END,
       timestamptz '2026-01-01 00:00Z' + n * interval '1 second',
       repeat('switchyard ', 8)
FROM generate_series(1, 50000) n;

ANALYZE job_listing;
~~~

### Index the predicate and ordering

Use the queued-only predicate and the same two sort keys needed by the listing.

Create `sql/05-ready-index.sql`.

<!-- file: sql/05-ready-index.sql -->
~~~sql
CREATE INDEX job_listing_ready ON job_listing (run_at, id)
WHERE status = 'queued';
ANALYZE job_listing;
~~~

### Compare plans and result IDs

Find access nodes recursively in JSON format. Compare shared hit plus read blocks at the root to avoid adding child work twice.

Create `lab/plan_test.go`.

<!-- file: lab/plan_test.go -->
~~~go
package lab

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

const listing = `SELECT id FROM job_listing
WHERE status = 'queued' AND run_at <= timestamptz '2026-02-01 00:00Z'
ORDER BY run_at, id LIMIT 16`

type node struct {
	Type     string `json:"Node Type"`
	Index    string `json:"Index Name"`
	Hit      int    `json:"Shared Hit Blocks"`
	Read     int    `json:"Shared Read Blocks"`
	Children []node `json:"Plans"`
}

func (n node) has(kind, index string) bool {
	if n.Type == kind && (index == "" || n.Index == index) {
		return true
	}
	for _, child := range n.Children {
		if child.has(kind, index) {
			return true
		}
	}
	return false
}

func explain(t *testing.T, ctx context.Context, db *pgxpool.Pool, label string) node {
	t.Helper()
	var data []byte
	sql := "EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) " + listing
	if err := db.QueryRow(ctx, sql).Scan(&data); err != nil {
		t.Fatal(err)
	}
	var result []struct {
		Plan node
	}
	if err := json.Unmarshal(data, &result); err != nil || len(result) != 1 {
		t.Fatalf("unexpected plan: %v", err)
	}
	if dir := os.Getenv("STORAGE_EVIDENCE_DIR"); dir != "" {
		if err := os.WriteFile(filepath.Join(dir, label+".json"), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return result[0].Plan
}

func ids(t *testing.T, ctx context.Context, db *pgxpool.Pool) []int64 {
	t.Helper()
	rows, err := db.Query(ctx, listing)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	result := []int64{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		result = append(result, id)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return result
}

func plans(t *testing.T, ctx context.Context, db *pgxpool.Pool) {
	original := ids(t, ctx, db)
	before := explain(t, ctx, db, "plan-before")
	migration, err := os.ReadFile("../sql/05-ready-index.sql")
	if err != nil {
		t.Fatal(err)
	}
	exec(t, ctx, db, string(migration))
	after := explain(t, ctx, db, "plan-after")
	if len(original) != 16 || !slices.Equal(original, ids(t, ctx, db)) {
		t.Fatal("the index changed the selected IDs or their ordering")
	}
	unindexed, indexed := before.Hit+before.Read, after.Hit+after.Read
	if !before.has("Seq Scan", "") || !after.has("Index Only Scan", "job_listing_ready") ||
		indexed <= 0 || indexed*8 >= unindexed {
		t.Fatalf("unexpected plans: before=%+v after=%+v", before, after)
	}
	t.Logf("EXPLAIN: Seq Scan → Index Only Scan, shared buffer accesses %d → %d, same ordered 16 IDs", unindexed, indexed)
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


The checked query changed from a sequential scan to an index-only scan. It returned the same ordered 16 IDs and the root reported 910 versus 17 shared buffer accesses in the reference run. These accesses include cache hits. The index-only node still reported 16 heap fetches to check visibility. [Captured plans](../evidence/README.md)
