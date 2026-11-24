// Command driver is the core 01 gate's client. It sends state changes to a
// running Switchyard from many clients at once, waits for the system to
// settle, and checks that it converged. It prints one line per check and
// exits 1 if any fails.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

type job struct {
	ID    int64  `json:"id"`
	State string `json:"state"`
}

var client = &http.Client{Timeout: 10 * time.Second}

// record is what the driver remembers about each job it created.
type record struct {
	id        int64
	cancelled bool // a cancel answered 200
}

type result struct {
	mu         sync.Mutex
	jobs       map[int64]*record
	sameKeyBad []string
	unexpected []string
	changes    atomic.Int64
	creates    atomic.Int64
	repeats    atomic.Int64
	cancels    atomic.Int64
	cancelled  atomic.Int64
}

func (r *result) fail(list *[]string, format string, args ...any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(*list) < 5 {
		*list = append(*list, fmt.Sprintf(format, args...))
	}
}

// create sends POST /jobs with an idempotency key, retrying 503s and 409s
// with the same key, and returns the job's ID.
func create(base, key, body string) (int64, bool, error) {
	for attempt := 0; attempt < 50; attempt++ {
		req, _ := http.NewRequest(http.MethodPost, base+"/jobs", bytes.NewBufferString(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Idempotency-Key", key)
		resp, err := client.Do(req)
		if err != nil {
			return 0, false, err
		}
		data, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		switch resp.StatusCode {
		case http.StatusCreated:
			var j job
			if err := json.Unmarshal(data, &j); err != nil {
				return 0, false, fmt.Errorf("decode %q: %w", data, err)
			}
			return j.ID, resp.Header.Get("Idempotent-Replayed") == "true", nil
		case http.StatusServiceUnavailable, http.StatusConflict:
			time.Sleep(time.Duration(20+rand.IntN(80)) * time.Millisecond)
		default:
			return 0, false, fmt.Errorf("POST /jobs: %d %s", resp.StatusCode, data)
		}
	}
	return 0, false, fmt.Errorf("POST /jobs: still busy after 50 tries")
}

func get(base, path string, into any) (int, error) {
	resp, err := client.Get(base + path)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	return resp.StatusCode, json.NewDecoder(resp.Body).Decode(into)
}

func main() {
	base := flag.String("url", "http://127.0.0.1:18080", "Switchyard's HTTP address")
	total := flag.Int("changes", 10000, "state changes to send")
	clients := flag.Int("clients", 32, "concurrent clients")
	settle := flag.Duration("settle", 120*time.Second, "how long to wait for every job to finish")
	flag.Parse()

	res := &result{jobs: make(map[int64]*record)}
	start := time.Now()
	var wg sync.WaitGroup
	for c := range *clients {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var mine []int64
			for n := 0; ; n++ {
				if res.changes.Add(1) > int64(*total) {
					return
				}
				switch roll := rand.IntN(100); {
				case roll < 15 && len(mine) > 0: // cancel one of this client's jobs
					id := mine[rand.IntN(len(mine))]
					resp, err := client.Post(fmt.Sprintf("%s/jobs/%d/cancel", *base, id), "application/json", nil)
					if err != nil {
						res.fail(&res.unexpected, "cancel %d: %v", id, err)
						continue
					}
					io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
					res.cancels.Add(1)
					switch resp.StatusCode {
					case http.StatusOK:
						res.cancelled.Add(1)
						res.mu.Lock()
						res.jobs[id].cancelled = true
						res.mu.Unlock()
					case http.StatusConflict: // it had already finished
					default:
						res.fail(&res.unexpected, "cancel %d: status %d, want 200 or 409", id, resp.StatusCode)
					}
				default: // create, and sometimes send the same request again
					key := "gate-" + strconv.Itoa(c) + "-" + strconv.Itoa(n)
					body := fmt.Sprintf(`{"description":"gate %d/%d","duration_ms":%d}`, c, n, rand.IntN(21))
					id, _, err := create(*base, key, body)
					if err != nil {
						res.fail(&res.unexpected, "create: %v", err)
						continue
					}
					res.creates.Add(1)
					res.mu.Lock()
					res.jobs[id] = &record{id: id}
					res.mu.Unlock()
					mine = append(mine, id)
					if roll < 35 { // a client that didn't hear the answer retries
						if res.changes.Add(1) > int64(*total) {
							return
						}
						again, replayed, err := create(*base, key, body)
						res.repeats.Add(1)
						if err != nil || again != id || !replayed {
							res.fail(&res.sameKeyBad, "key %s: first job %d, retry got job %d (replayed=%v, err=%v)", key, id, again, replayed, err)
						}
					}
				}
			}
		}()
	}
	wg.Wait()
	sent := time.Since(start)
	fmt.Printf("sent %d state changes in %.1f s: %d creates, %d repeated with the same key, %d cancels (%d accepted)\n",
		res.creates.Load()+res.repeats.Load()+res.cancels.Load(), sent.Seconds(),
		res.creates.Load(), res.repeats.Load(), res.cancels.Load(), res.cancelled.Load())

	// Wait for every job to reach a final state.
	final := map[string]bool{"completed": true, "failed": true, "cancelled": true}
	states := make(map[int64]string, len(res.jobs))
	deadline := time.Now().Add(*settle)
	for {
		open := 0
		for id := range res.jobs {
			if final[states[id]] {
				continue
			}
			var j job
			if code, err := get(*base, "/jobs/"+strconv.FormatInt(id, 10), &j); err != nil || code != http.StatusOK {
				states[id] = "missing"
				open++
				continue
			}
			states[id] = j.State
			if !final[j.State] {
				open++
			}
		}
		if open == 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	settled := time.Since(start)

	count := map[string]int{}
	var notFinal, cancelBroken, effectBroken []string
	for id, rec := range res.jobs {
		s := states[id]
		count[s]++
		if !final[s] && len(notFinal) < 5 {
			notFinal = append(notFinal, fmt.Sprintf("job %d is %s", id, s))
		}
		if rec.cancelled && s != "cancelled" && len(cancelBroken) < 5 {
			cancelBroken = append(cancelBroken, fmt.Sprintf("job %d was cancelled (200), but ended %s", id, s))
		}
		var e struct{ Effects int }
		code, err := get(*base, "/effects/"+strconv.FormatInt(id, 10), &e)
		want := 0
		if s == "completed" {
			want = 1
		}
		if (err != nil || code != http.StatusOK || e.Effects != want) && len(effectBroken) < 5 {
			effectBroken = append(effectBroken, fmt.Sprintf("job %d is %s with %d effects (status %d, %v), want %d", id, s, e.Effects, code, err, want))
		}
	}
	client.CloseIdleConnections()
	fmt.Printf("settled after %.1f s: %d jobs: %d completed, %d cancelled, %d failed\n",
		settled.Seconds(), len(res.jobs), count["completed"], count["cancelled"], count["failed"])

	ok := true
	check := func(name string, problems []string) {
		if len(problems) == 0 {
			fmt.Println("PASS  " + name)
			return
		}
		ok = false
		fmt.Println("FAIL  " + name)
		for _, p := range problems {
			fmt.Println("        " + p)
		}
	}
	check("every request got an expected answer", res.unexpected)
	check("a repeated request with the same key returned the same job", res.sameKeyBad)
	check("every job reached a final state (none lost, none stuck)", notFinal)
	check("every job cancelled with 200 ended cancelled, never completed", cancelBroken)
	check("every completed job has exactly one effect; every other job, none", effectBroken)
	if !ok {
		os.Exit(1)
	}
}
