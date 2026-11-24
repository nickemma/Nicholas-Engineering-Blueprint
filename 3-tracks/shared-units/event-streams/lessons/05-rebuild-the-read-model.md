# 05 Rebuild the read model from the log

> Event streams · Week 2

## The problem

A read model can drift or need a new definition. Reusing the running group's offsets would start partway through the retained log. Reusing its inbox would make earlier events look already applied.

## The mental model

~~~text
retained topic  ──┬─ live group    ── live inbox and counts
                  └─ rebuild group ── rebuild inbox and counts
~~~

## The pattern

Create a fresh group and a fresh projection together. The consumer starts at the earliest retained offset when that group has no stored position. The first and replayed models should agree for the same retained records. Plan retention around how much history a rebuild requires. [Kafka design](https://kafka.apache.org/41/design/design/)

## Build it

### Expose the writer, relay, and projector

Use the same `-group` name for Kafka offsets and its PostgreSQL projection. Keep the fault hooks at the two different commit boundaries.

Create `cmd/streams/main.go`.

<!-- file: cmd/streams/main.go -->
~~~go
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/twmb/franz-go/pkg/kgo"
	"switchyard/streams/internal/event"
	"switchyard/streams/internal/store"
	"switchyard/streams/internal/stream"
)

func run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("choose init, record, pending, relay, project, or snapshot")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	id := flags.String("id", "", "stable event ID")
	job := flags.String("job", "", "job ID")
	group := flags.String("group", "job-counts-v1", "group and read model name")
	limit := flags.Int("limit", 1, "maximum number of records to relay or project")
	crash := flags.Bool("crash", false, "lab: exit across the selected commit boundary")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 || *limit < 1 || *limit > 100 || !event.ValidName(*group) {
		return errors.New("invalid argument, limit, or group")
	}

	dsn := os.Getenv("STREAMS_DATABASE_URL")
	if dsn == "" {
		return errors.New("STREAMS_DATABASE_URL is required")
	}
	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return err
	}
	defer db.Close()

	switch args[0] {
	case "record":
		e, err := event.New(*id, *job)
		if err != nil {
			return err
		}
		return store.Record(ctx, db, e)
	case "pending":
		n, err := store.Pending(ctx, db)
		if err == nil {
			fmt.Println(n)
		}
		return err
	case "snapshot":
		counts, err := store.Snapshot(ctx, db, *group)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(counts)
	}

	seeds := os.Getenv("STREAMS_KAFKA_BROKERS")
	topic := os.Getenv("STREAMS_TOPIC")
	if seeds == "" || !event.ValidName(topic) {
		return errors.New("STREAMS_KAFKA_BROKERS and a valid STREAMS_TOPIC are required")
	}
	brokers := strings.Split(seeds, ",")
	switch args[0] {
	case "init", "relay":
		client, err := stream.Producer(brokers)
		if err != nil {
			return err
		}
		defer client.Close()
		if args[0] == "init" {
			if err := stream.EnsureTopic(ctx, client, topic); err != nil {
				return err
			}
			_, err := db.Exec(ctx, store.Schema)
			return err
		}
		for range *limit {
			attempt, cancel := context.WithTimeout(ctx, 10*time.Second)
			more, err := store.RelayOne(attempt, db, func(ctx context.Context, key string, body []byte) error {
				record := &kgo.Record{Topic: topic, Key: []byte(key), Value: body}
				if err := client.ProduceSync(ctx, record).FirstErr(); err != nil {
					return err
				}
				fmt.Printf("published job=%s partition=%d offset=%d\n", key, record.Partition, record.Offset)
				if *crash {
					os.Exit(70)
				}
				return nil
			})
			cancel()
			if err != nil || !more {
				return err
			}
		}
		return nil
	case "project":
		client, err := stream.Consumer(brokers, topic, *group)
		if err != nil {
			return err
		}
		defer client.Close()
		for range *limit {
			err := stream.ConsumeOne(ctx, client, func(ctx context.Context, record *kgo.Record) error {
				e, err := event.Decode(record.Key, record.Value)
				if err != nil {
					return err
				}
				applied, err := store.Apply(ctx, db, *group, e)
				if err != nil {
					return err
				}
				fmt.Printf("received id=%s partition=%d offset=%d applied=%t\n", e.ID, record.Partition, record.Offset, applied)
				if *crash {
					os.Exit(71)
				}
				return nil
			})
			if err != nil {
				return err
			}
		}
		return nil
	default:
		return errors.New("unknown command")
	}
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	if err := run(ctx, os.Args[1:]); err != nil {
		log.Fatal(err)
	}
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


`relay` publishes up to its limit and can stop sooner if the outbox is empty. `project` waits for the requested number of Kafka records, with one deadline for the command. The limit counts deliveries, including duplicates. If a replay times out, check the group name, the retained records, and the number you requested.
