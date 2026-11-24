# 04 Apply the event, then commit its offset

> Event streams · Week 2

## The problem

Committing an offset first can lose an update if the process dies before PostgreSQL commits. Committing the offset after the database gives the consumer a chance to see the same event again.

## The mental model

~~~text
Kafka fetch → PostgreSQL inbox + count transaction → Kafka offset commit
                                     ↑
                           kill projector here
~~~

## The pattern

A consumer group distributes partitions among members and tracks progress separately for each partition. A committed offset tells the group where to resume. Disable automatic commits. Apply one record and commit its offset only after the inbox and the count commit together. Release the rebalance block on each poll, including empty fetches and errors, so partitions can move. [franz-go consumer API](https://pkg.go.dev/github.com/twmb/franz-go@v1.22.1/pkg/kgo#BlockRebalanceOnPoll)

The inbox key is the projection and event ID. Two offsets can carry the same business event. Both belong to the log and only the first increments that projection's count.

## Build it

### Claim the event and increment in the same transaction

Use the unique inbox row to decide whether to increment. Compare the job on repeated IDs to catch a conflicting event.

Create `internal/store/project.go`.

<!-- file: internal/store/project.go -->
~~~go
package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"
	"switchyard/streams/internal/event"
)

// Apply claims an event for this projection and updates the count atomically.
func Apply(ctx context.Context, db *pgxpool.Pool, projection string, e event.Event) (bool, error) {
	tx, err := db.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)

	claim, err := tx.Exec(ctx, `INSERT INTO event_inbox (projection, event_id, job_id)
VALUES ($1, $2, $3) ON CONFLICT (projection, event_id) DO NOTHING`, projection, e.ID, e.Job)
	if err != nil {
		return false, err
	}
	if claim.RowsAffected() == 0 {
		var job string
		if err := tx.QueryRow(ctx, "SELECT job_id FROM event_inbox WHERE projection = $1 AND event_id = $2", projection, e.ID).Scan(&job); err != nil {
			return false, err
		}
		if job != e.Job {
			return false, errors.New("inbox event ID has a different job")
		}
		return false, tx.Commit(ctx)
	}

	if _, err := tx.Exec(ctx, `INSERT INTO job_counts (projection, job_id, total)
VALUES ($1, $2, 1) ON CONFLICT (projection, job_id)
DO UPDATE SET total = job_counts.total + 1`, projection, e.Job); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

func Snapshot(ctx context.Context, db *pgxpool.Pool, projection string) (map[string]int64, error) {
	rows, err := db.Query(ctx, "SELECT job_id, total FROM job_counts WHERE projection = $1", projection)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	counts := make(map[string]int64)
	for rows.Next() {
		var job string
		var total int64
		if err := rows.Scan(&job, &total); err != nil {
			return nil, err
		}
		counts[job] = total
	}
	return counts, rows.Err()
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


Follow the existing `ConsumeOne` function from poll through `apply` to `CommitRecords`. If event validation or the database fails, return an error and stop the projector at the record. A retry can then read it again.
