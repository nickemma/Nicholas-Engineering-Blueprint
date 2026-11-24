# 02 Check origins and apply a route change

> The proxy’s control plane · Week 1 · Builds on lesson 01

## The problem

A syntactically valid snapshot can point a route at an unhealthy origin. A live update can also race with a request that already selected its upstream.

## The mental model

The configured origin inventory is shared operationally by the controller and proxy. A health probe checks a candidate at a point in time. The Rust request selects an origin once and keeps that reference through the exchange. The origin pool and breaker are tied to physical slots.

## The pattern

Bound each preflight probe. Send the snapshot after both configured origins answer successfully. Use a held request to observe the handoff and an acknowledgement readback to choose the next generation. Publish rollback with a higher generation.

## Build it

### Step 1 — Make health a prerequisite

Probe a fixed path at configured numeric loopback addresses. Set a deadline, require HTTP 200, and reject a failed candidate before sending it to Rust.

<details>
<summary>Implementation</summary>

Create `control/controller.go`.

<!-- file: control/controller.go -->
~~~go
package control

import (
	"context"
	"fmt"
	"net/http"
	"net/netip"
	"time"
)

type Controller struct {
	Origins [2]string
	Send    Send
}

func requestClient() *http.Client {
	return &http.Client{
		Transport:     &http.Transport{DisableKeepAlives: true},
		Timeout:       2 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func (c Controller) Apply(ctx context.Context, snapshot Snapshot) (Ack, error) {
	if snapshot.Order != [2]int{0, 1} && snapshot.Order != [2]int{1, 0} ||
		snapshot.Digest != NewSnapshot(snapshot.Generation, snapshot.Order).Digest {
		return Ack{}, fmt.Errorf("invalid snapshot")
	}
	client := requestClient()
	client.Timeout = 250 * time.Millisecond
	for _, index := range snapshot.Order {
		address, err := netip.ParseAddrPort(c.Origins[index])
		if err != nil || !address.Addr().IsLoopback() || address.Port() == 0 {
			return Ack{}, fmt.Errorf("invalid configured origin %d", index)
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+address.String()+"/health", nil)
		if err != nil {
			return Ack{}, err
		}
		response, err := client.Do(request)
		if err != nil {
			return Ack{}, fmt.Errorf("origin %d health check: %w", index, err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return Ack{}, fmt.Errorf("origin %d unhealthy: HTTP %d", index, response.StatusCode)
		}
	}
	return c.Send(ctx, Command{Op: "apply", Snapshot: &snapshot})
}
~~~

</details>

### Step 2 — Check both sides of the update

Hold a request at origin A, apply a swap, and simulate losing the response after it was applied. Check the held response and the next request. Verify that retry and rollback produce the expected acknowledgements.

<details>
<summary>Hint</summary>

Observe the held request at the origin before issuing the update.

</details>

<details>
<summary>Implementation</summary>

Create `control/cluster_test.go`.

<!-- file: control/cluster_test.go -->
~~~go
package control

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type lab struct {
	origins [2]string
	edge    string
	socket  string
	healthy atomic.Bool
	entered chan struct{}
	release chan struct{}
}

func startLab(t *testing.T) *lab {
	t.Helper()
	binary := os.Getenv("EDGE_BIN")
	if binary == "" {
		t.Skip("set EDGE_BIN to the built Rust proxy")
	}
	l := &lab{entered: make(chan struct{}, 1), release: make(chan struct{}, 1)}
	l.healthy.Store(true)
	for index, name := range [2]string{"origin-a", "origin-b"} {
		origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/health" && index == 1 && !l.healthy.Load() {
				http.Error(w, "unhealthy", http.StatusServiceUnavailable)
				return
			}
			if index == 0 && r.URL.Path == "/a/held" {
				l.entered <- struct{}{}
				select {
				case <-l.release:
				case <-r.Context().Done():
					return
				}
			}
			fmt.Fprint(w, name)
		}))
		t.Cleanup(origin.Close)
		l.origins[index] = origin.Listener.Addr().String()
	}
	// Unix sockets have short platform path limits. Use a private short directory.
	dir, err := os.MkdirTemp("", "edge-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	l.socket = filepath.Join(dir, "admin.sock")
	cmd := exec.Command(os.Getenv("EDGE_BIN"), "managed", "127.0.0.1:0", l.origins[0], l.origins[1], l.socket)
	cmd.Stderr = os.Stderr
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	startup := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(out).ReadString('\n')
		startup <- strings.TrimSpace(line)
	}()
	select {
	case line := <-startup:
		address, ok := strings.CutPrefix(line, "listening ")
		if !ok {
			t.Fatalf("invalid startup response %q", line)
		}
		l.edge = "http://" + address
	case <-time.After(3 * time.Second):
		t.Fatal("edge startup timed out")
	}
	for deadline := time.Now().Add(time.Second); ; {
		ack, err := Unix(l.socket)(t.Context(), Command{Op: "status"})
		if err == nil && ack.Result == "current" {
			return l
		}
		if time.Now().After(deadline) {
			t.Fatalf("edge status unavailable: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func fetch(ctx context.Context, url string) (string, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	response, err := requestClient().Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 64))
	if response.StatusCode != 200 {
		return "", fmt.Errorf("HTTP %d: %s", response.StatusCode, body)
	}
	return string(body), err
}

func routeScenarios(t *testing.T, l *lab, send Send) {
	t.Helper()
	ctx := t.Context()
	check := func(cmd Command, result string, generation uint64) {
		t.Helper()
		ack, err := send(ctx, cmd)
		if err != nil || ack.Result != result || ack.Snapshot.Generation != generation {
			t.Fatalf("expected %s generation %d, got %+v, %v", result, generation, ack, err)
		}
	}
	desired := NewSnapshot(1, [2]int{1, 0})
	update := Command{Op: "apply", Snapshot: &desired}
	controller := Controller{Origins: l.origins, Send: send}
	l.healthy.Store(false)
	if _, err := controller.Apply(ctx, desired); err == nil {
		t.Fatal("unhealthy candidate accepted")
	}
	check(Command{Op: "status"}, "current", 0)
	l.healthy.Store(true)

	held := make(chan error, 1)
	go func() {
		body, err := fetch(ctx, l.edge+"/a/held")
		if err == nil && body != "origin-a" {
			err = fmt.Errorf("held request reached %s", body)
		}
		held <- err
	}()
	select {
	case <-l.entered:
	case <-time.After(time.Second):
		t.Fatal("held request did not reach first origin")
	}
	controller.Send = func(ctx context.Context, cmd Command) (Ack, error) {
		ack, err := send(ctx, cmd)
		if err != nil || ack.Result != "applied" {
			t.Fatalf("first publish: %+v %v", ack, err)
		}
		return Ack{}, io.ErrUnexpectedEOF
	}
	if _, err := controller.Apply(ctx, desired); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("lost acknowledgement: %v", err)
	}
	l.release <- struct{}{}
	if err := <-held; err != nil {
		t.Fatal(err)
	}
	check(update, "unchanged", 1)
	body, err := fetch(ctx, l.edge+"/a/new")
	if err != nil || body != "origin-b" {
		t.Fatalf("new request: %q %v", body, err)
	}
	stale := NewSnapshot(0, [2]int{0, 1})
	conflict := NewSnapshot(1, [2]int{0, 1})
	check(Command{Op: "apply", Snapshot: &stale}, "stale", 1)
	check(Command{Op: "apply", Snapshot: &conflict}, "conflict", 1)
	check(Command{Op: "status"}, "current", 1)
	rollback := NewSnapshot(2, [2]int{0, 1})
	controller.Send = send
	ack, err := controller.Apply(ctx, rollback)
	if err != nil || ack.Result != "applied" || ack.Snapshot != rollback {
		t.Fatalf("rollback: %+v %v", ack, err)
	}
	body, err = fetch(ctx, l.edge+"/a/new")
	if err != nil || body != "origin-a" {
		t.Fatalf("rolled-back request: %q %v", body, err)
	}
	t.Log("unhealthy candidate rejected, old request drained, new route served, retry acknowledged, rollback applied")
}

func TestRoutes(t *testing.T) {
	l := startLab(t)
	routeScenarios(t, l, Unix(l.socket))
}
~~~

</details>

## Check it

~~~bash
cargo build --locked --target-dir target
EDGE_BIN="$PWD/target/debug/switchyard-edge" go test -count=1 -v ./control -run '^TestRoutes$'
~~~

<!-- run: cargo build --locked --target-dir target && EDGE_BIN="$PWD/target/debug/switchyard-edge" go test -count=1 -v ./control -run '^TestRoutes$' -->

The reference test rejected the unhealthy candidate, drained the held request at the original origin, sent the next request to the new origin, and verified the retry and rollback. [Portable gate capture](../evidence/portable.txt)

## If it goes wrong

If the held request times out, check the ordering of the fixture events and release it within the Part 02 upstream deadline. If health passes for the wrong origin, compare the controller and proxy inventories slot by slot.

Continue to [Put mutual TLS on the management path](03-bind-management-peer-identities.md).
