# 05 Define reliability from the client side

## The problem

A process can be up while the client sees timeouts or wrong values. Observe the response from the client side and count rejected, slow, and failed attempts according to the contract.

## The pattern

An **SLI** is a measured indicator. Here it is good scheduled probe attempts divided by all attempts made. A good attempt returns HTTP 200 with the exact seeded value inside the request deadline. Transport failures, timeouts, unsuccessful HTTP responses, and wrong values remain in the denominator. A stopped probe needs separate monitoring in a deployed system because it produces no observations.

An **SLO** is a target for an SLI over a window. An illustrative 99.9% target allows an error budget of 0.1% of eligible attempts. In 10,000 attempts, that allows 10 bad outcomes. For the short lab choose three good outcomes out of the latest four and evaluate only after the first four arrive. The resulting state change is an alert transition. This lab measures one synthetic journey. The deployment unit expands the monitoring system with production alert windows.

~~~text
attempt        1 2 3 4 5 6 7 8 9
good?          Y Y Y Y N N Y Y Y
transition               fire  clear
~~~

## Build it

### Step 1. Maintain the rolling count

Add every observation. Work out which sample leaves the window on the fifth observation. Report transition events only when the state changes.

<details>
<summary>Hint</summary>

Subtract a good sample when it is overwritten and count the new sample once.

</details>

<details>
<summary>Completed files</summary>

Create `internal/sli/window.go`.

<!-- file: internal/sli/window.go -->
~~~go
// Package sli tracks an availability objective over a rolling probe window.
package sli

type Window struct {
	samples []bool
	minGood int
	next    int
	total   int
	good    int
	firing  bool
}

func New(size, minGood int) *Window {
	return &Window{samples: make([]bool, size), minGood: minGood}
}

type State struct {
	Total      int    `json:"total"`
	Good       int    `json:"good"`
	Firing     bool   `json:"firing"`
	Transition string `json:"transition,omitempty"`
}

func (w *Window) Observe(good bool) State {
	if w.total == len(w.samples) {
		if w.samples[w.next] {
			w.good--
		}
	} else {
		w.total++
	}
	if good {
		w.good++
	}
	w.samples[w.next] = good
	w.next = (w.next + 1) % len(w.samples)
	state := State{Total: w.total, Good: w.good}
	firing := w.total == len(w.samples) && w.good < w.minGood
	if firing != w.firing {
		state.Transition = "clear"
		if firing {
			state.Transition = "firing"
		}
	}
	w.firing = firing
	state.Firing = firing
	return state
}
~~~

Create `internal/sli/window_test.go`.

<!-- file: internal/sli/window_test.go -->
~~~go
package sli

import "testing"

func TestFiringAndRecovery(t *testing.T) {
	w := New(4, 3)
	input := []bool{true, true, true, true, false, false, true, true, true}
	for i, good := range input {
		state := w.Observe(good)
		if state.Total != min(i+1, 4) {
			t.Fatalf("sample %d: %+v", i, state)
		}
		want := map[int]string{5: "firing", 8: "clear"}[i]
		if state.Transition != want || state.Firing != (i >= 5 && i < 8) {
			t.Fatalf("sample %d got %+v want transition %q", i, state, want)
		}
		if want != "" {
			t.Logf("attempt %d: %s (%d/%d good)", i+1, want, state.Good, state.Total)
		}
	}
}
~~~

</details>
### Step 2. Make the probe a real client

Call the same mTLS entry point as a reader. Check status, expected value, and deadline. Emit one outcome per attempted request.

<details>
<summary>Hint</summary>

Keep the expected value in a file. Use a stable reason code and elapsed window state in the observation, without copying values or request bodies.

</details>

<details>
<summary>Completed files</summary>

Create `cmd/ship-probe/main.go`.

<!-- file: cmd/ship-probe/main.go -->
~~~go
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"time"

	"switchyard/metad/internal/edge"
	"switchyard/metad/internal/sli"
)

type observation struct {
	Attempt int       `json:"attempt"`
	At      time.Time `json:"at"`
	Status  int       `json:"status"`
	Reason  string    `json:"reason"`
	sli.State
}

func measure(client *http.Client, address string, body []byte, expected string, deadline time.Duration) (int, string) {
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, address, bytes.NewReader(body))
	if err != nil {
		return 0, "transport"
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return 0, "deadline"
		}
		return 0, "transport"
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return res.StatusCode, "http"
	}
	var actual edge.Metadata
	raw, err := io.ReadAll(io.LimitReader(res.Body, edge.ResponseLimit+1))
	if ctx.Err() != nil {
		return res.StatusCode, "deadline"
	}
	if err != nil || len(raw) > edge.ResponseLimit || json.Unmarshal(raw, &actual) != nil ||
		!actual.Found || actual.Value != expected {
		return res.StatusCode, "response"
	}
	return res.StatusCode, "good"
}

func run() error {
	address := flag.String("url", "", "HTTPS command URL")
	keyName := flag.String("lookup", "", "synthetic metadata key")
	expect := flag.String("expect-file", "", "file with the exact expected value")
	ca := flag.String("ca", "", "server trust root PEM")
	cert := flag.String("cert", "", "probe certificate PEM")
	key := flag.String("key", "", "probe private key PEM")
	interval := flag.Duration("interval", 250*time.Millisecond, "pause between attempts")
	deadline := flag.Duration("deadline", time.Second, "end-to-end deadline")
	count := flag.Int("count", 0, "stop after this many attempts; zero runs continuously")
	flag.Parse()
	parsed, err := url.Parse(*address)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil ||
		*keyName == "" || len(*keyName) > 128 || *count < 0 || *interval <= 0 || *deadline <= 0 {
		return errors.New("invalid probe configuration")
	}
	expected, err := os.ReadFile(*expect)
	if err != nil {
		return err
	}
	if len(expected) > 512 {
		return errors.New("expected value exceeds metadata limit")
	}
	cfg, err := edge.TLSConfig(*ca, *cert, *key, false)
	if err != nil {
		return err
	}
	transport := &http.Transport{TLSClientConfig: cfg}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	body, _ := json.Marshal(edge.Command{Op: "get", Key: *keyName})
	window := sli.New(4, 3)
	out := json.NewEncoder(os.Stdout)
	for attempt := 1; *count == 0 || attempt <= *count; attempt++ {
		status, reason := measure(client, parsed.String(), body, string(expected), *deadline)
		row := observation{Attempt: attempt, At: time.Now().UTC(), Status: status, Reason: reason,
			State: window.Observe(reason == "good")}
		if err := out.Encode(row); err != nil {
			return err
		}
		if attempt != *count {
			time.Sleep(*interval)
		}
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
~~~

Create `cmd/ship-probe/main_test.go`.

<!-- file: cmd/ship-probe/main_test.go -->
~~~go
package main

import (
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type transportFunc func(*http.Request) (*http.Response, error)

func (fn transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return fn(r) }

func TestMeasure(t *testing.T) {
	for _, x := range []struct {
		status     int
		body, want string
	}{
		{200, `{"found":true,"value":"canary"}`, "good"},
		{200, `{"found":true,"value":"wrong"}`, "response"},
		{200, `{"found":false}`, "response"},
		{503, "", "http"},
	} {
		client := &http.Client{Transport: transportFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: x.status, Body: io.NopCloser(strings.NewReader(x.body))}, nil
		})}
		if _, reason := measure(client, "https://probe/command", nil, "canary", time.Second); reason != x.want {
			t.Fatalf("%+v: got reason %s", x, reason)
		}
	}
}

func TestMeasureDeadline(t *testing.T) {
	client := &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	if _, reason := measure(client, "https://probe/command", nil, "canary", time.Millisecond); reason != "deadline" {
		t.Fatal(reason)
	}
}
~~~

</details>

## Check it

~~~bash
go vet ./internal/sli ./cmd/ship-probe && go test -race -count=1 -v ./internal/sli ./cmd/ship-probe
~~~

<!-- run: go vet ./internal/sli ./cmd/ship-probe && go test -race -count=1 -v ./internal/sli ./cmd/ship-probe -->

~~~text
    window_test.go:18: attempt 6: firing (2/4 good)
    window_test.go:18: attempt 9: clear (3/4 good)
--- PASS: TestMeasure (0.00s)
--- PASS: TestMeasureDeadline (0.00s)
~~~

The first four good observations establish the baseline. Two failures fire the alert, and three subsequent good attempts clear it.

[Captured output](../evidence/05-sli.txt)

## Explain it

How would dropping timeouts change the ratio? What does this probe say about writer availability?
