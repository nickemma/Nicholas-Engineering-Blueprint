# 07 Memory and the garbage collector

## What this step teaches

- Heap profiles: what's held, and what's allocated.
- Reading `gctrace`.
- `GOGC` and `GOMEMLIMIT`, and what they trade.
- Unbounded growth, and what a memory limit does to it.

Runs so far have been short. Look at what happens over time, with fewer lists (`-lists 0.01`) so memory, not listing, is the question. `GODEBUG=gctrace=1` prints a line for every garbage collection:

~~~bash
GODEBUG=gctrace=1 ./bin/hotspot 2> gc.txt &
./bin/load -rate 3000 -for 40s -lists 0.01
grep -c '^gc ' gc.txt
grep '^gc ' gc.txt | tail -1
~~~

~~~text
sent 120000 in 40.0s (2998/s), errors 0
latency p50 2.24ms  p90 3.24ms  p99 10.5ms  max 35.82ms
$ grep -c '^gc ' gc.txt
344
gc 344 @40.913s 0%: 0.14+5.2+0.11 ms clock, 2.3+0/11/12+1.8 ms cpu, 46->47->24 MB, 48 MB goal, 0 MB stacks, 0 MB globa
~~~

Read the last line:
- **`gc 344 @40.913s 0%`:** the 344th collection, 41 seconds in; 0% of the CPU has gone on GC so far.
- **`46->47->24 MB`:** the heap was 46 MB when it started, 47 MB when it ended, and 24 MB of that is **live**, still in use.
- **`48 MB goal`:** the next collection starts around 48 MB: twice the live heap, because `GOGC` defaults to 100 (let it grow 100% before collecting).

The collector is healthy. But sampling the process's memory (`VmRSS` in `/proc/PID/status`) every 10 seconds tells another story:

~~~text
t=10s rss=23MB
t=20s rss=32MB
t=30s rss=47MB
t=40s rss=64MB
~~~

It only goes up, because the store keeps every job forever. Two profiles show memory. `inuse_space` is what's held now; `alloc_space` is everything allocated since the start, which is what makes the collector work:

~~~bash
curl -s -o heap.pb.gz http://127.0.0.1:6060/debug/pprof/heap
go tool pprof -sample_index=inuse_space -top -nodecount=3 bin/hotspot heap.pb.gz
go tool pprof -sample_index=alloc_space -top -nodecount=3 bin/hotspot heap.pb.gz
~~~

~~~text
inuse_space
      flat  flat%   sum%        cum   cum%
19275.74kB 64.69% 64.69% 19275.74kB 64.69%  hotspot.(*Store).Create
 4096.06kB 13.75% 78.44%  4096.06kB 13.75%  encoding/json.(*decodeState).literalStore
 2321.19kB  7.79% 86.23%  2321.19kB  7.79%  hotspot.(*Store).List

alloc_space
      flat  flat%   sum%        cum   cum%
 2338.67MB 72.60% 72.60%  2338.67MB 72.60%  hotspot.(*Store).List
     268MB  8.32% 80.92%  2722.68MB 84.52%  hotspot.Handler.func2
  111.50MB  3.46% 84.38%   111.50MB  3.46%  time.Time.Format
~~~

- **Held:** `Store.Create`, the jobs. No surprise.
- **Allocated:** `Store.List` allocated **73% of all bytes**, from 1% of requests. It copies a tenant's jobs into a slice grown by `append`, regrowing and copying as it goes, after scanning every job in the store.

## The two knobs

**`GOGC`** trades memory for CPU: a higher value lets the heap grow further between collections. Same load, 40 seconds:

| `GOGC` | Collections | p99 | Memory at 40 s |
|---|---|---|---|
| 25 | 1,656 | 43.4 ms | 49 MB |
| 100 (default) | 344 | 10.5 ms | 64 MB |
| 400 | 70 | 8.1 ms | 155 MB |

**`GOMEMLIMIT`** gives the runtime a target for its total memory. Collect more often near it. A generous limit with `GOGC=off` is the recommended setup when you know the machine's size: don't collect at all until you must.

| Setting | Collections | p99 | Memory |
|---|---|---|---|
| `GOGC=off GOMEMLIMIT=500MiB`, 40 s | 7 | 6.9 ms | 475 MB |

Seven collections instead of 344. So what happens when the limit is too small for the **live** data? This store's live data only grows, so give it 20 MiB and 60 seconds:

~~~bash
GOMEMLIMIT=20MiB GODEBUG=gctrace=1 ./bin/hotspot 2> gc.txt
./bin/load -rate 3000 -for 60s -lists 0.01
~~~

~~~text
sent 180000 in 71.1s (2532/s), errors 76197
latency p50 22.99ms  p90 2.41217s  p99 9.58756s  max 12.21688s
~~~

~~~text
t=10s rss=20MB
t=20s rss=51MB
t=30s rss=60MB
t=40s rss=413MB
t=50s rss=625MB
t=60s rss=619MB
~~~

A **death spiral**. Once live data reaches the limit, the collector runs constantly and can't free anything, because it's all live. Its last line, with 375 MB live, 19% of the CPU gone on collection, and 57 MB of goroutine stacks, says so:

~~~text
gc 2627 @72.030s 19%: 0.18+52+0.40 ms clock, 3.0+2.7/192/456+6.4 ms cpu, 381->387->375 MB, 380 MB goal, 57 MB stacks, 0 MB globa
~~~

Requests slow down, so they pile up, so memory rises, so the collector works harder. 42% of requests failed. And see the memory: **625 MB against a limit of 20**. `GOMEMLIMIT` is a soft limit. The runtime caps the collector at about half the CPU rather than stop the program completely. It's a target, not a wall: **it can't save you from a leak**, it only changes how you die.

## The fix: bound what you keep

The real problem is the unbounded store. A fixed-size **ring** keeps the most recent `keep` jobs, and each new job overwrites the oldest. An index by tenant fixes `List` too: it no longer scans anyone else's jobs, and it knows the slice size up front. Replace `store.go`:

<!-- file: store.go -->
~~~go
// Package hotspot is a small jobs service with performance problems
// planted in it, for the Performance Bridge to find.
package hotspot

import (
	"fmt"
	"io"
	"sync"
	"time"
)

// Job is one submitted job.
type Job struct {
	ID      int64     `json:"id"`
	Tenant  string    `json:"tenant"`
	Key     string    `json:"key"`
	Payload string    `json:"payload"`
	Created time.Time `json:"created"`
}

// Store keeps the most recent jobs in memory and writes an audit line for
// each new one. Old jobs fall off a fixed-size ring, so memory is bounded;
// a duplicate older than the ring counts as a new job.
type Store struct {
	mu       sync.Mutex
	ring     []Job            // job i lives at ring[(i-1) % len(ring)]
	byKey    map[string]int64 // tenant + "\x00" + key → job ID
	byTenant map[string][]int64
	nextID   int64
	audit    io.Writer
}

// NewStore returns an empty store that keeps the last keep jobs and audits
// to w.
func NewStore(audit io.Writer, keep int) *Store {
	return &Store{
		audit:    audit,
		nextID:   1,
		ring:     make([]Job, keep),
		byKey:    make(map[string]int64),
		byTenant: make(map[string][]int64),
	}
}

// Create stores a job, unless the tenant already submitted one with the
// same idempotency key; then it returns that one and true.
func (s *Store) Create(tenant, key, payload string) (Job, bool, error) {
	// The slow check needs no shared state, so it runs before the lock:
	// a thousand requests can wait on the account service at once.
	if err := checkTenant(tenant); err != nil {
		return Job{}, false, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	k := tenant + "\x00" + key // \x00 can't appear in either, so keys can't collide
	if id, ok := s.byKey[k]; ok {
		return *s.slot(id), true, nil
	}
	j := Job{ID: s.nextID, Tenant: tenant, Key: key, Payload: payload, Created: time.Now()}
	s.nextID++
	s.evict(s.slot(j.ID))
	*s.slot(j.ID) = j
	s.byKey[k] = j.ID
	s.byTenant[tenant] = append(s.byTenant[tenant], j.ID)
	if err := s.writeAudit(j); err != nil {
		return Job{}, false, err
	}
	return j, false, nil
}

// slot returns where job id lives in the ring.
func (s *Store) slot(id int64) *Job { return &s.ring[(id-1)%int64(len(s.ring))] }

// evict forgets the job in old, if there is one. The oldest job is always
// first in its tenant's list, so this is O(1).
func (s *Store) evict(old *Job) {
	if old.ID == 0 {
		return // an empty slot
	}
	delete(s.byKey, old.Tenant+"\x00"+old.Key)
	s.byTenant[old.Tenant] = s.byTenant[old.Tenant][1:]
}

// List returns a tenant's retained jobs, oldest first.
func (s *Store) List(tenant string) []Job {
	s.mu.Lock()
	defer s.mu.Unlock()
	ids := s.byTenant[tenant]
	out := make([]Job, len(ids)) // sized once: no regrowing, no scanning others' jobs
	for i, id := range ids {
		out[i] = *s.slot(id)
	}
	return out
}

// checkTenant stands in for a call to an account service: it takes about
// a millisecond, like a network round trip.
func checkTenant(tenant string) error {
	if tenant == "" {
		return fmt.Errorf("tenant is required")
	}
	time.Sleep(time.Millisecond)
	return nil
}

func (s *Store) writeAudit(j Job) error {
	// Build the whole line, then write it once: one system call per job,
	// and a crash can't leave half a line.
	line := fmt.Appendf(nil, "id=%d tenant=%s key=%s bytes=%d at=%s\n",
		j.ID, j.Tenant, j.Key, len(j.Payload), j.Created.UTC().Format(time.RFC3339Nano))
	_, err := s.audit.Write(line)
	return err
}
~~~

- **There's a trade here, and it's in the comment:** a duplicate older than the ring counts as a new job. Keep more than your longest retry window (you met this in [Phase 3](../../03-docker-and-postgres/README.md)'s idempotency keys).
- **`List` still copies under the lock,** on purpose: it must not hold the lock while writing to a slow client. That's step 2's lesson.

Add the flag in `cmd/hotspot/main.go`:

<!-- edit: cmd/hotspot/main.go -->
~~~go
	waits := flag.Bool("profile-waits", false, "record mutex and blocking profiles (costs a little)")
~~~

to:

~~~go
	keep := flag.Int("keep", 50_000, "how many recent jobs to keep in memory")
	waits := flag.Bool("profile-waits", false, "record mutex and blocking profiles (costs a little)")
~~~

<!-- edit: cmd/hotspot/main.go -->
~~~go
hotspot.Handler(hotspot.NewStore(f))
~~~

to:

~~~go
hotspot.Handler(hotspot.NewStore(f, *keep))
~~~

And replace `store_test.go`. The new test checks that the ring, both indexes, and the eviction agree:

<!-- file: store_test.go -->
~~~go
package hotspot

import (
	"fmt"
	"io"
	"sync"
	"testing"
	"time"
)

func TestDuplicateKeyReturnsTheSameJob(t *testing.T) {
	s := NewStore(io.Discard, 10)
	a, dup, err := s.Create("acme", "k1", "x")
	if err != nil || dup {
		t.Fatalf("first create: dup=%v err=%v", dup, err)
	}
	b, dup, _ := s.Create("acme", "k1", "y")
	if !dup || b.ID != a.ID {
		t.Fatalf("second create: dup=%v id=%d, want true and %d", dup, b.ID, a.ID)
	}
	if _, dup, _ := s.Create("globex", "k1", "z"); dup {
		t.Fatal("another tenant's key must not collide")
	}
}

func TestEmptyTenantIsRefused(t *testing.T) {
	if _, _, err := NewStore(io.Discard, 10).Create("", "k", "x"); err == nil {
		t.Fatal("want an error")
	}
}

func TestTheSlowCheckDoesNotHoldTheLock(t *testing.T) {
	s := NewStore(io.Discard, 1000)
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

func TestOldJobsFallOffTheRing(t *testing.T) {
	s := NewStore(io.Discard, 3)
	for i := range 5 {
		s.Create(fmt.Sprintf("t%d", i%2), fmt.Sprintf("k%d", i), "x")
	}
	// Jobs 1 and 2 are gone; 3, 4, 5 remain. t0 had 1, 3, 5 and t1 had 2, 4.
	got := []int64{}
	for _, j := range s.List("t0") {
		got = append(got, j.ID)
	}
	if fmt.Sprint(got) != "[3 5]" {
		t.Errorf("t0's jobs = %v, want [3 5]", got)
	}
	if jobs := s.List("t1"); len(jobs) != 1 || jobs[0].ID != 4 {
		t.Errorf("t1's jobs = %+v, want only 4", jobs)
	}
	if len(s.byKey) != 3 {
		t.Errorf("byKey holds %d keys, want 3: evicted keys must go", len(s.byKey))
	}
	// An evicted key is new again; a retained one is still a duplicate.
	if _, dup, _ := s.Create("t0", "k0", "x"); dup {
		t.Error("k0 fell off the ring, so it should count as new")
	}
	if _, dup, _ := s.Create("t0", "k4", "x"); !dup {
		t.Error("k4 is retained, so it should be a duplicate")
	}
}

func TestAuditIsOneWritePerJob(t *testing.T) {
	var w countingWriter
	s := NewStore(&w, 10)
	s.Create("acme", "k1", "x")
	s.Create("acme", "k2", "x")
	if w != 2 {
		t.Errorf("%d writes for 2 jobs", w)
	}
}

type countingWriter int

func (w *countingWriter) Write(p []byte) (int, error) { *w++; return len(p), nil }
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race ./... && go build -o bin/ ./cmd/... -->

## Run it

Now 60 seconds, at the same rate:

~~~text
sent 180000 in 60.1s (2997/s), errors 0
latency p50 2.26ms  p90 3.6ms  p99 16.97ms  max 134.93ms
t=10s rss=26MB
t=20s rss=42MB
t=30s rss=43MB
t=40s rss=45MB
t=50s rss=44MB
t=60s rss=44MB
~~~

Flat at about 44 MB. And the setting that killed the service before, with a limit set sensibly above the bounded live data:

~~~bash
GOMEMLIMIT=40MiB ./bin/hotspot
~~~

~~~text
sent 180000 in 60.0s (2998/s), errors 0
latency p50 2.22ms  p90 3.28ms  p99 7.72ms  max 45.35ms
t=10s rss=29MB
t=20s rss=36MB
t=30s rss=38MB
t=40s rss=40MB
t=50s rss=39MB
t=60s rss=39MB
~~~

No errors, p99 under 8 ms. A memory limit works when the live data fits under it.

**Break it.** In `evict`, remove the `delete(s.byKey, ...)` line, and run the tests:

~~~text
--- FAIL: TestOldJobsFallOffTheRing (0.01s)
    store_test.go:62: byKey holds 5 keys, want 3: evicted keys must go
    store_test.go:66: k0 fell off the ring, so it should count as new
FAIL
FAIL	hotspot	0.033s
FAIL
~~~

That's a leak hidden inside the fix: the ring is bounded, but the map would grow forever. Put it back.

**Explain it:** What's the difference between `inuse_space` and `alloc_space`? In `46->47->24 MB`, what's each number, and how is the goal derived? What does `GOGC` trade? Why does a too-small `GOMEMLIMIT` get worse over time? Why did memory reach 625 MB under a 20 MiB limit? Why can't a memory limit fix a leak? What's the cost of the ring?

**Read.** Go, [*A Guide to the Go Garbage Collector*](https://go.dev/doc/gc-guide).

---
