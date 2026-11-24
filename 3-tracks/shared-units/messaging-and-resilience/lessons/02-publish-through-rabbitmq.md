# 02 Publish through RabbitMQ

The producer and worker are separate processes. Create a quorum command queue, a completion-events queue, and a dead-letter queue. Use the default exchange and the queue name as the route for this lab. Set the persistent delivery mode, request a publisher confirm, and surface an unroutable return. A publisher confirm is evidence about the broker accepting the publish. Later, a consumer acknowledgment marks a particular delivery as processed.

The example uses one sequential publisher per channel. Retire the channel after an ambiguous confirmation timeout rather than reusing it for the next publish. The native gate starts a one-node RabbitMQ instance to exercise protocol behavior. High availability and dead-letter resilience across brokers require their own tests. [RabbitMQ confirms and acknowledgments](https://www.rabbitmq.com/docs/confirms)

### rabbit.go

Create `internal/broker/rabbit.go`.

<!-- file: internal/broker/rabbit.go -->
~~~go
package broker

import (
	"context"
	"errors"
	"fmt"

	amqp "github.com/rabbitmq/amqp091-go"
)

const (
	Commands = "switchyard.commands"
	Events   = "switchyard.events"
	Dead     = "switchyard.dead"
)

func Declare(ch *amqp.Channel) error {
	for _, name := range []string{Dead, Events} {
		if _, err := ch.QueueDeclare(name, true, false, false, false, nil); err != nil {
			return err
		}
	}
	_, err := ch.QueueDeclare(Commands, true, false, false, false, amqp.Table{
		"x-queue-type": "quorum", "x-delivery-limit": int32(3),
		"x-dead-letter-exchange": "", "x-dead-letter-routing-key": Dead,
	})
	return err
}

// Publisher is used sequentially. The server sends an unroutable return before
// confirming the publish. Drain it after the confirmation so refusal is visible.
type Publisher struct {
	ch       *amqp.Channel
	returned <-chan amqp.Return
}

func NewPublisher(ch *amqp.Channel) (*Publisher, error) {
	if err := ch.Confirm(false); err != nil {
		return nil, err
	}
	return &Publisher{ch, ch.NotifyReturn(make(chan amqp.Return, 1))}, nil
}

func (p *Publisher) Send(ctx context.Context, queue string, body []byte) error {
	confirmation, err := p.ch.PublishWithDeferredConfirmWithContext(ctx, "", queue, true, false, amqp.Publishing{
		ContentType: "application/json", DeliveryMode: amqp.Persistent, Body: body,
	})
	if err != nil {
		return err
	}
	ok, err := confirmation.WaitContext(ctx)
	if err != nil {
		// A timed-out confirmation can arrive later. Retire this connection
		// path so the next receipt cannot confuse it with a new publish.
		p.ch.Close()
		return err
	}
	if !ok {
		return errors.New("publish was not confirmed")
	}
	select {
	case returned, open := <-p.returned:
		if !open {
			return errors.New("publisher channel closed")
		}
		return fmt.Errorf("message did not route: %d", returned.ReplyCode)
	default:
		return nil
	}
}
~~~

## Check it

~~~bash
go test -race -count=1 ./internal/broker
~~~

<!-- run: go test -race -count=1 ./internal/broker -->
