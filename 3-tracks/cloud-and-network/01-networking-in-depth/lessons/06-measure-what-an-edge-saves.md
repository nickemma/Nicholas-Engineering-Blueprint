# 06 Measure what an edge saves

> Networking in depth · Week 3 · Builds on lesson 05

## The problem

An edge can route packets, terminate connections, or answer with a cached response. Timing alone cannot tell you which happened.

## The mental model

Keep the origin payload and link path fixed. In direct mode the edge forwards packets. In proxy mode it terminates client TLS and reuses an origin client. After cache priming it can answer from its own bounded object cache.

## The pattern

Compare the same content along each path. Track the origin request count independently of edge timing. A warm cache hit must leave that counter fixed.

## Build it

### Step 1 — Sketch the three paths

Mark where the client TLS connection ends and whether each path reaches the origin.

<details>
<summary>Hint</summary>

Direct routing still passes through the edge namespace.

</details>

### Step 2 — Build the bounded edge fixture

Pass a fixed origin client into a small handler and cache only complete successful objects. Use an immutable lab content fixture.

<details>
<summary>Hint</summary>

A proxy request still changes the origin counter even when the connection is reused.

</details>

<details>
<summary>Implementation</summary>

Create `edge/edge.go`.

<!-- file: edge/edge.go -->
~~~go
// Package edge caches the immutable object fixture in front of one origin.
package edge

import (
	"context"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

type cache struct {
	mu       sync.Mutex
	items    map[string][]byte
	origin   string
	client   *http.Client
	useCache bool
}

func Handler(origin string, client *http.Client, useCache bool) http.Handler {
	node := &cache{items: make(map[string][]byte), origin: strings.TrimSuffix(origin, "/"),
		client: client, useCache: useCache}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /obj/{size}/{id}", node.object)
	return mux
}

func (c *cache) object(w http.ResponseWriter, r *http.Request) {
	key := r.URL.RequestURI()
	c.mu.Lock()
	body, found := c.items[key]
	c.mu.Unlock()
	status := "hit"
	if !found {
		status = "miss"
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, c.origin+key, nil)
		if err != nil {
			http.Error(w, "invalid origin request", http.StatusBadGateway)
			return
		}
		response, err := c.client.Do(request)
		if err != nil {
			http.Error(w, "origin unavailable", http.StatusBadGateway)
			return
		}
		defer response.Body.Close()
		body, err = io.ReadAll(io.LimitReader(response.Body, (128<<10)+1))
		if err != nil || response.StatusCode != http.StatusOK || len(body) > 128<<10 {
			http.Error(w, "origin response unavailable", http.StatusBadGateway)
			return
		}
		c.mu.Lock()
		if c.useCache && len(c.items) < 128 {
			c.items[key] = body
		}
		c.mu.Unlock()
	}
	w.Header().Set("X-Cache", status)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(body)
}
~~~

Find these regions in `cmd/netlab/main.go` in order.

<!-- edit: cmd/netlab/main.go -->
~~~go
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
~~~

Replace the selected lines with this block.

~~~go
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
~~~

<!-- edit: cmd/netlab/main.go -->
~~~go
	"syscall"
	"time"

	"switchyard/netlab/page"
)
~~~

Replace the selected lines with this block.

~~~go
	"syscall"
	"time"

	"switchyard/netlab/edge"
	"switchyard/netlab/page"
)
~~~

<!-- edit: cmd/netlab/main.go -->
~~~go
		var origin page.Origin
		return page.Serve(ctx, args[1], filepath.Join(args[2], "server.pem"), filepath.Join(args[2], "server.key"),
			origin.Handler(), func(address string) { fmt.Println("ready", address) })
	case len(args) == 7 && args[0] == "fetch":
		count, err := strconv.Atoi(args[4])
		if err != nil {
~~~

Replace the selected lines with this block.

~~~go
		var origin page.Origin
		return page.Serve(ctx, args[1], filepath.Join(args[2], "server.pem"), filepath.Join(args[2], "server.key"),
			origin.Handler(), func(address string) { fmt.Println("ready", address) })
	case len(args) == 5 && args[0] == "edge":
		trust := filepath.Join(args[3], "server.pem")
		client, closeClient, err := page.Client("h2", trust)
		if err != nil {
			return err
		}
		defer closeClient()
		if args[4] != "cache" && args[4] != "proxy" {
			return errors.New("edge mode must be cache or proxy")
		}
		return page.Serve(ctx, args[1], trust, filepath.Join(args[3], "server.key"),
			edge.Handler(args[2], client, args[4] == "cache"), func(address string) { fmt.Println("ready", address) })
	case len(args) == 3 && args[0] == "count":
		client, closeClient, err := page.Client("h2", args[2])
		if err != nil {
			return err
		}
		defer closeClient()
		attempt, stop := context.WithTimeout(ctx, 5*time.Second)
		defer stop()
		req, err := http.NewRequestWithContext(attempt, "GET", args[1]+"/count", nil)
		if err != nil {
			return err
		}
		reply, err := client.Do(req)
		if err != nil {
			return err
		}
		defer reply.Body.Close()
		if reply.StatusCode != http.StatusOK {
			return errors.New("cannot read origin counter")
		}
		_, err = io.Copy(os.Stdout, io.LimitReader(reply.Body, 128))
		return err
	case len(args) == 7 && args[0] == "fetch":
		count, err := strconv.Atoi(args[4])
		if err != nil {
~~~

<!-- edit: cmd/netlab/main.go -->
~~~go
		}
		return json.NewEncoder(os.Stdout).Encode(result)
	default:
		return errors.New("usage: netlab cert DIR | serve ADDRESS CERT_DIR | fetch {h2|h3} URL TRUST COUNT BYTES {cold|warm}")
	}
}
~~~

Replace the selected lines with this block.

~~~go
		}
		return json.NewEncoder(os.Stdout).Encode(result)
	default:
		return errors.New("usage: netlab cert DIR | serve ADDRESS CERT_DIR | edge ADDRESS ORIGIN CERT_DIR {proxy|cache} | count ORIGIN TRUST | fetch {h2|h3} URL TRUST COUNT BYTES {cold|warm}")
	}
}
~~~

</details>

### Step 3 — Verify the warm hit

Prime the cache, capture the origin count, fetch the same bytes again, and check that the counter stays fixed.

<details>
<summary>Hint</summary>

Compare content hashes against the direct response and require the cache hit marker.

</details>

<details>
<summary>Implementation</summary>

Create `edge/edge_test.go`.

<!-- file: edge/edge_test.go -->
~~~go
package edge

import (
	"context"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"switchyard/netlab/page"
)

func start(t *testing.T, handler http.Handler, dir string) string {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	listening, stopped := make(chan string, 1), make(chan error, 1)
	go func() {
		stopped <- page.Serve(ctx, "127.0.0.1:0", filepath.Join(dir, "server.pem"),
			filepath.Join(dir, "server.key"), handler, func(addr string) { listening <- addr })
	}()
	select {
	case addr := <-listening:
		t.Cleanup(func() {
			cancel()
			if err := <-stopped; err != nil {
				t.Error(err)
			}
		})
		return "https://" + addr
	case err := <-stopped:
		cancel()
		t.Fatal(err)
		return ""
	}
}

func TestCachePreventsASecondOriginRequest(t *testing.T) {
	dir := t.TempDir()
	if err := page.Certificates(dir); err != nil {
		t.Fatal(err)
	}
	trust := filepath.Join(dir, "server.pem")
	var origin page.Origin
	base := start(t, origin.Handler(), dir)
	client, closeClient, err := page.Client("h2", trust)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(closeClient)
	proxy := start(t, Handler(base, client, false), dir)
	cached := start(t, Handler(base, client, true), dir)
	ctx, cancel := context.WithTimeout(t.Context(), 8*time.Second)
	defer cancel()

	fetch := func(target string) page.Object {
		t.Helper()
		p, err := page.Fetch(ctx, "h2", target, trust, 1, 8192, false)
		if err != nil {
			t.Fatal(err)
		}
		return p.Objects[0]
	}
	want := fetch(base).SHA256
	if fetch(proxy).SHA256 != want || fetch(cached).SHA256 != want {
		t.Fatal("paths returned different content")
	}
	before := origin.Requests.Load()
	warm := fetch(cached)
	if origin.Requests.Load() != before {
		t.Fatal("warm request reached origin")
	}
	if warm.Cache != "hit" || warm.SHA256 != want {
		t.Fatalf("invalid warm response: %+v", warm)
	}
	t.Logf("warm cache hit kept origin count at %d and matched the direct hash", before)
}
~~~

</details>

## Check it

~~~bash
go test -race -count=1 -v ./edge
~~~

<!-- run: go test -race -count=1 -v ./edge -->

The portable fixture kept its origin count at three across the warm hit. The Linux fixture also records timings for direct, proxy, cache prime, and warm cache. [Edge results](../evidence/README.md)

## If it goes wrong

If the count increases on the warm request, compare the normalized object URI and cache enablement before looking at the latency.
