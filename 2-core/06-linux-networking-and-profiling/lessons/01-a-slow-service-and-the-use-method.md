# 01 A slow service, and the USE method

## What this step teaches

- A service that's slow for a reason you don't yet know.
- A load generator you can trust.
- **The USE method:** for each resource, check **utilisation**, **saturation** and **errors**, before you touch a profiler.

## The service

`hotspot` is a small version of Switchyard's API: `POST /jobs` stores a job, with an idempotency key per tenant, and `GET /jobs?tenant=` lists a tenant's jobs. Every new job writes an audit line. Before each new job, it checks the tenant with an account service, which here is a 1 ms sleep standing in for a network round trip.

Read it as you type it. Some of what's below is bad on purpose, but don't go looking yet. In real life, nobody tells you the code is broken.

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

// Store keeps jobs in memory and writes an audit line for each new one.
type Store struct {
	mu     sync.Mutex
	jobs   []Job
	nextID int64
	audit  io.Writer
}

// NewStore returns an empty store that audits to w.
func NewStore(audit io.Writer) *Store {
	return &Store{audit: audit, nextID: 1}
}

// Create stores a job, unless the tenant already submitted one with the
// same idempotency key; then it returns that one and true.
func (s *Store) Create(tenant, key, payload string) (Job, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := checkTenant(tenant); err != nil {
		return Job{}, false, err
	}
	for _, j := range s.jobs {
		if j.Tenant == tenant && j.Key == key {
			return j, true, nil
		}
	}
	j := Job{ID: s.nextID, Tenant: tenant, Key: key, Payload: payload, Created: time.Now()}
	s.nextID++
	s.jobs = append(s.jobs, j)
	if err := s.writeAudit(j); err != nil {
		return Job{}, false, err
	}
	return j, false, nil
}

// List returns a tenant's jobs, oldest first.
func (s *Store) List(tenant string) []Job {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []Job
	for _, j := range s.jobs {
		if j.Tenant == tenant {
			out = append(out, j)
		}
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
	fields := []string{
		fmt.Sprintf("id=%d", j.ID),
		" tenant=" + j.Tenant,
		" key=" + j.Key,
		fmt.Sprintf(" bytes=%d", len(j.Payload)),
		" at=" + j.Created.UTC().Format(time.RFC3339Nano),
		"\n",
	}
	for _, f := range fields {
		if _, err := io.WriteString(s.audit, f); err != nil {
			return err
		}
	}
	return nil
}
~~~

<!-- file: handler.go -->
~~~go
package hotspot

import (
	"encoding/json"
	"fmt"
	"net/http"
)

// Handler serves the jobs API.
func Handler(s *Store) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /jobs", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Tenant, Key, Payload string }
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			http.Error(w, "bad JSON", http.StatusBadRequest)
			return
		}
		j, dup, err := s.Create(in.Tenant, in.Key, in.Payload)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		status := http.StatusCreated
		if dup {
			status = http.StatusOK
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(j)
	})
	mux.HandleFunc("GET /jobs", func(w http.ResponseWriter, r *http.Request) {
		jobs := s.List(r.URL.Query().Get("tenant"))
		out := ""
		for _, j := range jobs {
			out += fmt.Sprintf("%d\t%s\t%s\n", j.ID, j.Key, j.Created.Format("15:04:05.000"))
		}
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprint(w, out)
	})
	return mux
}
~~~

The server runs Go's profiler on a separate port, bound to localhost only. Importing `net/http/pprof` registers its handlers on the default mux. **Never expose that port publicly**: profiles reveal your code and data.

<!-- file: cmd/hotspot/main.go -->
~~~go
// Command hotspot serves the jobs API, with Go's profiler on a separate,
// local-only port.
package main

import (
	"flag"
	"log"
	"net/http"
	_ "net/http/pprof" // registers /debug/pprof/ on the default mux
	"os"

	"hotspot"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8080", "API address")
	debug := flag.String("debug", "127.0.0.1:6060", "profiler address")
	auditPath := flag.String("audit", "audit.log", "audit log file")
	flag.Parse()

	f, err := os.OpenFile(*auditPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()

	go func() { log.Println(http.ListenAndServe(*debug, nil)) }()
	log.Printf("serving on %s, profiler on %s", *addr, *debug)
	log.Fatal(http.ListenAndServe(*addr, hotspot.Handler(hotspot.NewStore(f))))
}
~~~

<!-- file: store_test.go -->
~~~go
package hotspot

import (
	"io"
	"testing"
)

func TestDuplicateKeyReturnsTheSameJob(t *testing.T) {
	s := NewStore(io.Discard)
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
	if _, _, err := NewStore(io.Discard).Create("", "k", "x"); err == nil {
		t.Fatal("want an error")
	}
}
~~~

## The load generator

To measure a service, you must not fool yourself, so this generator keeps [core 02](../../02-python-runtime-and-honest-measurement/README.md)'s two rules:

- **Open loop:** requests start on a fixed schedule, whether or not earlier ones have finished, the way real users arrive.
- **Latency runs from the scheduled time,** not from the moment the request was sent. Otherwise, time spent queueing behind a stalled server vanishes from the numbers (coordinated omission).

<!-- file: load/load.go -->
~~~go
// Package load sends requests on a fixed schedule and summarises latency.
package load

import (
	"slices"
	"time"
)

// Result is one request's outcome. Latency is measured from when the
// request was scheduled, not when it was sent, so time spent waiting to be
// sent counts (no coordinated omission).
type Result struct {
	Latency time.Duration
	Status  int // 0 if the request failed before a response
}

// Summary is what a run reports.
type Summary struct {
	Requests, Errors   int
	P50, P90, P99, Max time.Duration
}

// Summarise computes percentiles over successful results (status < 500).
func Summarise(results []Result) Summary {
	s := Summary{Requests: len(results)}
	var lat []time.Duration
	for _, r := range results {
		if r.Status == 0 || r.Status >= 500 {
			s.Errors++
			continue
		}
		lat = append(lat, r.Latency)
	}
	if len(lat) == 0 {
		return s
	}
	slices.Sort(lat)
	s.P50, s.P90, s.P99 = Percentile(lat, 50), Percentile(lat, 90), Percentile(lat, 99)
	s.Max = lat[len(lat)-1]
	return s
}

// Percentile returns the nearest-rank p-th percentile of sorted, which must
// not be empty.
func Percentile(sorted []time.Duration, p float64) time.Duration {
	rank := int(p/100*float64(len(sorted))+0.999999) - 1 // ceil(p/100·n) − 1
	return sorted[max(0, min(rank, len(sorted)-1))]
}
~~~

<!-- file: load/load_test.go -->
~~~go
package load

import (
	"testing"
	"time"
)

func ms(n int) time.Duration { return time.Duration(n) * time.Millisecond }

func TestPercentile(t *testing.T) {
	var lat []time.Duration
	for i := 1; i <= 100; i++ {
		lat = append(lat, ms(i))
	}
	for p, want := range map[float64]time.Duration{50: ms(50), 90: ms(90), 99: ms(99), 100: ms(100)} {
		if got := Percentile(lat, p); got != want {
			t.Errorf("Percentile(1..100 ms, %v) = %v, want %v", p, got, want)
		}
	}
	if got := Percentile([]time.Duration{ms(7)}, 99); got != ms(7) {
		t.Errorf("one value: got %v", got)
	}
}

func TestSummariseCountsErrorsApart(t *testing.T) {
	s := Summarise([]Result{{ms(1), 201}, {ms(2), 200}, {ms(900), 0}, {ms(5), 503}})
	if s.Requests != 4 || s.Errors != 2 || s.Max != ms(2) {
		t.Errorf("Summarise = %+v; want 4 requests, 2 errors, max 2ms", s)
	}
}
~~~

<!-- file: cmd/load/main.go -->
~~~go
// Command load sends jobs to hotspot at a fixed rate and prints latency
// percentiles, measured from each request's scheduled time.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"net/http"
	"sync"
	"time"

	"hotspot/load"
)

func main() {
	url := flag.String("url", "http://127.0.0.1:8080", "hotspot's address")
	rate := flag.Int("rate", 500, "requests a second")
	dur := flag.Duration("for", 10*time.Second, "how long to send")
	keys := flag.Int("keys", 1_000_000, "distinct idempotency keys per tenant (fewer means more duplicates)")
	lists := flag.Float64("lists", 0.05, "fraction of requests that list a tenant's jobs")
	flag.Parse()

	client := &http.Client{
		Timeout:   10 * time.Second,
		Transport: &http.Transport{MaxIdleConnsPerHost: 1024},
	}
	rng := rand.New(rand.NewPCG(1, 2)) // the same requests every run
	n := int(float64(*rate) * dur.Seconds())
	interval := time.Second / time.Duration(*rate)
	results := make([]load.Result, n)

	var wg sync.WaitGroup
	start := time.Now()
	for i := range n {
		scheduled := start.Add(time.Duration(i) * interval)
		time.Sleep(time.Until(scheduled))
		tenant := fmt.Sprintf("t%d", rng.IntN(10))
		var req *http.Request
		if rng.Float64() < *lists {
			req, _ = http.NewRequest("GET", *url+"/jobs?tenant="+tenant, nil)
		} else {
			body, _ := json.Marshal(map[string]string{
				"tenant": tenant, "key": fmt.Sprintf("k%d", rng.IntN(*keys)), "payload": "x",
			})
			req, _ = http.NewRequest("POST", *url+"/jobs", bytes.NewReader(body))
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, err := client.Do(req)
			if err != nil {
				results[i] = load.Result{Latency: time.Since(scheduled)}
				return
			}
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			results[i] = load.Result{Latency: time.Since(scheduled), Status: resp.StatusCode}
		}()
	}
	wg.Wait()
	s := load.Summarise(results)
	elapsed := time.Since(start)
	log.SetFlags(0)
	log.Printf("sent %d in %.1fs (%.0f/s), errors %d", s.Requests, elapsed.Seconds(), float64(s.Requests)/elapsed.Seconds(), s.Errors)
	log.Printf("latency p50 %v  p90 %v  p99 %v  max %v",
		s.P50.Round(10*time.Microsecond), s.P90.Round(10*time.Microsecond),
		s.P99.Round(10*time.Microsecond), s.Max.Round(10*time.Microsecond))
}
~~~

Build it and run the tests:

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go build -o bin/ ./cmd/... -->

~~~bash
go vet ./... && go test ./...
go build -o bin/ ./cmd/...
~~~

## Run it

In one terminal, start the service:

~~~bash
./bin/hotspot
~~~

In another, load it at rising rates:

~~~bash
./bin/load -rate 200 -for 10s
./bin/load -rate 500 -for 10s
./bin/load -rate 800 -for 10s
~~~

~~~text
$ ./bin/load -rate 200 -for 10s
sent 2000 in 10.0s (200/s), errors 0
latency p50 2.31ms  p90 2.86ms  p99 3.21ms  max 15.89ms
$ ./bin/load -rate 500 -for 10s
sent 5000 in 10.0s (500/s), errors 0
latency p50 2.15ms  p90 2.79ms  p99 3.16ms  max 8.65ms
$ ./bin/load -rate 800 -for 10s
sent 8000 in 11.2s (717/s), errors 0
latency p50 563.56ms  p90 1.10872s  p99 1.1524s  max 1.15803s
~~~

Fine at 500 requests a second, with a p99 of 3 ms. At 800, a p50 of half a second, and the generator couldn't even finish on time. Somewhere between them is a **knee**: the point where queues start to grow without bound.

## USE, before any profiler

Why? The tempting move is to open the code. Don't. First ask which **resource** is the limit. Brendan Gregg's USE method goes through each resource:

| Resource | Utilisation (how busy?) | Saturation (how much is queued?) | Errors |
|---|---|---|---|
| CPU | `top`, `vmstat`'s `us` and `sy` | `vmstat`'s `r` column; load average | |
| Memory | `free` | swapping (`si`, `so`) | OOM kills in `dmesg` |
| Disk | `iostat` | queue length | `dmesg` |
| Network | `ss`, `ip -s link` | retransmits | drops |

Keep the load running at 800/s, and in a third terminal look:

~~~bash
vmstat 1 5
~~~

~~~text
procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
 0  0 229968 5580148  86840 1045928  353  381 16815  2637 14813   22 12  8 79  1  0  0
 1  0 229968 5573332  86840 1045972    0    0     0     0 22661 38339  3  4 93  0  0  0
 1  0 229968 5568108  86848 1045972    0    0     0     0 21319 35838  3  4 93  0  0  0
 0  0 229968 5563508  86848 1046036    0    0     0     0 25511 43807  6  4 90  0  0  0
 2  0 229968 5560860  86848 1046036    0    0     0    44 24225 41580  4  4 91  0  0  0
~~~

Ignore the first line, which is an average since boot. Then:

- `id` is **about 92%**: the machine is nearly idle.
- `r`, the run queue, is 0–2 on a 16-CPU machine: nothing is waiting for a CPU.
- `wa` is 0: nothing is waiting for a disk.
- `si` and `so` are 0: no swapping.

And the process itself:

~~~bash
top -b -n 1 -p $(pgrep -x hotspot) | tail -2
grep -E 'Threads|ctxt_switches' /proc/$(pgrep -x hotspot)/status
~~~

~~~text
    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
1448896 techiee+  20   0 2747756  52348   7516 S  70.0   0.7   0:17.45 hotspot
Threads:	21
voluntary_ctxt_switches:	11107
nonvoluntary_ctxt_switches:	11
~~~

Read that carefully. The process uses 70% of **one** core out of 16. And **voluntary** context switches outnumber involuntary ones 11,107 to 11. A voluntary switch means a thread gave up the CPU because it had nothing to do: it went to sleep waiting for something. An involuntary one means the scheduler pushed it off.

**So nothing is saturated, and yet requests wait for a second.** The service isn't computing; it's **waiting**. When no resource is full but throughput has hit a ceiling, the limit is usually inside the program: something that only one thing can do at a time. That rules out most guesses, and it tells you the next tool. A CPU profile would be useless here, because it only sees time spent running.

**Explain it:** Why is the first line of `vmstat` different from the rest? What's the difference between utilisation and saturation? What does a mostly idle machine with a latency problem tell you? Why did the generator take 11.2 seconds to send 10 seconds' worth of requests? Which guess would you have made before seeing `vmstat`?

**Read.** Brendan Gregg, [*The USE Method*](https://www.brendangregg.com/usemethod.html), and [*Linux Performance Analysis in 60,000 Milliseconds*](https://netflixtechblog.com/linux-performance-analysis-in-60-000-milliseconds-accc10403c55).

---
