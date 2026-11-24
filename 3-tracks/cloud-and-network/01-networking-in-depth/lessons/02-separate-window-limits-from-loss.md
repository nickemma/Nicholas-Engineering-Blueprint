# 02 Separate window limits from loss

> Networking in depth · Week 1 · Builds on lesson 01

## The problem

A flow can leave a link idle because its send window is too small. A different flow can slow because it retransmits. Similar goodput needs different evidence.

## The mental model

Write down each trial’s nominal rate and RTT. Change one input at a time from the baseline. Use receiver goodput and sender TCP state, and retain the per-run qdisc counters from the loss direction.

## The pattern

A window ceiling and a simplified Reno estimate answer different questions. The Mathis estimate models steady Reno behavior under simplifying assumptions. Compare the ratios it predicts with the data and avoid treating its output as a CUBIC or BBR prediction.

## Build it

### Step 1 — Write the loss and RTT prediction

Calculate the effect of multiplying loss by four or doubling RTT in the simplified model.

<details>
<summary>Hint</summary>

Compare the loss square root and the RTT term separately.

</details>

<details>
<summary>Implementation</summary>

Create `link/loss.go`.

<!-- file: link/loss.go -->
~~~go
package link

import (
	"fmt"
	"math"
	"time"
)

// RenoEstimate is the simplified Mathis estimate in decimal Mbit/s.
func RenoEstimate(mss int, rtt time.Duration, loss float64) (float64, error) {
	if mss <= 0 || rtt <= 0 || !(loss > 0 && loss < 1) {
		return 0, fmt.Errorf("use a positive MSS and RTT and loss between zero and one")
	}
	return float64(mss) * 8 * math.Sqrt(1.5) / (rtt.Seconds() * math.Sqrt(loss) * 1e6), nil
}
~~~

Create `link/loss_test.go`.

<!-- file: link/loss_test.go -->
~~~go
package link

import (
	"math"
	"testing"
	"time"
)

func TestRenoEstimateRatios(t *testing.T) {
	baseline, _ := RenoEstimate(1448, 40*time.Millisecond, 0.01)
	moreLoss, _ := RenoEstimate(1448, 40*time.Millisecond, 0.04)
	longer, _ := RenoEstimate(1448, 80*time.Millisecond, 0.01)
	if math.Abs(baseline/2-moreLoss) > 1e-9 || math.Abs(baseline/2-longer) > 1e-9 {
		t.Fatal("unexpected loss or RTT ratio")
	}
	if _, err := RenoEstimate(1448, 40*time.Millisecond, 0); err == nil {
		t.Fatal("the model has no loss-free prediction")
	}
	t.Logf("Reno estimate at 1448-byte MSS, 40 ms RTT, and 1%% loss: %.2f Mbit/s", baseline)
}
~~~

</details>

### Step 2 — Build the matched transfer fixture

Keep the destination and bottleneck fixed. Run the default buffer, a smaller socket buffer, lower RTT, and injected loss. Write iperf receiver output and sender socket data to separate files.

<details>
<summary>Hint</summary>

Use a distinct receiver port per transfer. Retain failed control connections alongside the successful attempts.

</details>

<details>
<summary>Implementation</summary>

Create `experiments/transport.sh`.

<!-- file: experiments/transport.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
cd /lab
source experiments/topology.sh
out=/out/transport
mkdir -p "$out"
topology
uname -sr >"$out/kernel.txt"
ns origin cat /proc/sys/net/ipv4/tcp_available_congestion_control >"$out/controllers.txt"
ns client iperf3 -s -D -p 5201
ns client iperf3 -s -D -p 5202
port=6100

capture_queue() {
    ns edge tc -s -j qdisc show dev edge0 >"$out/$1-edge-qdisc.json"
    ns origin tc -s -j qdisc show dev origin0 >"$out/$1-origin-qdisc.json"
}

run_flow() {
    local name=$1 half=$2 loss=$3 controller=$4
    shift 4
    shape "$half" "$loss" deep
    local sender attempt
    for attempt in 1 2 3; do
        port=$((port + 1))
        ns client iperf3 -s -1 -D -p "$port"
        sleep 0.2
        ns origin iperf3 -c 10.77.1.2 -p "$port" -C "$controller" -O 1 -t 2 -J "$@" >"$out/$name.json" &
        sender=$!
        sleep 0.55
        ns origin ss -tin >"$out/$name-ss.txt"
        if wait "$sender"; then
            break
        fi
        cp "$out/$name.json" "$out/$name-attempt-$attempt.json"
        if [[ "$attempt" == 3 ]]; then
            cat "$out/$name.json" >&2
            return 1
        fi
    done
    capture_queue "$name"
}

shape 20 0% deep
ns client ping -n -c 6 -i 0.12 -W 2 10.77.2.2 >"$out/idle-40.txt"
run_flow baseline 20 0% cubic
run_flow short 5 0% cubic
run_flow small-window 20 0% cubic -w 16K
for repeat in 1 2 3; do
    run_flow "loss-$repeat" 20 1% cubic
done
for controller in reno cubic bbr; do
    if ! grep -qw "$controller" "$out/controllers.txt"; then
        printf '%s unavailable\n' "$controller" >>"$out/skipped.txt"
        continue
    fi
    for repeat in 1 2; do
        run_flow "$controller-$repeat" 20 0.3% "$controller"
    done
done

other=reno
if grep -qw bbr "$out/controllers.txt"; then other=bbr; fi
printf 'cubic %s\n' "$other" >"$out/share-controllers.txt"
shape 20 0% deep
ns origin iperf3 -c 10.77.1.2 -p 5201 -C cubic -t 4 -J >"$out/share-1.json" &
first=$!
ns origin iperf3 -c 10.77.1.2 -p 5202 -C "$other" -t 4 -J >"$out/share-2.json" &
second=$!
wait "$first"
wait "$second"

for pair in 1 2 3; do
    queues=(deep managed)
    if (( pair % 2 == 0 )); then queues=(managed deep); fi
    for queue in "${queues[@]}"; do
        name="$queue-$pair"
        shape 20 0% "$queue"
        ns client ping -n -c 5 -i 0.1 -W 2 10.77.2.2 >"$out/$name-idle.txt"
        port=$((port + 1))
        ns client iperf3 -s -1 -D -p "$port"
        sleep 0.2
        ns origin iperf3 -c 10.77.1.2 -p "$port" -C cubic -O 1 -t 2 -J >"$out/$name.json" &
        sender=$!
        sleep 0.55
        ns client ping -n -c 12 -i 0.14 -W 2 10.77.2.2 >"$out/$name-loaded.txt"
        wait "$sender"
        capture_queue "$name"
    done
done
~~~

</details>

### Step 3 — Read an honest comparison

Distinguish requested socket buffer from advertised receive window and congestion window. Look for sender retransmissions and drops where loss was configured.

<details>
<summary>Hint</summary>

The window model describes bytes in flight. A requested socket-buffer size is an input to the live experiment.

</details>

## Check it

~~~bash
go test -v ./link -run TestRenoEstimateRatios
~~~

<!-- run: go test -v ./link -run TestRenoEstimateRatios && bash -n experiments/transport.sh -->

The reference estimate at 1% loss, a 1,448-byte MSS, and 40 ms is 3.55 Mbit/s. The live data includes three independent lossy trials. [Transport capture](../evidence/README.md)

## If it goes wrong

If drop and retransmission counts disagree, check the direction and the sample interval. The qdisc and TCP sender count different events.
