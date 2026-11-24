# 02 Commit the event with the write

> Event streams · Week 1

## The problem

Writing to PostgreSQL and sending to Kafka in separate calls leaves a gap. If the database commit finishes and the process dies before Kafka accepts the message, the history and stream disagree.

## The mental model

~~~text
one PostgreSQL transaction
    INSERT job_history
    INSERT event_outbox
COMMIT
~~~

## The pattern

A transactional outbox stores publication intent alongside the business write. The committed row contains the Kafka key and full event. Submitting the same event ID for the same job keeps its original publication intent. An ID reused for a different job fails as a conflict.

## Build it

### Store history and publication intent

Use a unique event ID in both tables. Give pending rows a partial index in relay order. Initialize the inbox and read-model tables for the consumer you will build in lesson 04.

Create `internal/store/writer.go`.

<!-- file: internal/store/writer.go -->
~~~go
package store

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"
	"switchyard/streams/internal/event"
)

const Schema = `
CREATE TABLE IF NOT EXISTS job_history (
    event_id text PRIMARY KEY,
    job_id text NOT NULL
);
CREATE TABLE IF NOT EXISTS event_outbox (
    seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id text NOT NULL UNIQUE REFERENCES job_history(event_id),
    job_id text NOT NULL,
    body jsonb NOT NULL,
    sent_at timestamptz
);
CREATE INDEX IF NOT EXISTS event_outbox_pending ON event_outbox (seq) WHERE sent_at IS NULL;
CREATE TABLE IF NOT EXISTS event_inbox (
    projection text NOT NULL,
    event_id text NOT NULL,
    job_id text NOT NULL,
    PRIMARY KEY (projection, event_id)
);
CREATE TABLE IF NOT EXISTS job_counts (
    projection text NOT NULL,
    job_id text NOT NULL,
    total bigint NOT NULL,
    PRIMARY KEY (projection, job_id)
);
`

// Record commits the job history and publication intent in one transaction.
func Record(ctx context.Context, db *pgxpool.Pool, e event.Event) error {
	body, err := json.Marshal(e)
	if err != nil {
		return err
	}
	tx, err := db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	result, err := tx.Exec(ctx, `INSERT INTO job_history (event_id, job_id)
VALUES ($1, $2) ON CONFLICT (event_id) DO NOTHING`, e.ID, e.Job)
	if err != nil {
		return err
	}
	if result.RowsAffected() == 0 {
		var job string
		if err := tx.QueryRow(ctx, "SELECT job_id FROM job_history WHERE event_id = $1", e.ID).Scan(&job); err != nil {
			return err
		}
		if job != e.Job {
			return errors.New("event ID already belongs to a different job")
		}
		return tx.Commit(ctx)
	}

	if _, err := tx.Exec(ctx, "INSERT INTO event_outbox (event_id, job_id, body) VALUES ($1, $2, $3::jsonb)", e.ID, e.Job, body); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func Pending(ctx context.Context, db *pgxpool.Pool) (int64, error) {
	var pending int64
	err := db.QueryRow(ctx, "SELECT count(*) FROM event_outbox WHERE sent_at IS NULL").Scan(&pending)
	return pending, err
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


The live gate adds a constraint that rejects the outbox insert and counts the surviving history and outbox rows. Both counts must be zero. If history remains, check that both inserts used the same transaction. An identity sequence can have gaps after a rollback. It is a local ordering aid.
