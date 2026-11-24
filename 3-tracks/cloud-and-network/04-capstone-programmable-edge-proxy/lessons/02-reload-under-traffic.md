# 02 Reload and roll back under traffic

> Programmable edge proxy capstone · Week 1 · Builds on lesson 01

## The problem

A controlled pair proves ordering for two requests. A paced workload tests continuity while updates and ordinary requests overlap.

## The mental model

Use a monotonic clock for scheduled arrivals, dispatches, completions, and updates. A request that finishes before an update begins has one possible route. A request that starts after its acknowledgement has the new route until the next update can overlap. The actual publication lies inside the measured management window.

## The pattern

Schedule a small workload with room below the driver cap. Keep all arrivals, including those the driver cannot launch. Check the digest and generation after each update, and check the served origin after a rejection. Record process RSS on a fixed sampling interval.

## Build it

### Step 1 — Make the timelines comparable

Measure a request from both scheduled arrival and actual launch so scheduler lag remains visible. Treat work overlapping a publication window as eligible for either observed route.

<details>
<summary>Implementation</summary>

Create `control/reload_test.go`.

<!-- file: control/reload_test.go -->
~~~go
package control

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type updateWindow struct {
	Attempt uint64 `json:"attempt"`
	Active  uint64 `json:"active"`
	Slot    int    `json:"slot"`
	BeginUS int64  `json:"begin_us"`
	AckUS   int64  `json:"ack_us"`
	Result  string `json:"result"`
}

type reloadSample struct {
	ID          int    `json:"id"`
	ScheduledUS int64  `json:"scheduled_us"`
	StartedUS   int64  `json:"started_us"`
	FinishedUS  int64  `json:"finished_us"`
	Origin      int    `json:"origin"`
	Outcome     string `json:"outcome"`
}

type rssSample struct {
	AtUS int64  `json:"at_us"`
	KiB  uint64 `json:"kib"`
}

type reloadReport struct {
	OfferedRPS int            `json:"offered_rps"`
	WindowUS   int64          `json:"window_us"`
	ElapsedUS  int64          `json:"elapsed_us"`
	Updates    []updateWindow `json:"updates"`
	Requests   []reloadSample `json:"requests"`
	RSS        []rssSample    `json:"rss"`
}

func readRSS(pid int) (uint64, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		return 0, err
	}
	for line := range strings.SplitSeq(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 3 && fields[0] == "VmRSS:" && fields[2] == "kB" {
			return strconv.ParseUint(fields[1], 10, 64)
		}
	}
	return 0, fmt.Errorf("VmRSS missing from process status")
}

func (c capstone) traffic(t *testing.T, start time.Time, duration time.Duration, rate int) ([]reloadSample, int64) {
	transport := &http.Transport{
		MaxIdleConnsPerHost: 64, MaxConnsPerHost: 64, IdleConnTimeout: 5 * time.Second,
		DisableCompression: true,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 2 * time.Second}
	samples := make([]reloadSample, int(duration/time.Second)*rate)
	slots := make(chan struct{}, 64)
	var active sync.WaitGroup
	for id := range samples {
		offset := time.Duration(id) * time.Second / time.Duration(rate)
		time.Sleep(time.Until(start.Add(offset)))
		row := &samples[id]
		row.ID, row.ScheduledUS = id, offset.Microseconds()
		select {
		case slots <- struct{}{}:
			active.Go(func() {
				row.StartedUS = time.Since(start).Microseconds()
				origin, err := c.origin(t.Context(), client, objectPath)
				row.Origin, row.Outcome = origin, "ok"
				if err != nil {
					row.Outcome = err.Error()
				}
				row.FinishedUS = time.Since(start).Microseconds()
				<-slots
			})
		default:
			row.StartedUS = time.Since(start).Microseconds()
			row.Origin, row.Outcome, row.FinishedUS = -1, "driver_full", row.StartedUS
		}
	}
	active.Wait()
	time.Sleep(time.Until(start.Add(duration)))
	return samples, time.Since(start).Microseconds()
}

func validOrigin(row reloadSample, updates []updateWindow) bool {
	allowed := []int{0}
	for _, update := range updates {
		if update.Result != "applied" {
			continue
		}
		if row.FinishedUS < update.BeginUS {
			break
		}
		if row.StartedUS > update.AckUS {
			allowed = []int{update.Slot}
		} else {
			allowed = append(allowed, update.Slot)
		}
	}
	return slices.Contains(allowed, row.Origin)
}

func (c capstone) update(t *testing.T, start time.Time, generation uint64, slot int, wantReject bool) updateWindow {
	t.Helper()
	desired := NewSnapshot(generation, [2]int{slot, 1 - slot})
	c.origins[slot].healthy.Store(!wantReject)
	defer c.origins[slot].healthy.Store(true)
	row := updateWindow{Attempt: generation, Slot: slot, BeginUS: time.Since(start).Microseconds()}
	ack, err := c.controller.Apply(t.Context(), desired)
	row.AckUS = time.Since(start).Microseconds()
	if wantReject {
		if err == nil || !strings.Contains(err.Error(), "unhealthy") {
			t.Fatalf("unhealthy generation accepted: %+v %v", ack, err)
		}
		row.Result = "rejected"
	} else {
		if err != nil || ack.Result != "applied" || ack.Snapshot != desired {
			t.Fatalf("publish generation %d: %+v %v", generation, ack, err)
		}
		row.Result = "applied"
	}
	readback, err := c.controller.Send(t.Context(), Command{Op: "status"})
	expected := desired
	if wantReject {
		expected = NewSnapshot(generation-1, [2]int{1 - slot, slot})
	}
	if err != nil || readback.Result != "current" || readback.Snapshot != expected {
		t.Fatalf("generation readback: %+v %v", readback, err)
	}
	row.Active = readback.Snapshot.Generation
	c.assertOrigin(t, readback.Snapshot.Order[0])
	return row
}

func measureTraffic(t *testing.T, slots []int) {
	t.Helper()
	c := startCapstone(t)
	const rate, duration = 120, 2 * time.Second
	c.assertOrigin(t, 0)

	// Give both goroutines time to initialize before the first scheduled request.
	start := time.Now().Add(30 * time.Millisecond)
	var workers sync.WaitGroup
	var report reloadReport
	report.OfferedRPS, report.WindowUS = rate, duration.Microseconds()
	workers.Go(func() {
		report.Requests, report.ElapsedUS = c.traffic(t, start, duration, rate)
	})
	var rssErr error
	workers.Go(func() {
		for offset := time.Duration(0); offset <= duration; offset += 25 * time.Millisecond {
			time.Sleep(time.Until(start.Add(offset)))
			value, err := readRSS(c.pid)
			if err != nil {
				rssErr = err
				return
			}
			report.RSS = append(report.RSS, rssSample{time.Since(start).Microseconds(), value})
		}
	})
	defer workers.Wait()
	for i, slot := range slots {
		time.Sleep(time.Until(start.Add(time.Duration(i+1) * 300 * time.Millisecond)))
		report.Updates = append(report.Updates, c.update(t, start, uint64(i+1), slot, i == 2))
	}
	workers.Wait()
	if rssErr != nil || len(report.RSS) < 2 {
		t.Fatalf("RSS samples missing: %v", rssErr)
	}
	for _, row := range report.Requests {
		if row.Outcome != "ok" || !validOrigin(row, report.Updates) {
			t.Fatalf("reload traffic failed: %+v, updates %+v", row, report.Updates)
		}
	}
	if path := os.Getenv("EDGE_RELOAD_REPORT"); path != "" {
		file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if err != nil {
			t.Fatal(err)
		}
		err = json.NewEncoder(file).Encode(report)
		closeErr := file.Close()
		if err != nil || closeErr != nil {
			t.Fatalf("write reload evidence: %v %v", err, closeErr)
		}
	}
	t.Logf("%d scheduled requests passed across %d update attempts, %d RSS samples",
		len(report.Requests), len(report.Updates), len(report.RSS))
}

func TestCapstoneSteady(t *testing.T) {
	measureTraffic(t, nil)
}

func TestCapstoneReload(t *testing.T) {
	measureTraffic(t, []int{1, 0, 1, 1, 0})
}
~~~

</details>

### Step 2 — Interpret the failed update

Change only the candidate health response. Require the active generation and served origin to remain at the last applied snapshot. Keep the timed workload running until its final arrival completes.

<details>
<summary>Hint</summary>

A rejected attempt has no publication window.

</details>

## Check it

~~~bash
cargo build --locked --target-dir target
EDGE_BIN="$PWD/target/debug/switchyard-edge" go test -race -count=1 -v ./control -run '^(TestCapstoneSteady|TestCapstoneReload)$'
~~~

<!-- run: cargo build --locked --target-dir target && EDGE_BIN="$PWD/target/debug/switchyard-edge" go test -race -count=1 -v ./control -run '^(TestCapstoneSteady|TestCapstoneReload)$' -->

The reference trial served all 240 scheduled requests across four applied updates and one rejection. The origin and RSS observations are retained alongside the workload. [Reference results](../evidence/README.md)

## If it goes wrong

If a capture fails, inspect the error or the origin choice before changing the offered rate. Verify that the driver was healthy at the same rate without updates.

Continue to [Measure throughput, latency, and memory](03-measure-throughput-and-memory.md).
