# 02 Waiting: mutex and block profiles

## What this step teaches

- Go's two profiles for time spent **not** running.
- Why a lock's **critical section** should never contain slow work.
- Fixing the top item, then checking the knee moved.

Go can record how long goroutines wait: the **mutex profile** (contended locks, charged to whoever held them) and the **block profile** (time blocked on locks and channels, charged to the waiter). They're off by default, because they cost a little. Add a flag.

In `cmd/hotspot/main.go`, add the import:

<!-- edit: cmd/hotspot/main.go -->
~~~go
	_ "net/http/pprof" // registers /debug/pprof/ on the default mux
	"os"
~~~

to:

~~~go
	_ "net/http/pprof" // registers /debug/pprof/ on the default mux
	"os"
	"runtime"
~~~

and the flag:

<!-- edit: cmd/hotspot/main.go -->
~~~go
	auditPath := flag.String("audit", "audit.log", "audit log file")
	flag.Parse()
~~~

to:

~~~go
	auditPath := flag.String("audit", "audit.log", "audit log file")
	waits := flag.Bool("profile-waits", false, "record mutex and blocking profiles (costs a little)")
	flag.Parse()

	if *waits {
		runtime.SetMutexProfileFraction(1) // record every contended lock
		runtime.SetBlockProfileRate(1)     // record every blocking event, in nanoseconds
	}
~~~

Rate 1 records everything, which is right for a short investigation and too expensive to leave on in production.

## Run it

~~~bash
go build -o bin/ ./cmd/...
./bin/hotspot -profile-waits
~~~

Load it at 800/s, and five seconds in, fetch the profiles:

~~~bash
./bin/load -rate 800 -for 20s &
sleep 5
curl -s -o block.pb.gz http://127.0.0.1:6060/debug/pprof/block
curl -s -o mutex.pb.gz http://127.0.0.1:6060/debug/pprof/mutex
go tool pprof -top -nodecount=8 block.pb.gz
~~~

~~~text
Type: delay
Showing nodes accounting for 1272.11s, 100% of 1272.12s total
Showing top 8 nodes out of 10
      flat  flat%   sum%        cum   cum%
  1272.11s   100%   100%   1272.11s   100%  sync.(*Mutex).Lock (inline)
         0     0%   100%   1203.72s 94.62%  hotspot.(*Store).Create
         0     0%   100%     68.39s  5.38%  hotspot.(*Store).List
         0     0%   100%   1203.72s 94.62%  hotspot.Handler.func1
         0     0%   100%     68.39s  5.38%  hotspot.Handler.func2
         0     0%   100%   1272.11s   100%  net/http.(*ServeMux).ServeHTTP
         0     0%   100%   1272.12s   100%  net/http.(*Server).Serve.gowrap3
         0     0%   100%   1272.12s   100%  net/http.(*conn).serve
~~~

How to read it:
- **`flat`** is time in that function itself; **`cum`** includes what it called.
- **1,272 seconds** of waiting within seconds of starting isn't a mistake. It's the sum over all goroutines, and hundreds of them were queued at once.

Everything is in `sync.(*Mutex).Lock`, and 95% of it under `Store.Create`. Who was holding the lock? That's the mutex profile, and `-list` shows it line by line:

~~~bash
go tool pprof -list 'Store..Create' mutex.pb.gz
~~~

~~~text
Total: 1208.10s
ROUTINE ======================== hotspot.(*Store).Create in hotspot/store.go
         0   1203.92s (flat, cum) 99.65% of Total
         .          .     36:func (s *Store) Create(tenant, key, payload string) (Job, bool, error) {
         .          .     37:	s.mu.Lock()
         .          .     38:	defer s.mu.Unlock()
         .          .     39:
         .          .     40:	if err := checkTenant(tenant); err != nil {
         .          .     41:		return Job{}, false, err
         .          .     42:	}
         .          .     43:	for _, j := range s.jobs {
         .          .     44:		if j.Tenant == tenant && j.Key == key {
         .          .     45:			return j, true, nil
         .          .     46:		}
         .          .     47:	}
         .          .     48:	j := Job{ID: s.nextID, Tenant: tenant, Key: key, Payload: payload, Created: time.Now()}
         .          .     49:	s.nextID++
         .          .     50:	s.jobs = append(s.jobs, j)
         .     5.29us     51:	if err := s.writeAudit(j); err != nil {
         .          .     52:		return Job{}, false, err
         .          .     53:	}
         .   1203.92s     54:	return j, false, nil
~~~

All of the delay lands on the `return`, where the deferred `Unlock` runs: the lock is held for the **whole** function. And look at what's inside it: `checkTenant`, a 1 ms call to another service. With the lock held across a 1 ms wait, only one request can be in that section at a time, so the service can't exceed 1,000 creates a second, whatever the hardware. That's exactly the ceiling we hit, and why the CPUs sat idle.

## The fix

`checkTenant` touches no shared state, so it doesn't need the lock. In `store.go`:

<!-- edit: store.go -->
~~~go
func (s *Store) Create(tenant, key, payload string) (Job, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := checkTenant(tenant); err != nil {
		return Job{}, false, err
	}
	for _, j := range s.jobs {
~~~

to:

~~~go
func (s *Store) Create(tenant, key, payload string) (Job, bool, error) {
	// The slow check needs no shared state, so it runs before the lock:
	// a thousand requests can wait on the account service at once.
	if err := checkTenant(tenant); err != nil {
		return Job{}, false, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	for _, j := range s.jobs {
~~~

Hold that in place with a test: 100 concurrent creates, each with a 1 ms check, would take at least 100 ms if they ran one at a time. In `store_test.go`:

<!-- edit: store_test.go -->
~~~go
import (
	"io"
	"testing"
)
~~~

to:

~~~go
import (
	"fmt"
	"io"
	"sync"
	"testing"
	"time"
)
~~~

<!-- append: store_test.go -->
~~~go
func TestTheSlowCheckDoesNotHoldTheLock(t *testing.T) {
	s := NewStore(io.Discard)
	start := time.Now()
	var wg sync.WaitGroup
	for i := range 100 {
		wg.Go(func() { s.Create("acme", fmt.Sprintf("k%d", i), "x") })
	}
	wg.Wait()
	if d := time.Since(start); d > 50*time.Millisecond {
		t.Errorf("100 creates took %v: are they running one at a time?", d)
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test ./... -->

## Run it

~~~bash
go build -o bin/ ./cmd/...
./bin/hotspot
./bin/load -rate 800 -for 10s
./bin/load -rate 1500 -for 10s
./bin/load -rate 3000 -for 10s
~~~

~~~text
$ ./bin/load -rate 800 -for 10s
sent 8000 in 10.0s (800/s), errors 0
latency p50 2.22ms  p90 3.09ms  p99 6.38ms  max 65.01ms
$ ./bin/load -rate 1500 -for 10s
sent 15000 in 10.1s (1486/s), errors 0
latency p50 2.47ms  p90 5.51ms  p99 26.73ms  max 130.3ms
$ ./bin/load -rate 3000 -for 10s
sent 30000 in 20.0s (1500/s), errors 611
latency p50 1.63026s  p90 6.56083s  p99 9.32578s  max 10.00448s
~~~

800 is now fine: p50 down from over half a second to 2 ms, a change of 250 times from moving three lines. 1,500 holds too. The knee moved up to somewhere below 3,000, where it falls over again, with timeouts counted as errors.

**Break it.** Move `checkTenant` back inside the lock, and run the tests:

~~~text
--- FAIL: TestTheSlowCheckDoesNotHoldTheLock
    store_test.go:41: 100 creates took 115.548256ms: are they running one at a time?
FAIL
~~~

Put it back.

**Explain it:** What's the difference between the mutex profile and the block profile, and who does each charge the time to? Why does 1,272 seconds in a five-second run make sense? Why was throughput capped below 1,000 a second regardless of the hardware? Why couldn't a CPU profile have found this? What else, in a real service, shouldn't be held under a lock?

**Read.** The Go diagnostics guide, [*Diagnostics*](https://go.dev/doc/diagnostics), on the profiles.

---
