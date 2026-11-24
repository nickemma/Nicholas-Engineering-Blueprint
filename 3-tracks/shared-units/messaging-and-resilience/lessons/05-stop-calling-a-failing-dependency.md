# 05 Stop calling a failing dependency

Place independent circuit breakers around the store and completion publisher. Two consecutive failures open the corresponding circuit. A call during cooldown is refused without touching that dependency. After cooldown, one trial may proceed. A successful trial closes the circuit. Keep one breaker per dependency so a publisher fault does not masquerade as a database outage.

The lab drives exactly one worker loop. Test with a fake clock so the assertion checks the number of dependency calls, without sleeps. Keep message retry and circuit state conceptually separate. A retry decides what happens to a delivery. A breaker decides whether to contact a dependency.

### worker_test.go

Create `internal/delivery/worker_test.go`.

<!-- file: internal/delivery/worker_test.go -->
~~~go
package delivery

import (
	"context"
	"errors"
	"testing"
	"time"

	"switchyard/messaging/internal/contract"
)

func TestBothBreakersOpenAndRecover(t *testing.T) {
	for _, dependency := range []string{"store", "publish"} {
		t.Run(dependency, func(t *testing.T) {
			now := time.Unix(100, 0)
			calls := 0
			fault := true
			attempt := func() error {
				calls++
				if fault {
					return errors.New("unavailable")
				}
				return nil
			}
			w := Worker{now: func() time.Time { return now }, Store: func(context.Context, contract.Command) error { return nil },
				Publish: func(context.Context, []byte) error { return nil }}
			if dependency == "store" {
				w.Store = func(context.Context, contract.Command) error { return attempt() }
			} else {
				w.Publish = func(context.Context, []byte) error { return attempt() }
			}
			raw := []byte(`{"id":"cmd","kind":"record-job","version":2,"payload":{"job":"job"}}`)
			for range 2 {
				if got, _ := w.Handle(context.Background(), raw); got != Retry {
					t.Fatal(got)
				}
			}
			if got, err := w.Handle(context.Background(), raw); got != Retry || !errors.Is(err, ErrOpen) || calls != 2 {
				t.Fatal(got, err, calls)
			}
			now = now.Add(500 * time.Millisecond)
			fault = false
			if got, err := w.Handle(context.Background(), raw); got != Acknowledge || err != nil || calls != 3 {
				t.Fatal(got, err, calls)
			}
			t.Log("two failures opened the circuit; after cooldown one success closed it")
		})
	}
}
~~~

## Check it

~~~bash
go test -race -count=1 -v ./internal/delivery
~~~

<!-- run: go test -race -count=1 -v ./internal/delivery -->
