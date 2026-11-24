# 01 Define the reload contract

> Programmable edge proxy capstone · Week 1 · Builds on lesson 00

## The problem

An acknowledged update can move a route while older requests still have work at the previous origin. Test what the client actually receives during that overlap.

## The mental model

Each HTTP request selects one origin before awaiting its upstream exchange. Snapshot publication changes the selection for later requests. An acknowledgement proves publication has already happened.

## The pattern

Hold a request at the old origin. Publish through the same HTTPS and Unix-socket path an operator uses. Check a fresh request at the new origin before releasing the held response. Run the mirror sequence to prove rollback.

## Build it

### Step 1 — Write the ordering invariant

Draw one held request, publication and acknowledgement, and one fresh request. Mark which step is allowed to release the held request.

<details>
<summary>Hint</summary>

Use the origin signal as evidence that the held request already chose its route.

</details>

### Step 2 — Reuse the managed process harness

Launch the Rust process with two configured origins and return its listen address, management socket, and PID. Keep a deadline on its readiness check.

<details>
<summary>Implementation</summary>

Find these regions in `control/cluster_test.go` in order.

<!-- edit: control/cluster_test.go -->
~~~go
		l.origins[index] = origin.Listener.Addr().String()
	}
	// Unix sockets have short platform path limits. Use a private short directory.
	dir, err := os.MkdirTemp("", "edge-")
~~~

Replace the selected lines with this block.

~~~go
		l.origins[index] = origin.Listener.Addr().String()
	}
	l.edge, l.socket, _ = launchEdge(t, l.origins)
	return l
}

func launchEdge(t *testing.T, origins [2]string) (string, string, int) {
	t.Helper()
	// Unix sockets have short platform path limits. Use a private short directory.
	dir, err := os.MkdirTemp("", "edge-")
~~~

<!-- edit: control/cluster_test.go -->
~~~go
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	l.socket = filepath.Join(dir, "admin.sock")
	cmd := exec.Command(os.Getenv("EDGE_BIN"), "managed", "127.0.0.1:0", l.origins[0], l.origins[1], l.socket)
	cmd.Stderr = os.Stderr
	out, err := cmd.StdoutPipe()
~~~

Replace the selected lines with this block.

~~~go
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socket := filepath.Join(dir, "admin.sock")
	cmd := exec.Command(os.Getenv("EDGE_BIN"), "managed", "127.0.0.1:0", origins[0], origins[1], socket)
	cmd.Stderr = os.Stderr
	out, err := cmd.StdoutPipe()
~~~

<!-- edit: control/cluster_test.go -->
~~~go
		startup <- strings.TrimSpace(line)
	}()
	select {
	case line := <-startup:
~~~

Replace the selected lines with this block.

~~~go
		startup <- strings.TrimSpace(line)
	}()
	var edgeURL string
	select {
	case line := <-startup:
~~~

<!-- edit: control/cluster_test.go -->
~~~go
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
~~~

Replace the selected lines with this block.

~~~go
			t.Fatalf("invalid startup response %q", line)
		}
		edgeURL = "http://" + address
	case <-time.After(3 * time.Second):
		t.Fatal("edge startup timed out")
	}
	for deadline := time.Now().Add(time.Second); ; {
		ack, err := Unix(socket)(t.Context(), Command{Op: "status"})
		if err == nil && ack.Result == "current" {
			return edgeURL, socket, cmd.Process.Pid
		}
		if time.Now().After(deadline) {
~~~

</details>

### Step 3 — Exercise both directions over mutual TLS

Give each origin a distinct header and 4 KiB payload. Check the HTTP version, status, origin, and exact response bytes.

<details>
<summary>Implementation</summary>

Create `control/capstone_test.go`.

<!-- file: control/capstone_test.go -->
~~~go
package control

import (
	"bytes"
	"context"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

const objectPath = "/a/obj/4096/1"

type fixtureOrigin struct {
	id      int
	healthy atomic.Bool
	entered chan struct{}
	release chan struct{}
}

func (o *fixtureOrigin) payload() []byte {
	return bytes.Repeat([]byte{byte('a' + o.id)}, 4096)
}

func (o *fixtureOrigin) handler() http.Handler {
	mux := http.NewServeMux()
	payload := o.payload()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		if !o.healthy.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	respond := func(w http.ResponseWriter) {
		w.Header().Set("X-Origin-Slot", strconv.Itoa(o.id))
		w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
		_, _ = w.Write(payload)
	}
	mux.HandleFunc("GET "+objectPath, func(w http.ResponseWriter, _ *http.Request) {
		respond(w)
	})
	mux.HandleFunc("GET /a/held", func(w http.ResponseWriter, r *http.Request) {
		select {
		case o.entered <- struct{}{}:
		case <-r.Context().Done():
			return
		}
		select {
		case <-o.release:
			respond(w)
		case <-r.Context().Done():
		}
	})
	return mux
}

type capstone struct {
	origins    [2]*fixtureOrigin
	controller Controller
	edge       string
	pid        int
}

func startCapstone(t *testing.T) capstone {
	t.Helper()
	var c capstone
	var addresses [2]string
	for slot := range c.origins {
		origin := &fixtureOrigin{id: slot, entered: make(chan struct{}), release: make(chan struct{})}
		origin.healthy.Store(true)
		server := httptest.NewServer(origin.handler())
		t.Cleanup(server.Close)
		addresses[slot] = server.Listener.Addr().String()
		c.origins[slot] = origin
	}
	edge, socket, pid := launchEdge(t, addresses)
	c.edge, c.pid = edge, pid

	ca := testCA(t)
	dir := t.TempDir()
	sidecarLeaf := filepath.Join(dir, "sidecar.pem")
	controllerLeaf := filepath.Join(dir, "controller.pem")
	ca.issue(t, sidecarLeaf, sidecarRole, 2, x509.ExtKeyUsageServerAuth)
	ca.issue(t, controllerLeaf, controllerRole, 3, x509.ExtKeyUsageClientAuth)
	serverConfig, err := ServerTLS(ca.path, sidecarLeaf)
	if err != nil {
		t.Fatal(err)
	}
	config, err := ClientTLS(ca.path, controllerLeaf)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := NewSidecar(serverConfig, socket)
	t.Cleanup(func() { server.Close() })
	go server.ServeTLS(listener, "", "")
	c.controller = Controller{Origins: addresses, Send: HTTPS("https://"+listener.Addr().String(), config)}
	return c
}

func (c capstone) origin(ctx context.Context, client *http.Client, path string) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.edge+path, nil)
	if err != nil {
		return -1, err
	}
	response, err := client.Do(req)
	if err != nil {
		return -1, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.ProtoMajor != 1 || response.ProtoMinor != 1 {
		return -1, fmt.Errorf("unexpected HTTP result: %s status %d", response.Proto, response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 4097))
	if err != nil {
		return -1, err
	}
	slot, err := strconv.Atoi(response.Header.Get("X-Origin-Slot"))
	if err != nil || slot < 0 || slot >= len(c.origins) || !bytes.Equal(body, c.origins[slot].payload()) {
		return -1, fmt.Errorf("response bytes or origin identity did not match")
	}
	return slot, nil
}

func (c capstone) apply(t *testing.T, generation uint64, slot int) {
	t.Helper()
	desired := NewSnapshot(generation, [2]int{slot, 1 - slot})
	ack, err := c.controller.Apply(t.Context(), desired)
	if err != nil || ack.Result != "applied" || ack.Snapshot != desired {
		t.Fatalf("publish generation %d: %+v, %v", generation, ack, err)
	}
}

func (c capstone) assertOrigin(t *testing.T, expected int) {
	t.Helper()
	slot, err := c.origin(t.Context(), requestClient(), objectPath)
	if err != nil || slot != expected {
		t.Fatalf("new request: want origin %d, got %d, %v", expected, slot, err)
	}
}

func (c capstone) handoff(t *testing.T, generation uint64, previous, next int) {
	t.Helper()
	origin := c.origins[previous]
	held := make(chan error, 1)
	go func() {
		slot, err := c.origin(t.Context(), requestClient(), "/a/held")
		if err == nil && slot != previous {
			err = fmt.Errorf("expected origin %d, observed %d", previous, slot)
		}
		held <- err
	}()
	select {
	case <-origin.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("held request did not reach its original origin")
	}
	c.apply(t, generation, next)
	c.assertOrigin(t, next)
	select {
	case origin.release <- struct{}{}:
	case err := <-held:
		t.Fatalf("held request interrupted at publication: %v", err)
	case <-time.After(time.Second):
		t.Fatal("held request did not drain")
	}
	if err := <-held; err != nil {
		t.Fatalf("held request interrupted at publication: %v", err)
	}
	t.Logf("generation %d: held request finished at %d, post-ack request reached %d", generation, previous, next)
}

func TestCapstoneHandoff(t *testing.T) {
	c := startCapstone(t)
	c.handoff(t, 1, 0, 1)
	c.handoff(t, 2, 1, 0)
}
~~~

</details>

## Check it

~~~bash
cargo build --locked --target-dir target
EDGE_BIN="$PWD/target/debug/switchyard-edge" go test -race -count=1 -v ./control -run '^TestCapstoneHandoff$'
~~~

<!-- run: cargo build --locked --target-dir target && EDGE_BIN="$PWD/target/debug/switchyard-edge" go test -race -count=1 -v ./control -run '^TestCapstoneHandoff$' -->

The controlled swap and rollback both preserved the held response and moved the post-acknowledgement request. [Portable gate transcript](../evidence/reference/portable.txt)

## If it goes wrong

If the held request expires, check when the fixture released it relative to the existing upstream deadline. If the fresh request lands at the old origin, compare the acknowledgement and actual route selection.

Continue to [Reload and roll back under traffic](02-reload-under-traffic.md).
