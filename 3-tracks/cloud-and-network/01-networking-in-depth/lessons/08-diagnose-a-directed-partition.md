# 08 Diagnose a partial partition

> Networking in depth · Week 4 · Builds on lesson 07

## The problem

The caller sees a timeout and assumes its worker never saw the request. A one-way failure makes that conclusion unsafe.

## The mental model

First model the two directions independently. Then block origin egress in the isolated Linux fixture. Send directed UDP probes across both directions. Use an edge API fixture to make a bounded job request against its dependency.

## The pattern

Request delivery and response delivery are separate. A local timeout describes the caller’s observation. Use independent directional evidence to narrow down the failed link, then restore it and run the same probes. [Raft partial partitions](../../../storage-engines/02-consensus-in-depth/lessons/04-protect-a-healthy-majority.md)

## Build it

### Step 1 — Predict two different probes

Write the expected forward probe, reverse probe, and caller result when only the reply direction fails.

<details>
<summary>Hint</summary>

The probe in one direction cannot establish reachability in the other.

</details>

### Step 2 — Implement the directed model

Record each directed edge independently and connect it to the worker action and client-visible result.

<details>
<summary>Hint</summary>

A symmetric lookup would give the wrong result in the partial partition.

</details>

<details>
<summary>Implementation</summary>

Create `partition/model.go`.

<!-- file: partition/model.go -->
~~~go
// Package partition separates forward probes from request/reply success.
package partition

type Direction struct{ From, To string }

type Links map[Direction]bool

func (links Links) Probe(from, to string) bool {
	return links[Direction{from, to}]
}

type Result struct {
	WorkerApplied bool
	CallerOK      bool
}

func (links Links) Job() Result {
	// Delivery to the worker and delivery of its reply are separate.
	forward := links.Probe("api", "worker")
	return Result{WorkerApplied: forward, CallerOK: forward && links.Probe("worker", "api")}
}
~~~

Create `partition/model_test.go`.

<!-- file: partition/model_test.go -->
~~~go
package partition

import "testing"

func TestDirectedPartitionAndHeal(t *testing.T) {
	forward := Direction{"api", "worker"}
	reverse := Direction{"worker", "api"}
	links := Links{forward: true, reverse: true}
	if result := links.Job(); !result.CallerOK {
		t.Fatalf("healthy job: %+v", result)
	}
	links[reverse] = false
	if !links.Probe(forward.From, forward.To) || links.Probe(reverse.From, reverse.To) {
		t.Fatal("asymmetric link was misclassified")
	}
	if result := links.Job(); !result.WorkerApplied || result.CallerOK {
		t.Fatalf("partial partition: %+v", result)
	}
	links[reverse] = true
	if result := links.Job(); !result.WorkerApplied || !result.CallerOK {
		t.Fatalf("heal: %+v", result)
	}
	t.Log("the worker received the request during the partition; only healing restored the reply")
}
~~~

</details>

### Step 3 — Drive the live fixture

Add UDP send and receive commands and a bounded job request. Run the no-loss and impaired HTTP cases, then apply the one-way outage and heal it.

<details>
<summary>Hint</summary>

Use the proxy without a cache for the job request so a live worker dependency remains in its path.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `page/page.go` in order.

<!-- edit: page/page.go -->
~~~go

func (o *Origin) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /count", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, o.Requests.Load())
	})
~~~

Replace the selected lines with this block.

~~~go

func (o *Origin) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /jobs/fixture", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintln(w, `{"job":"fixture","state":"ready"}`)
	})
	mux.HandleFunc("GET /count", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, o.Requests.Load())
	})
~~~

Find these regions in `edge/edge.go` in order.

<!-- edit: edge/edge.go -->
~~~go
		client: client, useCache: useCache}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /obj/{size}/{id}", node.object)
	return mux
}
~~~

Replace the selected lines with this block.

~~~go
		client: client, useCache: useCache}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /obj/{size}/{id}", node.object)
	mux.HandleFunc("GET /jobs/fixture", node.object)
	return mux
}
~~~

Find these regions in `cmd/netlab/main.go` in order.

<!-- edit: cmd/netlab/main.go -->
~~~go
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
~~~

Replace the selected lines with this block.

~~~go
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
~~~

<!-- edit: cmd/netlab/main.go -->
~~~go
		}
		_, err = io.Copy(os.Stdout, io.LimitReader(reply.Body, 128))
		return err
	case len(args) == 7 && args[0] == "fetch":
		count, err := strconv.Atoi(args[4])
		if err != nil {
~~~

Replace the selected lines with this block.

~~~go
		}
		_, err = io.Copy(os.Stdout, io.LimitReader(reply.Body, 128))
		return err
	case len(args) == 4 && args[0] == "outcome":
		client, closeClient, err := page.Client("h2", args[2])
		if err != nil {
			return err
		}
		defer closeClient()
		timeout, err := time.ParseDuration(args[3])
		if err != nil || timeout <= 0 {
			return errors.New("positive request timeout required")
		}
		attempt, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		req, err := http.NewRequestWithContext(attempt, "GET", args[1]+"/jobs/fixture", nil)
		if err != nil {
			return err
		}
		start := time.Now()
		response, err := client.Do(req)
		if err != nil {
			return err
		}
		defer response.Body.Close()
		if _, err = io.Copy(io.Discard, io.LimitReader(response.Body, 8192)); err != nil {
			return err
		}
		fmt.Printf("status=%d elapsed_ms=%d\n", response.StatusCode, time.Since(start).Milliseconds())
		return nil
	case len(args) == 3 && args[0] == "udp" && args[1] == "receive":
		socket, err := net.ListenPacket("udp", args[2])
		if err != nil {
			return err
		}
		defer socket.Close()
		if err := socket.SetReadDeadline(time.Now().Add(750 * time.Millisecond)); err != nil {
			return err
		}
		fmt.Println("ready")
		buf := make([]byte, 64)
		count, _, err := socket.ReadFrom(buf)
		if err != nil {
			return err
		}
		if string(buf[:count]) != "switchyard-lab-probe" {
			return errors.New("invalid fixture probe")
		}
		fmt.Println("received")
		return nil
	case len(args) == 3 && args[0] == "udp" && args[1] == "send":
		socket, err := net.Dial("udp", args[2])
		if err != nil {
			return err
		}
		defer socket.Close()
		_, err = socket.Write([]byte("switchyard-lab-probe"))
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
		return errors.New("usage: netlab cert DIR | serve ADDRESS CERT_DIR | edge ADDRESS ORIGIN CERT_DIR {proxy|cache} | count ORIGIN TRUST | fetch {h2|h3} URL TRUST COUNT BYTES {cold|warm}")
	}
}
~~~

Replace the selected lines with this block.

~~~go
		}
		return json.NewEncoder(os.Stdout).Encode(result)
	default:
		return errors.New("usage: netlab cert DIR | serve ADDRESS CERT_DIR | edge ADDRESS ORIGIN CERT_DIR {proxy|cache} | count ORIGIN TRUST | outcome URL TRUST TIMEOUT | udp {send|receive} ADDRESS | fetch {h2|h3} URL TRUST COUNT BYTES {cold|warm}")
	}
}
~~~

Create `experiments/http-live.sh`.

<!-- file: experiments/http-live.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
cd /lab
source experiments/topology.sh
base=/out/http
engine=/engine
mkdir -p "$base"
topology
keys=$(mktemp -d)
trap 'rm -rf "$keys"' EXIT
"$engine" cert "$keys"
trust="$keys/server.pem"
origin=https://10.77.2.2:8443
proxy=https://10.77.1.1:8444
cache=https://10.77.1.1:8445
ns origin "$engine" serve 10.77.2.2:8443 "$keys" >"$base/origin.log" 2>&1 &
ns edge "$engine" edge 10.77.1.1:8444 "$origin" "$keys" proxy >"$base/proxy.log" 2>&1 &
ns edge "$engine" edge 10.77.1.1:8445 "$origin" "$keys" cache >"$base/cache.log" 2>&1 &
wait_ready() {
    local file=$1
    local attempt
    for attempt in {1..30}; do
        if grep -q '^ready' "$file"; then return; fi
        sleep 0.1
    done
    cat "$file" >&2
    return 1
}
for server in origin proxy cache; do wait_ready "$base/$server.log"; done
get() { ns client "$engine" fetch "$@"; }
count() { ns client "$engine" count "$origin" "$trust"; }

for loss in 0 1; do
    shape 20 "$loss%" deep
    for repeat in 1 2 3; do
        protocols=(h2 h3)
        if (( repeat % 2 == 0 )); then protocols=(h3 h2); fi
        for protocol in "${protocols[@]}"; do
            for mode in cold warm; do
                get "$protocol" "$origin" "$trust" 12 4096 "$mode" >"$base/loss-$loss-$repeat-$protocol-$mode.json"
            done
        done
    done
done

shape 20 0% managed
get h2 "$origin" "$trust" 8 8192 warm >"$base/direct.json"
get h2 "$proxy" "$trust" 8 8192 warm >"$base/proxy.json"
get h2 "$cache" "$trust" 8 8192 warm >"$base/cache-prime.json"
count >"$base/origin-before-hit.txt"
get h2 "$cache" "$trust" 8 8192 warm >"$base/cache-hit.json"
count >"$base/origin-after-hit.txt"

one_way() {
    local receiver=$1 addr=$2 sender=$3 log=$4 expected=$5
    ns "$receiver" "$engine" udp receive "$addr" >"$log" 2>&1 &
    local child=$!
    wait_ready "$log"
    ns "$sender" "$engine" udp send "$addr"
    if wait "$child"; then
        test "$expected" = pass
        grep -q '^received$' "$log"
    else
        test "$expected" = blocked
        grep -q 'i/o timeout' "$log"
    fi
}

ns client "$engine" outcome "$proxy" "$trust" 12s >"$base/before-partition.txt"
ns origin tc qdisc change dev origin0 root netem delay 20ms loss 100% limit 10000
one_way origin 10.77.2.2:9090 client "$base/forward.txt" pass
one_way client 10.77.1.2:9090 origin "$base/reverse.txt" blocked
ns client "$engine" outcome "$proxy" "$trust" 12s >"$base/during-partition.txt"
ns origin tc -s -j qdisc show dev origin0 >"$base/partition-qdisc.json"
shape 20 0% managed
one_way client 10.77.1.2:9090 origin "$base/healed-reverse.txt" pass
ns client "$engine" outcome "$proxy" "$trust" 12s >"$base/after-partition.txt"
~~~

</details>

### Step 4 — Distinguish delivery from timeout

Compare the two UDP receive logs, the drop counter, and the job response before, during, and after the fault.

<details>
<summary>Hint</summary>

The app and transport probes give different observations about the same direction.

</details>

## Check it

~~~bash
go test -v ./partition
~~~

<!-- run: go test -v ./partition && bash -n experiments/http-live.sh -->

The model classified the one-way failure correctly. The live job request and directed probes show the failure and recovery. [Partition evidence](../evidence/README.md)

## If it goes wrong

If both probes fail, check the addresses, bind readiness, and qdisc direction. If the job stays successful, verify it is using the proxied dependency with caching disabled.
