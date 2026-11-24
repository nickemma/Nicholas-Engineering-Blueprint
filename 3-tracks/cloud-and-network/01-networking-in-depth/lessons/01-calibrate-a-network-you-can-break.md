# 01 Calibrate a network you can break

> Networking in depth · Week 1 · Builds on lesson 00

## The problem

A throughput result is hard to interpret until you know whether packets crossed the link you meant to shape.

## The mental model

Draw client, edge router, and origin in distinct Linux network namespaces. The edge forwards between veth pairs. The origin sends test data toward the client. Measure idle RTT in both directions before sending a bulk transfer.

## The pattern

A queueing discipline acts on egress. Add half the nominal RTT to the two endpoint egress paths and put the shared bottleneck on the edge’s client-facing interface. Bandwidth-delay product (BDP) estimates the bytes in flight on a full link.

## Build it

### Step 1 — Draw and label the path

Write the source and destination IP of a download packet and the interface where it leaves each namespace.

<details>
<summary>Hint</summary>

The data crosses the client-facing edge interface. The return ACK leaves the client first.

</details>

### Step 2 — Build the isolated tools and topology

Add the disposable tools image and create the namespaces and routes. Set delay at the endpoints and use a common rate limiter with two queue options.

<details>
<summary>Hint</summary>

Start each run with fresh qdiscs so their drop counters belong to that configuration.

</details>

<details>
<summary>Implementation</summary>

Create `go.mod`.

<!-- file: go.mod -->
~~~text
module switchyard/netlab

go 1.26.6

require github.com/quic-go/quic-go v0.64.1
~~~

Create `tools/Dockerfile`.

<!-- file: tools/Dockerfile -->
~~~text
FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 iperf3 iputils-ping procps \
 && rm -rf /var/lib/apt/lists/*
~~~

Create `experiments/topology.sh`.

<!-- file: experiments/topology.sh -->
~~~bash
#!/usr/bin/env bash
# Source inside an empty, disposable Linux network environment.
set -euo pipefail

ns() { ip netns exec "$@"; }

topology() {
    for name in client edge origin; do
        ip netns add "$name"
        ip -n "$name" link set lo up
    done
    ip link add client0 netns client type veth peer edge0 netns edge
    ip link add edge1 netns edge type veth peer origin0 netns origin
    ip -n client addr add 10.77.1.2/24 dev client0
    ip -n edge addr add 10.77.1.1/24 dev edge0
    ip -n edge addr add 10.77.2.1/24 dev edge1
    ip -n origin addr add 10.77.2.2/24 dev origin0
    ip -n client link set client0 up
    ip -n edge link set edge0 up
    ip -n edge link set edge1 up
    ip -n origin link set origin0 up
    ip -n client route add 10.77.2.0/24 via 10.77.1.1
    ip -n origin route add 10.77.1.0/24 via 10.77.2.1
    ns edge sysctl -qw net.ipv4.ip_forward=1
}

shape() {
    local half=$1 loss=$2 queue=$3
    ns client tc qdisc del dev client0 root 2>/dev/null || true
    ns origin tc qdisc del dev origin0 root 2>/dev/null || true
    ns edge tc qdisc del dev edge0 root 2>/dev/null || true
    ns client tc qdisc replace dev client0 root netem delay "${half}ms" limit 10000
    ns origin tc qdisc replace dev origin0 root netem delay "${half}ms" loss "$loss" limit 10000
    ns edge tc qdisc replace dev edge0 root handle 1: tbf rate 20mbit burst 16kb latency 2s
    case "$queue" in
        deep) ns edge tc qdisc replace dev edge0 parent 1:1 handle 20: pfifo limit 700 ;;
        managed) ns edge tc qdisc replace dev edge0 parent 1:1 handle 20: fq_codel limit 700 target 5ms interval 100ms ;;
        *) echo 'queue must be deep or managed' >&2; return 2 ;;
    esac
}
~~~

</details>

### Step 3 — Compute the byte budget

Convert 20 Mbit/s and 40 ms into bytes. Use the same units for a window ceiling.

<details>
<summary>Hint</summary>

Divide by eight when converting bits in flight to bytes.

</details>

<details>
<summary>Implementation</summary>

Create `link/budget.go`.

<!-- file: link/budget.go -->
~~~go
// Package link calculates byte budgets for the controlled bottleneck.
package link

import (
	"fmt"
	"time"
)

// Budget uses decimal megabits and returns bytes in flight at the requested RTT.
func Budget(megabits int, rtt time.Duration) (float64, error) {
	if megabits <= 0 || rtt <= 0 {
		return 0, fmt.Errorf("positive rate and RTT required")
	}
	return float64(megabits) * 1e6 * rtt.Seconds() / 8, nil
}

// WindowRate is a byte-window ceiling expressed in decimal megabits per second.
func WindowRate(bytes int, rtt time.Duration) (float64, error) {
	if bytes <= 0 || rtt <= 0 {
		return 0, fmt.Errorf("positive window and RTT required")
	}
	return float64(bytes) * 8 / rtt.Seconds() / 1e6, nil
}
~~~

Create `link/budget_test.go`.

<!-- file: link/budget_test.go -->
~~~go
package link

import (
	"testing"
	"time"
)

func TestByteBudgetAndWindowCeiling(t *testing.T) {
	budget, err := Budget(20, 40*time.Millisecond)
	if err != nil || budget != 100000 {
		t.Fatalf("budget = %v, %v", budget, err)
	}
	ceiling, err := WindowRate(16000, 40*time.Millisecond)
	if err != nil || ceiling != 3.2 {
		t.Fatalf("ceiling = %v, %v", ceiling, err)
	}
	if _, err := Budget(20, 0); err == nil {
		t.Fatal("accepted zero RTT")
	}
	t.Log("a 20 Mbit/s, 40 ms link needs 100000 bytes in flight; a 16000-byte window bounds it to 3.2 Mbit/s")
}
~~~

</details>

### Step 4 — Check the instrument

Keep idle ping output and the bottleneck’s qdisc metadata. The full fixture is assembled by lesson 09.

<details>
<summary>Hint</summary>

Compare goodput measured at the receiver with the link’s configured rate.

</details>

## Check it

~~~bash
go test -v ./link -run TestByteBudgetAndWindowCeiling
~~~

<!-- run: go test -v ./link -run TestByteBudgetAndWindowCeiling -->

The byte-budget check reports 100,000 bytes in flight. A 16,000-byte window gives a modeled ceiling of 3.2 Mbit/s. [Live calibration](../evidence/README.md)

## If it goes wrong

If doubling one endpoint delay produces the wrong RTT, check where the reverse path is delayed. If throughput exceeds the shaper budget, inspect the learned routes and the outgoing interface.
