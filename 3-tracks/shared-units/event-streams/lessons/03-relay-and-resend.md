# 03 Relay and resend after a crash

> Event streams · Week 1

## The problem

Once an outbox row commits, the relay must remember to publish it. Once Kafka accepts it, another small crash window opens before the row can be marked sent.

## The mental model

~~~text
lock pending row → publish and wait → Kafka accepts → mark sent → commit
                                             ↑
                           kill relay here, then retry the row
~~~

## The pattern

Hold a row lock during a bounded attempt. After a crash, PostgreSQL releases the lock and rolls back the pending transaction. The replacement can publish the same event at another offset. Kafka producer idempotence helps with retries by that producer. Across two relay processes, the stable business ID still matters.

The lab uses one relay that processes rows in sequence. The sequence is allocation order and can differ from commit order for concurrent writers. If a business process needs a particular per-job order across concurrent writes, model that order explicitly. Kafka preserves the append order within each partition. [Kafka design](https://kafka.apache.org/41/design/design/) · [PostgreSQL locking clauses](https://www.postgresql.org/docs/17/sql-select.html#SQL-FOR-UPDATE-SHARE)

## Build it

### Select one pending record

Commit the sent marker only when the publisher returns success. Read your key and body from the durable row on every attempt.

Create `internal/store/relay.go`.

<!-- file: internal/store/relay.go -->
~~~go
package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Publish func(context.Context, string, []byte) error

// RelayOne leaves a row pending until Kafka has confirmed publication.
// The lab runs one relay. The row lock also keeps duplicate relay processes
// from picking the same pending row while the first publish is in flight.
func RelayOne(ctx context.Context, db *pgxpool.Pool, publish Publish) (bool, error) {
	tx, err := db.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)

	var seq int64
	var key string
	var body []byte
	err = tx.QueryRow(ctx, `SELECT seq, job_id, body FROM event_outbox
WHERE sent_at IS NULL ORDER BY seq LIMIT 1 FOR UPDATE`).Scan(&seq, &key, &body)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := publish(ctx, key, body); err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, "UPDATE event_outbox SET sent_at = now() WHERE seq = $1", seq); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}
~~~

### Use a keyed producer and an explicit topic

Create a three-partition, one-replica topic and use keyed, confirmed publishes. Keep the group setup next to the producer and use its consumer loop in the next lesson.

Create `internal/stream/kafka.go`.

<!-- file: internal/stream/kafka.go -->
~~~go
package stream

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"
)

func EnsureTopic(ctx context.Context, client *kgo.Client, topic string) error {
	admin := kadm.NewClient(client)
	_, err := admin.CreateTopic(ctx, 3, 1, nil, topic)
	if err != nil && !errors.Is(err, kerr.TopicAlreadyExists) {
		return fmt.Errorf("create topic: %w", err)
	}
	return nil
}

func Producer(brokers []string) (*kgo.Client, error) {
	return kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		kgo.RequiredAcks(kgo.AllISRAcks()),
		kgo.RecordPartitioner(kgo.StickyKeyPartitioner(nil)),
		kgo.RecordDeliveryTimeout(8*time.Second),
	)
}

func Consumer(brokers []string, topic, group string) (*kgo.Client, error) {
	return kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		kgo.ConsumerGroup(group),
		kgo.ConsumeTopics(topic),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()),
		kgo.DisableAutoCommit(),
		kgo.BlockRebalanceOnPoll(),
		kgo.SessionTimeout(10*time.Second),
		kgo.RebalanceTimeout(45*time.Second),
	)
}

// ConsumeOne processes and commits a single record. On failure the caller
// exits instead of polling ahead of the failed offset in that partition.
func ConsumeOne(ctx context.Context, client *kgo.Client, apply func(context.Context, *kgo.Record) error) error {
	var record *kgo.Record
	for record == nil {
		fetches := client.PollRecords(ctx, 1)
		if err := fetches.Err(); err != nil {
			client.AllowRebalance()
			return fmt.Errorf("poll Kafka: %w", err)
		}
		if records := fetches.Records(); len(records) > 0 {
			record = records[0]
		} else {
			client.AllowRebalance()
		}
	}
	defer client.AllowRebalance()
	attempt, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	if err := apply(attempt, record); err != nil {
		return fmt.Errorf("partition %d offset %d: %w", record.Partition, record.Offset, err)
	}
	if err := client.CommitRecords(attempt, record); err != nil {
		return fmt.Errorf("commit offset for partition %d: %w", record.Partition, err)
	}
	return nil
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


If the relay exits after publishing, `pending` should still report the row. If the replacement publishes it again, compare its partition and offset with the first result. The partition is unchanged and the offset increases.
