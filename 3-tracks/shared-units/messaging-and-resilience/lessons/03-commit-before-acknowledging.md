# 03 Commit before acknowledging

Store the command identity and its effect in the same PostgreSQL transaction. A repeated identity with the same normalized input observes the previous effect. An identity reused for different input is a permanent conflict. Build the worker so its sequence is commit, confirmed event publish, and consumer acknowledgment.

~~~text
receive -> decode -> durable ledger commit -> confirm completion event -> acknowledge
                        |                         |
                  effect survives          event may already exist
~~~

A crash between commit and acknowledgment lets the same command be delivered again. A crash after confirming the event can duplicate the event too. A stable event ID makes this visible to consumers. PostgreSQL and RabbitMQ commit independently. The [Event streams unit](../../event-streams/README.md) covers outbox and inbox patterns for that boundary.

The lab's crash flag exits only after the ledger commit. The worker stays sequential, with a prefetch of one, so retry and breaker observations are easy to attribute.

### breaker.go

Create `internal/delivery/breaker.go`.

<!-- file: internal/delivery/breaker.go -->
~~~go
package delivery

import (
	"errors"
	"time"
)

var ErrOpen = errors.New("dependency circuit open")
var ErrConflict = errors.New("command ID already bound to another job")

// Breaker belongs to one sequential consumer. It admits one call after cooldown.
type Breaker struct {
	failures int
	until    time.Time
}

func (b *Breaker) Attempt(now time.Time, work func() error) error {
	if now.Before(b.until) {
		return ErrOpen
	}
	err := work()
	if err == nil || errors.Is(err, ErrConflict) {
		b.failures = 0
		b.until = time.Time{}
		return err
	}
	b.failures++
	if b.failures >= 2 {
		b.until = now.Add(500 * time.Millisecond)
	}
	return err
}
~~~

### worker.go

Create `internal/delivery/worker.go`.

<!-- file: internal/delivery/worker.go -->
~~~go
package delivery

import (
	"context"
	"errors"
	"time"

	"switchyard/messaging/internal/contract"
)

type Outcome uint8

const (
	Acknowledge Outcome = iota
	DeadLetter
	Retry
)

type Worker struct {
	Store           func(context.Context, contract.Command) error
	Publish         func(context.Context, []byte) error
	AfterCommit     func()
	now             func() time.Time
	storage, broker Breaker
}

func (w *Worker) Handle(ctx context.Context, raw []byte) (Outcome, error) {
	command, err := contract.Decode(raw)
	if err != nil {
		return DeadLetter, err
	}
	now := w.now
	if now == nil {
		now = time.Now
	}
	err = w.storage.Attempt(now(), func() error { return w.Store(ctx, command) })
	if errors.Is(err, ErrConflict) {
		return DeadLetter, err
	}
	if err != nil {
		return Retry, err
	}
	if w.AfterCommit != nil {
		w.AfterCommit()
	}
	err = w.broker.Attempt(now(), func() error { return w.Publish(ctx, contract.Recorded(command)) })
	if err != nil {
		return Retry, err
	}
	return Acknowledge, nil
}
~~~

### store.go

Create `internal/ledger/store.go`.

<!-- file: internal/ledger/store.go -->
~~~go
package ledger

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"
	"switchyard/messaging/internal/contract"
	"switchyard/messaging/internal/delivery"
)

func Initialize(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS delivery_effects (
		event_id text PRIMARY KEY,
		job_id text NOT NULL
	)`)
	return err
}

// Apply binds one durable effect to each command identity. A repeated command
// observes its prior effect, while conflicting reuse is a permanent error.
func Apply(ctx context.Context, pool *pgxpool.Pool, c contract.Command) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, "INSERT INTO delivery_effects(event_id,job_id) VALUES ($1,$2) ON CONFLICT DO NOTHING", c.ID, c.Job)
	if err != nil {
		return err
	}
	var job string
	if err := tx.QueryRow(ctx, "SELECT job_id FROM delivery_effects WHERE event_id=$1", c.ID).Scan(&job); err != nil {
		return err
	}
	if job != c.Job {
		return delivery.ErrConflict
	}
	return tx.Commit(ctx)
}
~~~

### main.go

Create `cmd/messages/main.go`.

<!-- file: cmd/messages/main.go -->
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
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	amqp "github.com/rabbitmq/amqp091-go"
	"switchyard/messaging/internal/broker"
	"switchyard/messaging/internal/contract"
	"switchyard/messaging/internal/delivery"
	"switchyard/messaging/internal/ledger"
)

func run(ctx context.Context, args []string) error {
	flags := flag.NewFlagSet("messages", flag.ContinueOnError)
	input := flags.String("input", "", "path to a JSON command")
	queue := flags.String("queue", broker.Events, "inspection queue")
	crash := flags.Bool("crash-after-commit", false, "lab: exit before publishing or acknowledging")
	refuse := flags.String("refuse-job", "", "lab: return a temporary storage error for this job")
	if len(args) == 0 {
		return errors.New("choose send, drain, count, or work")
	}
	mode := args[0]
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	var db *pgxpool.Pool
	if mode == "work" || mode == "count" {
		dsn := os.Getenv("MESSAGING_DATABASE_URL")
		if dsn == "" {
			return errors.New("MESSAGING_DATABASE_URL is required")
		}
		d, err := pgxpool.New(ctx, dsn)
		if err != nil {
			return err
		}
		db = d
		defer db.Close()
		if err := ledger.Initialize(ctx, db); err != nil {
			return err
		}
		if mode == "count" {
			var n int
			if err := db.QueryRow(ctx, "SELECT count(*) FROM delivery_effects").Scan(&n); err != nil {
				return err
			}
			fmt.Println(n)
			return nil
		}
	}
	url := os.Getenv("MESSAGING_AMQP_URL")
	if url == "" {
		return errors.New("MESSAGING_AMQP_URL is required")
	}
	conn, err := amqp.Dial(url)
	if err != nil {
		return err
	}
	defer conn.Close()
	ch, err := conn.Channel()
	if err != nil {
		return err
	}
	defer ch.Close()
	if err := broker.Declare(ch); err != nil {
		return err
	}
	switch mode {
	case "send":
		p, err := broker.NewPublisher(ch)
		if err != nil {
			return err
		}
		data, err := os.ReadFile(*input)
		if err != nil {
			return err
		}
		deadline, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		return p.Send(deadline, broker.Commands, data)
	case "drain":
		if *queue != broker.Events && *queue != broker.Dead {
			return errors.New("only event and dead queues may be inspected")
		}
		for {
			d, ok, err := ch.Get(*queue, false)
			if err != nil {
				return err
			}
			if !ok {
				return nil
			}
			if err := json.NewEncoder(os.Stdout).Encode(string(d.Body)); err != nil {
				return err
			}
			if err := d.Ack(false); err != nil {
				return err
			}
		}
	case "work":
		pub, err := conn.Channel()
		if err != nil {
			return err
		}
		defer pub.Close()
		p, err := broker.NewPublisher(pub)
		if err != nil {
			return err
		}
		w := delivery.Worker{
			Store: func(ctx context.Context, c contract.Command) error {
				if c.Job == *refuse {
					return errors.New("lab storage fault")
				}
				return ledger.Apply(ctx, db, c)
			},
			Publish: func(ctx context.Context, b []byte) error { return p.Send(ctx, broker.Events, b) },
		}
		if *crash {
			w.AfterCommit = func() { log.Print("lab crash after durable effect and before acknowledgment"); os.Exit(70) }
		}
		if err := ch.Qos(1, 0, false); err != nil {
			return err
		}
		receipts, err := ch.Consume(broker.Commands, "delivery-worker", false, false, false, false, nil)
		if err != nil {
			return err
		}
		log.Print("worker receiving")
		for {
			select {
			case <-ctx.Done():
				return nil
			case d, ok := <-receipts:
				if !ok {
					return errors.New("broker closed the consumer")
				}
				child, cancel := context.WithTimeout(ctx, 3*time.Second)
				result, reason := w.Handle(child, d.Body)
				cancel()
				if result == delivery.Acknowledge {
					if err := d.Ack(false); err != nil {
						return err
					}
					log.Printf("acknowledged command (redelivered=%t)", d.Redelivered)
					continue
				}
				log.Printf("delivery %d: %v", result, reason)
				if pub.IsClosed() {
					return fmt.Errorf("publisher channel closed: %w", reason)
				}
				if err := d.Reject(result == delivery.Retry); err != nil {
					return err
				}
				if result == delivery.Retry {
					select {
					case <-ctx.Done():
						return nil
					case <-time.After(300 * time.Millisecond):
					}
				}
			}
		}
	default:
		return errors.New("unknown command")
	}
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
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
