# Networking Bridge teaching: the network under load

Every system in this Blueprint talks over a network, and so far you've mostly treated it as a function call that can fail. Phase 5 added delay with `tc netem` to see what your retries did. This bridge turns the camera around: what does the **network itself** do when it's busy, lossy or far away, and what does that do to your service?

**The goal:** `netlab`, two containers joined by a link you control, and a set of measurements that answer questions you'll be asked in a systems interview, and will need in Phase 8. Why does 1% loss cost 95% of a download? Why does a big buffer make things worse? When is HTTP/3 actually faster? What does a CDN save?

**The rule of the bridge:** the same as Phase 7's. Write down what you predict, run it enough times to see the spread, and believe the measurement. That includes measuring your measuring instrument: in step 2 the first results are wrong, and finding out why teaches more than the results would have.

## How this guide works

- Type the code; don't paste it.
- **CI rebuilds the code and runs its tests.** It can't run the live measurements, which need Docker, `tc` and hours of run time. Those outputs were captured by hand on one laptop (an 8-core Ryzen 7 5850U under WSL2, kernel 6.18). Your numbers will differ. Compare the **ratios and the shape**, not the digits.
- An emulated link isn't the internet. Where that matters, the guide says so.
- **A faulty clock, disclosed.** Steps 3 to 6 ran after the laptop woke from sleep, and its virtual machine's clock then ran about 4–5% fast. Every lab tool times against that same clock, so the ratios and comparisons hold, but absolute milliseconds in those steps may read 4–5% off. The cause turned out to be WSL's two time services fighting, as [JOURNEY's known limits](../../JOURNEY.md) explain. The [maths track](../../math/01-queueing/README.md#the-clock-lied) shows how this was found.
- Each step ends with **Explain it** questions and a **Read** list.

## Setup

You need Go 1.26+ and Docker from earlier phases. Make a new repository, called `netlab`:

<!-- file: go.mod -->
~~~text
module netlab

go 1.26
~~~

<!-- file: .gitignore -->
~~~text
bin/
*.pcap
~~~

---

## Step 1: A network you can break

### What this step teaches

- A lab: two hosts, one link, and a script that sets its delay, rate, loss and queue.
- **Round-trip time, bandwidth, and their product**, the number that explains most of this bridge.
- Reading a live TCP connection with `ss -ti`.

### The lab

Two containers on one Docker network. Nothing else is on that link, so anything you measure is yours. The tools go in one image:

<!-- file: tools/Dockerfile -->
~~~text
# Network measurement tools for the lab's containers.
FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 iperf3 iputils-ping tcpdump kmod ethtool curl procps \
 && rm -rf /var/lib/apt/lists/*
~~~

<!-- file: compose.yaml -->
~~~yaml
# Two hosts joined by one link. tc on each side shapes what it sends.
name: netlab
services:
  client: &host
    image: nettools
    build: tools
    command: sleep infinity
    cap_add: [NET_ADMIN]
    volumes: [".:/lab"]
    working_dir: /lab
  server:
    <<: *host
~~~

`cap_add: [NET_ADMIN]` lets a container change its own network settings, which is all `tc` needs. It gets no power over the host, unlike the privileged container from the Performance Bridge.

**`tc netem`** ("network emulator") is a queueing discipline: a kernel component that decides what happens to packets on their way out of an interface. You met it in Phase 5, where it added delay. It can also drop packets and limit the rate. Each side shapes only what it **sends**, so the script below splits the delay across both sides, and puts the rate limit and the loss on the server's side. Downloads then cross the bottleneck, as they do on a real last mile.

<!-- file: link.sh -->
~~~bash
#!/bin/sh
# Shape the link between client and server.
#   ./link.sh 40ms 100mbit 0%           RTT, rate, loss on the way to the client
#   ./link.sh 40ms 100mbit 0% 350       ...and a queue of 350 packets
#   ./link.sh off
set -eu
c() { docker compose exec -T "$@"; }
if [ "$1" = off ]; then
  c client tc qdisc del dev eth0 root 2>/dev/null || true
  c server tc qdisc del dev eth0 root 2>/dev/null || true
  exit 0
fi
half=$(( ${1%ms} / 2 ))ms
limit=${4:-10000}
# Half the delay each way. The bottleneck and the loss are on data going
# from server to client, the direction iperf3 -R and downloads use.
c client tc qdisc replace dev eth0 root netem delay "$half"
c server tc qdisc replace dev eth0 root netem delay "$half" loss "$3" rate "$2" limit "$limit"
~~~

<!-- run: chmod +x link.sh && sh -n link.sh -->

Start it, and load the two kernel modules the lab uses. On most Linux machines they load themselves; under WSL2 you may need to do it by hand. A WSL restart unloads them.

~~~bash
chmod +x link.sh
docker compose up -d --build
docker run --rm --privileged -v /lib/modules:/lib/modules:ro nettools modprobe -a tcp_bbr sch_netem
cat /proc/sys/net/ipv4/tcp_available_congestion_control
~~~

~~~text
reno cubic bbr
~~~

That last line matters in step 3. If `bbr` isn't there, the kernel doesn't have it as a module: step 3 will work with `reno` and `cubic`, and you should read its BBR results as given here.

### Round-trip time

With no shaping, the two containers are about as close as two computers get:

~~~bash
docker compose exec client ping -c 5 -q server
~~~

~~~text
5 packets transmitted, 5 received, 0% packet loss, time 4053ms
rtt min/avg/max/mdev = 0.098/0.576/2.180/0.804 ms
~~~

Now put a few thousand kilometres between them. 40 ms is about what a long trip inside Europe or across part of the US costs:

~~~bash
./link.sh 40ms 100mbit 0%
docker compose exec client ping -c 5 server
~~~

~~~text
PING server (172.25.0.3) 56(84) bytes of data.
64 bytes from netlab-server-1.netlab_default (172.25.0.3): icmp_seq=1 ttl=64 time=40.7 ms
64 bytes from netlab-server-1.netlab_default (172.25.0.3): icmp_seq=2 ttl=64 time=40.5 ms
64 bytes from netlab-server-1.netlab_default (172.25.0.3): icmp_seq=3 ttl=64 time=41.1 ms
64 bytes from netlab-server-1.netlab_default (172.25.0.3): icmp_seq=4 ttl=64 time=40.7 ms
64 bytes from netlab-server-1.netlab_default (172.25.0.3): icmp_seq=5 ttl=64 time=40.3 ms

--- server ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4007ms
rtt min/avg/max/mdev = 40.335/40.669/41.089/0.259 ms
~~~

**Round-trip time (RTT)** is how long a message takes to get there and for the answer to come back. You can't engineer it away: light in fibre covers about 200 km per millisecond, so a round trip across the Atlantic can't be under about 55 ms. It's made of **propagation** (distance), **serialisation** (putting bits on the wire), **processing**, and **queueing**, which is the only part that changes with load. Keep an eye on that last one.

### Bandwidth

`iperf3` measures how much data fits through. `-R` means reverse: the server sends, so the data crosses the bottleneck.

~~~bash
docker compose exec -d server iperf3 -s
docker compose exec client iperf3 -c server -R -t 10 -f m
~~~

~~~text
Connecting to host server, port 5201
Reverse mode, remote host server is sending
[  5] local 172.25.0.2 port 57006 connected to 172.25.0.3 port 5201
[ ID] Interval           Transfer     Bitrate
[  5]   0.00-1.00   sec  9.38 MBytes  78.6 Mbits/sec                  
[  5]   1.00-2.00   sec  11.5 MBytes  96.5 Mbits/sec                  
[  5]   2.00-3.00   sec  11.4 MBytes  95.4 Mbits/sec                  
[  5]   3.00-4.00   sec  11.4 MBytes  95.4 Mbits/sec                  
[  5]   4.00-5.00   sec  11.4 MBytes  95.4 Mbits/sec                  
[  5]   5.00-6.00   sec  11.4 MBytes  95.4 Mbits/sec                  
[  5]   6.00-7.00   sec  11.5 MBytes  96.5 Mbits/sec                  
[  5]   7.00-8.00   sec  11.4 MBytes  95.4 Mbits/sec                  
[  5]   8.00-9.00   sec  11.4 MBytes  95.4 Mbits/sec                  
[  5]   9.00-10.00  sec  11.4 MBytes  95.4 Mbits/sec                  
- - - - - - - - - - - - - - - - - - - - - - - - -
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-10.04  sec   116 MBytes  97.1 Mbits/sec    0             sender
[  5]   0.00-10.00  sec   112 MBytes  93.9 Mbits/sec                  receiver

iperf Done.
~~~

Three things to notice:

- **The first second is slower.** TCP starts cautiously and doubles its sending rate every round trip until it finds the limit. That's **slow start**.
- **The steady rate is 95.4 Mbit/s, not 100.** The link carries 1,514 bytes for every 1,448 bytes of your data; the rest is headers. 1,448 ÷ 1,514 = 95.7%.
- **The sender reports more than the receiver.** The sender counts what it handed to the kernel, some of which was still queued when the test ended. Trust the receiver line.

### The bandwidth-delay product

A link isn't only a rate. It's a pipe with a **volume**. Bits take time to cross it, so when it's full, a certain amount of data is in the air, sent but not yet acknowledged:

```
bandwidth-delay product = rate × RTT
                        = 100,000,000 bits/s × 0.040 s
                        = 4,000,000 bits = 500,000 bytes
                        ≈ 345 segments of 1,448 bytes
```

TCP may only have a limited amount of unacknowledged data out at once: the smaller of the **congestion window** (the sender's estimate of what the network will take) and the **receive window** (what the receiver has room for). So:

```
rate ≤ window / RTT
```

To fill this link, the window must be at least 500 KB. Test that. `-w` fixes the socket's buffer size, which turns off the kernel's automatic tuning:

~~~bash
for w in 16K 64K 256K 1M; do
  echo "window $w: $(docker compose exec client iperf3 -c server -R -t 8 -O 2 -w $w -f m | awk '/receiver/ {print $7, $8}')"
done
~~~

~~~text
window 16K: 3.93 Mbits/sec
window 64K: 18.0 Mbits/sec
window 256K: 67.9 Mbits/sec
window 1M: 95.6 Mbits/sec
~~~

Only the 1M window reaches the link's limit. The others are capped by the window, and the shape is what the formula says: four times the window, about four times the rate. The digits run a bit higher than you'd calculate, because the kernel doubles the buffer you ask for and keeps a share for bookkeeping. `ss` showed a real window (`snd_wnd`) of 78,336 bytes for `64K`, and 391,416 for `256K`.

**Why this matters in production.** The same 256 KB window that's plenty across a data centre (RTT 0.5 ms) gives only about 68 Mbit/s here. On a 10 Gbit/s link between regions with a 100 ms RTT, the bandwidth-delay product is 125 MB, far more than a default maximum buffer. Look at yours:

~~~bash
docker compose exec server cat /proc/sys/net/ipv4/tcp_wmem /proc/sys/net/ipv4/tcp_rmem
~~~

~~~text
4096	16384	4194304
4096	131072	33554432
~~~

Minimum, default, maximum, in bytes. The send buffer tops out at 4 MB here, so a single connection at a 100 ms RTT can't go much above 4 MB × 8 ÷ 0.1 s ≈ 335 Mbit/s, however fast the link is. "We have a 10 Gbit/s link and a backup crawls" is often this.

### Reading a live connection

`ss -ti` prints the kernel's own state for each TCP connection. Start a transfer in one terminal:

~~~bash
docker compose exec client iperf3 -c server -R -t 8 -f m -C cubic
~~~

and look at it from another, while it runs:

~~~bash
docker compose exec server ss -tin 'sport = :5201'
~~~

`iperf3` has two connections: a control one that sits idle, and the data one. Here's the data one, trimmed:

~~~text
ESTAB 0      3156504 [::ffff:172.25.0.3]:5201 [::ffff:172.25.0.2]:38694
	 cubic wscale:10,10 rto:476 rtt:272.95/1.265 mss:1448 pmtu:1500 cwnd:2376 ssthresh:494
	 send 100837457bps pacing_rate 121004944bps delivery_rate 95874040bps unacked:2180 minrtt:40.286 snd_wnd:6231040
~~~

| Field | Meaning |
|---|---|
| `cubic` | The congestion control algorithm |
| `mss:1448` | Bytes of data per segment |
| `cwnd:2376` | Congestion window, in segments |
| `ssthresh:494` | Where slow start stopped |
| `rtt:272.95/1.265` | Smoothed RTT and its variation, in ms |
| `minrtt:40.286` | The lowest RTT seen: the path with nothing queued |
| `delivery_rate` | What's actually arriving |
| `unacked:2180` | Segments in flight |
| `snd_wnd:6231040` | The receive window, in bytes |

Now look at those numbers together, because something's wrong. The window is 2,376 segments; the pipe holds 345. The RTT is **273 ms** on a 40 ms link. The sender has 2,180 segments unacknowledged, more than six times what's needed. The delivery rate is no better for it.

Those extra packets aren't on the wire. They're sitting in the queue in front of the bottleneck, and that queue is why the RTT is nearly seven times what it should be: (2,180 − 345) packets × 1,514 bytes × 8 ÷ 100 Mbit/s ≈ 222 ms of waiting, plus 40 ms of distance. You've found **bufferbloat** by accident, and you'll come back to it in step 3.

**Explain it:** Which part of RTT changes with load? Why is the receiver's figure the one to trust? What's the bandwidth-delay product of a 1 Gbit/s link with a 200 ms RTT, and what window does it need? Why did a 64 KB window limit the rate when the link had room to spare? From the `ss` output alone, how can you tell the queue is full?

**Read.** Peterson and Davie, [*Computer Networks: A Systems Approach*](https://book.systemsapproach.org/), chapters 1 and 5. The man pages for [`tc-netem`](https://man7.org/linux/man-pages/man8/tc-netem.8.html) and [`ss`](https://man7.org/linux/man-pages/man8/ss.8.html).

---

## Step 2: What loss does to TCP

### What this step teaches

- **Checking your instrument** before you trust it, and what happens when you don't.
- Why TCP treats loss as a signal, and the **Mathis formula** that follows from it.
- What a loss looks like on the wire: duplicate ACKs, **SACK** and **fast retransmit**.

### Does the link do what you told it?

The plan is to set a loss rate, measure throughput, and compare with theory. But `./link.sh 40ms 100mbit 1%` only **asks** the kernel to drop 1%. Before building on that, count what it really did. `tc -s` reports how many packets a queue sent and dropped:

<!-- file: experiments/drops.sh -->
~~~bash
#!/bin/bash
# Set a loss rate, send data, and count what the link really dropped.
# Prints: set-rate packets dropped dropped% retransmits Mbit/s
set -eu
c() { docker compose exec -T "$@"; }
counts() { c server tc -s qdisc show dev eth0 | awk '/Sent/ {print $4, $7}' | tr -d ','; }
c -d server sh -c 'pgrep iperf3 || iperf3 -s' 2>/dev/null
sleep 1
printf '%-7s %8s %8s %9s %8s %7s\n' set packets dropped 'dropped%' retrans Mbit/s
for loss in "$@"; do
  ./link.sh 40ms 100mbit "$loss"
  read -r p0 d0 < <(counts)
  out=$(c client iperf3 -c server -R -t 13 -C reno -f m)
  read -r p1 d1 < <(counts)
  p=$((p1 - p0)) d=$((d1 - d0))
  retrans=$(echo "$out" | awk '/sender/ {print $9}')
  mbps=$(echo "$out" | awk '/sender/ {print $7}')
  awk -v s="$loss" -v p=$p -v d=$d -v r="$retrans" -v m="$mbps" \
    'BEGIN {printf "%-7s %8d %8d %8.3f%% %8s %7s\n", s, p, d, 100*d/(p+d), r, m}'
done
~~~

Before you run it, predict: at 0.1% on a transfer of 100,000 packets, how many drops?

<!-- run: chmod +x experiments/drops.sh && bash -n experiments/drops.sh -->

~~~bash
chmod +x experiments/drops.sh
./experiments/drops.sh 0.01% 0.1% 1%
~~~

~~~text
set      packets  dropped  dropped%  retrans  Mbit/s
0.01%     108756        0    0.000%        0    96.6
0.1%      106517        5    0.005%       46    95.5
1%         28902       42    0.145%      204    27.5
~~~

That's wrong. At 0.1% you should have seen about 100 drops, and there were **5**. At 0.01%, about 10, and there were **none**, with the transfer at full speed. Had you skipped this check, you'd now be plotting a graph showing TCP shrugging off loss.

There's a second clue. At 0.1%, 5 drops caused 46 retransmissions. One lost packet should mean one retransmission, not nine.

The usual suspect is offload: the kernel handing big buffers to the network card to split. Turn it off:

~~~bash
docker compose exec server ethtool -K eth0 tso off gso off
./experiments/drops.sh 0.01% 0.1%
~~~

~~~text
set      packets  dropped  dropped%  retrans  Mbit/s
0.01%     107917        1    0.001%       20    95.8
0.1%       20169       10    0.050%       23    18.7
~~~

Slightly different, still wrong: 1 drop where there should be 10, and 20 retransmissions from it.

Here's what's going on. Writing one packet at a time through the whole network stack is expensive, so Linux TCP builds a large buffer of up to 64 KB, and passes it down as **one** unit. Something splits it into real packets as late as possible. That's **GSO**, generic segmentation offload, and modern TCP always works this way; `ethtool` only decides whether the splitting happens in the network card or in software just before it. Either way, **the split happens after the queueing discipline**.

So netem, which sits in the queueing discipline, sees a burst of many packets as one item, and tosses its coin once. A loss drops the whole burst. The counter says 1 drop; the receiver is missing 20 packets. And since a fast sender builds bigger bursts, loss hits it less often but harder. That isn't what a real lossy link does.

The fix is to tell the kernel this interface takes bursts of one packet:

<!-- edit: link.sh -->
~~~bash
half=$(( ${1%ms} / 2 ))ms
~~~
~~~bash
# TCP hands the qdisc bursts of up to 64 KB, split up after it. One burst,
# one coin toss: send packets one at a time, so loss means what it says.
c server ip link set dev eth0 gso_max_segs 1
c client ip link set dev eth0 gso_max_segs 1
half=$(( ${1%ms} / 2 ))ms
~~~

Put the offload back, and check again:

~~~bash
docker compose exec server ethtool -K eth0 tso on gso on
./experiments/drops.sh 0.01% 0.1% 1%
~~~

~~~text
set      packets  dropped  dropped%  retrans  Mbit/s
0.01%      73769        6    0.008%        6    66.4
0.1%       18580       18    0.097%       18    17.5
1%          3623       39    1.065%       38    3.22
~~~

The dropped percentage matches what was asked, and retransmissions match drops almost one for one. Now the instrument works. Notice that in fixing it you also got the real result: at 1%, the speed fell from 27.5 Mbit/s to 3.2.

**The lesson is bigger than netem.** You saw a tool report success while doing something else, and only a number from a **different** place (the retransmit count, disagreeing with the drop count) gave it away. When a measurement looks too good, or an AI assistant gives you an experiment that runs cleanly, ask what independent number would show it's wrong.

### Why TCP slows down

The internet gives senders no signal about how much capacity is free. Reno, the classic algorithm, works it out by probing:

- **Additive increase:** each round trip without loss, add one segment to the window.
- **Multiplicative decrease:** on a loss, cut the window in half.

Loss is the signal, on the assumption that it means a queue somewhere overflowed. The result is a **sawtooth**: the window climbs slowly to some *W*, halves to *W*/2, and climbs again.

You can work out the rate from that shape. One tooth takes *W*/2 round trips, and carries about 3*W*²/8 packets. If a packet is lost with probability *p*, then one loss comes every 1/*p* packets, so 3*W*²/8 = 1/*p*. The average window is 3*W*/4, and rate is window over RTT. Put them together:

```
                 MSS       C
throughput  ≈  ------ × -------      where C = sqrt(3/2) ≈ 1.22
                 RTT    sqrt(p)
```

This is the **Mathis formula** (1997). It says something uncomfortable. Throughput falls with the **square root** of loss, not in proportion: four times the loss, half the speed. And it's divided by RTT, so the same loss hurts a distant user twice as much as one half as far away.

Put it in code, with the numbers you'll need:

<!-- file: model/model.go -->
~~~go
// Package model holds the back-of-the-envelope formulas the experiments
// are checked against.
package model

import (
	"math"
	"time"
)

// BDP returns the bandwidth-delay product in bytes: how much data is in
// flight on a full link of rate bits/s and round-trip time rtt.
func BDP(rate float64, rtt time.Duration) float64 {
	return rate * rtt.Seconds() / 8
}

// Mathis predicts Reno's long-run throughput in bits/s, for segments of
// mss bytes and a chance p of losing a packet: (MSS/RTT) * (C/sqrt(p)).
func Mathis(mss int, rtt time.Duration, p float64) float64 {
	const c = 1.22 // sqrt(3/2), from the sawtooth's geometry
	return float64(mss) * 8 / rtt.Seconds() * c / math.Sqrt(p)
}
~~~

<!-- file: model/model_test.go -->
~~~go
package model

import (
	"math"
	"testing"
	"time"
)

func near(got, want float64) bool { return math.Abs(got-want) < want/1000 }

func TestBDP(t *testing.T) {
	if got := BDP(100e6, 40*time.Millisecond); !near(got, 500_000) {
		t.Errorf("BDP = %v, want 500,000 bytes", got)
	}
}

func TestMathis(t *testing.T) {
	// 1448*8/0.04 = 289,600 bits/s; 1.22/sqrt(0.0001) = 122.
	if got := Mathis(1448, 40*time.Millisecond, 0.0001); !near(got, 35_331_200) {
		t.Errorf("Mathis = %v, want 35.3 Mbit/s", got)
	}
}

func TestQuadruplingLossHalvesThroughput(t *testing.T) {
	a := Mathis(1448, 40*time.Millisecond, 0.001)
	b := Mathis(1448, 40*time.Millisecond, 0.004)
	if !near(b, a/2) {
		t.Errorf("got %v and %v, want a ratio of 2", a, b)
	}
}
~~~

<!-- file: cmd/mathis/main.go -->
~~~go
// Command mathis prints Reno's predicted throughput at each loss rate given
// on the command line, in percent.
package main

import (
	"flag"
	"fmt"
	"log"
	"strconv"
	"time"

	"netlab/model"
)

func main() {
	mss := flag.Int("mss", 1448, "segment size in bytes")
	rtt := flag.Duration("rtt", 40*time.Millisecond, "round-trip time")
	flag.Parse()
	for _, arg := range flag.Args() {
		pct, err := strconv.ParseFloat(arg, 64)
		if err != nil {
			log.Fatalf("bad loss rate %q: %v", arg, err)
		}
		fmt.Printf("%6.2f%%  %8.2f Mbit/s\n", pct, model.Mathis(*mss, *rtt, pct/100)/1e6)
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go build -o bin/ ./cmd/... -->

~~~bash
go test ./... && go build -o bin/ ./cmd/...
./bin/mathis 0.01 0.03 0.1 0.3 1
~~~

~~~text
  0.01%     35.33 Mbit/s
  0.03%     20.40 Mbit/s
  0.10%     11.17 Mbit/s
  0.30%      6.45 Mbit/s
  1.00%      3.53 Mbit/s
~~~

Those are your predictions, written down before the experiment. On a 95 Mbit/s link, 1% loss should leave 3.5.

### The experiment

One run proves little: at 0.01% loss a whole run contains only a few loss events. So plan it the way Phase 7 does: repeat each setting, shuffle the order so that slow drift on the machine doesn't line up with one setting, and report a median with a confidence interval. Each run is 60 seconds, and the first 10 are left out, since they're slow start and not the long run the formula describes.

<!-- file: experiments/mathis.sh -->
~~~bash
#!/bin/bash
# Reno's throughput at each loss rate, in shuffled order, on a 100 Mbit/s,
# 40 ms link. Appends "loss mbps" lines to results/mathis.txt.
# The first 10 seconds are left out: they're slow start, not the long run.
set -eu
mkdir -p results
c() { docker compose exec -T "$@"; }
c -d server sh -c 'pgrep iperf3 || iperf3 -s' 2>/dev/null
for run in $(seq 1 "${REPEATS:-5}"); do
  for loss in $(printf '%s\n' 0.01% 0.03% 0.1% 0.3% 1% | shuf); do
    ./link.sh 40ms 100mbit "$loss"
    mbps=$(c client iperf3 -c server -R -t 60 -O 10 -C reno -f m | awk '/receiver/ {print $7}')
    echo "$loss $mbps" | tee -a results/mathis.txt
  done
done
~~~

And the summary, using the bootstrap from Phase 7:

<!-- file: stats/stats.go -->
~~~go
// Package stats summarises repeated measurements: a median, with a
// percentile-bootstrap confidence interval (Phase 7, step 1).
package stats

import (
	"math/rand/v2"
	"slices"
)

// Median returns the middle of values, which must not be empty.
func Median(values []float64) float64 {
	s := slices.Sorted(slices.Values(values))
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

// Interval returns a 95% bootstrap interval for the median of values:
// resample with replacement many times, and take the middle 95% of the
// resampled medians. A fixed seed makes the same data give the same answer.
func Interval(values []float64) (low, high float64) {
	const rounds = 2000
	rng := rand.New(rand.NewPCG(1, 2))
	medians := make([]float64, rounds)
	sample := make([]float64, len(values))
	for i := range medians {
		for j := range sample {
			sample[j] = values[rng.IntN(len(values))]
		}
		medians[i] = Median(sample)
	}
	slices.Sort(medians)
	return medians[rounds*25/1000], medians[rounds*975/1000]
}
~~~

<!-- file: stats/stats_test.go -->
~~~go
package stats

import "testing"

func TestMedian(t *testing.T) {
	cases := []struct {
		values []float64
		want   float64
	}{
		{[]float64{3, 1, 2}, 2},
		{[]float64{4, 1, 3, 2}, 2.5},
		{[]float64{7}, 7},
	}
	for _, c := range cases {
		if got := Median(c.values); got != c.want {
			t.Errorf("Median(%v) = %v, want %v", c.values, got, c.want)
		}
	}
}

func TestMedianLeavesItsInputAlone(t *testing.T) {
	v := []float64{3, 1, 2}
	Median(v)
	if v[0] != 3 {
		t.Errorf("input changed to %v", v)
	}
}

func TestIntervalContainsTheMedianAndNarrowsWithData(t *testing.T) {
	few := []float64{10, 11, 12, 13, 50}
	low, high := Interval(few)
	if low > 12 || high < 12 {
		t.Errorf("interval [%v, %v] misses the median 12", low, high)
	}
	var many []float64
	for range 20 {
		many = append(many, few...)
	}
	l2, h2 := Interval(many)
	if h2-l2 >= high-low {
		t.Errorf("more data should narrow it: [%v, %v] against [%v, %v]", l2, h2, low, high)
	}
}
~~~

<!-- file: cmd/summarise/main.go -->
~~~go
// Command summarise reads "label value" lines from stdin and prints, for
// each label in first-seen order, the run count, median and 95% interval.
package main

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"

	"netlab/stats"
)

func main() {
	var order []string
	values := map[string][]float64{}
	in := bufio.NewScanner(os.Stdin)
	for in.Scan() {
		fields := strings.Fields(in.Text())
		if len(fields) < 2 {
			continue
		}
		label := strings.Join(fields[:len(fields)-1], " ")
		v, err := strconv.ParseFloat(fields[len(fields)-1], 64)
		if err != nil {
			log.Fatalf("bad value in %q: %v", in.Text(), err)
		}
		if _, ok := values[label]; !ok {
			order = append(order, label)
		}
		values[label] = append(values[label], v)
	}
	for _, label := range order {
		v := values[label]
		low, high := stats.Interval(v)
		fmt.Printf("%-32s n=%-3d median %9.2f   95%% CI %9.2f to %9.2f\n", label, len(v), stats.Median(v), low, high)
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test ./... && go build -o bin/ ./cmd/... && chmod +x experiments/mathis.sh -->

It takes about 30 minutes. Start it and leave the machine alone: anything else running counts as noise.

~~~bash
go build -o bin/ ./cmd/...
chmod +x experiments/mathis.sh
./experiments/mathis.sh
sort results/mathis.txt | ./bin/summarise
~~~

| Loss | Predicted (Mbit/s) | Measured median, 5 runs | 95% interval | Share of the link left |
|---|---|---|---|---|
| 0.01% | 35.3 | 34.4 | 32.7 to 41.9 | 36% |
| 0.03% | 20.4 | 19.5 | 19.3 to 22.8 | 20% |
| 0.1% | 11.2 | 11.4 | 10.6 to 11.8 | 12% |
| 0.3% | 6.45 | 6.57 | 6.24 to 7.18 | 7% |
| 1% | 3.53 | 3.32 | 3.29 to 3.58 | 3.5% |

Every prediction is inside its interval. A formula from a few lines of algebra about a sawtooth predicts a real kernel's throughput over two orders of magnitude of loss, to within a few percent. **One lost packet in a hundred costs Reno more than 96% of this link.**

Be careful how far you take that. Five runs give a rough interval, the widest at 0.01%, where a run has few loss events. The agreement is also a little better than the model deserves: it ignores timeouts and slow start, and this loss is random and independent, where real loss tends to come in bursts. On this link, at this RTT, it holds. And Reno isn't what your servers run; that's the next step.

### What a loss looks like on the wire

Capture a short transfer at 1% loss, from the client's side:

~~~bash
./link.sh 40ms 100mbit 1%
docker compose exec -d client timeout 6 tcpdump -i eth0 -nn -S -w /lab/results/loss.pcap 'tcp port 5201'
docker compose exec client iperf3 -c server -R -t 4 -C reno -f m
docker compose exec client tcpdump -nn -S -r /lab/results/loss.pcap | grep -m5 -B2 'sack [0-9]'
~~~

`-S` prints real sequence numbers, and each number counts bytes of the stream. Here's the first loss in that capture, trimmed (headers and timestamps options removed):

~~~text
18:21:33.235602 client > [.], ack 1143080889
18:21:33.235605 client > [.], ack 1143080889, [sack 1 {1143082337:1143083785}]
18:21:33.235808 client > [.], ack 1143080889, [sack 1 {1143082337:1143085233}]
18:21:33.235851 client > [.], ack 1143080889, [sack 1 {1143082337:1143086681}]
...
18:21:33.259685 server > [.], seq 1143180801:1143182249
18:21:33.259810 server > [P.], seq 1143080889:1143082337
18:21:33.259938 server > [.], seq 1143182249:1143183697
...
18:21:33.280015 client > [.], ack 1143106953, [sack 1 {1143108401:1143182249}]
~~~

Read it as a conversation:

1. **`ack 1143080889`:** the client has everything before that byte. An ACK is cumulative, so it can only name the first hole.
2. **The same ACK again**, with a new field. **SACK** (selective acknowledgement) adds "but I also have 1143082337 to 1143083785". The missing segment is the 1,448 bytes between: 1143080889 to 1143082337. These repeats are **duplicate ACKs**.
3. **The SACK block keeps growing** as later segments arrive. Three duplicates are enough for the sender to conclude the packet is lost, and not just late. That's **fast retransmit**: no waiting for a timeout.
4. **`seq 1143080889:1143082337`** appears among much higher sequence numbers. That's the retransmission, going out of order.
5. **`ack 1143106953`:** the ACK jumps forward by 26 KB, past everything that had been waiting. Note the new `sack`: a second hole, at 1143106953, has already been found.

Why does the retransmission show up 24 ms after the first SACK, when the RTT is 40? Because of where `tcpdump` sits. It sees outgoing packets **after** the queueing discipline, so the client's ACKs are shown with their 20 ms delay already spent. The confirming ACK shows that too: the retransmission arrives at .2598, and the ACK for it appears at .2800. Knowing where your capture point is matters as much as what it shows.

Point 5 of that list hides something you'll need in step 4. Those 26 KB had arrived, and were waiting in the kernel, but TCP delivers bytes **in order**, so the application could have none of it until the hole was filled. Remember that.

**Explain it:** Why did 5 drops cause 46 retransmissions? Why didn't `ethtool` fix it? What did `tc` count that was misleading? Derive the Mathis formula on paper. If loss goes from 0.1% to 0.4%, what happens to throughput? And if RTT goes from 40 ms to 160 ms? Why is an ACK alone unable to say what's missing? Why three duplicates, and not one?

**Read.** Mathis, Semke, Mahdavi and Ott, [*The Macroscopic Behavior of the TCP Congestion Avoidance Algorithm*](https://dl.acm.org/doi/10.1145/263932.264023) (1997). [RFC 2018](https://www.rfc-editor.org/rfc/rfc2018) (SACK) and [RFC 5681](https://www.rfc-editor.org/rfc/rfc5681) (congestion control). Linux's [segmentation offload notes](https://docs.kernel.org/networking/segmentation-offloads.html).

---

## Step 3: Congestion control

### What this step teaches

- **CUBIC** and **BBR**, and what each one treats as a signal.
- **Bufferbloat:** why a bigger queue makes a network worse.
- **Fairness:** why the fastest algorithm in a test can be a bad neighbour.

### Three ideas about the same problem

| Algorithm | Signal | Idea |
|---|---|---|
| **Reno** | Loss | Add one segment per round trip; halve on a loss |
| **CUBIC** | Loss | After a loss, cut by 30%, and grow along a cubic curve in *time*: fast at first, flat near the old maximum, then probing beyond it |
| **BBR** | Measured rate and RTT | Keep a model of the path: the highest delivery rate and the lowest RTT seen. Send at that rate, with about one bandwidth-delay product in flight, and treat loss as mostly noise |

CUBIC has been Linux's default for many years. Check yours:

~~~bash
docker compose exec server cat /proc/sys/net/ipv4/tcp_congestion_control
~~~

~~~text
cubic
~~~

Reno and CUBIC both believe "loss means full queue", and both fill the queue until it overflows, because that's how they find the limit. BBR (2016) came from Google noticing two things: on modern links, a lot of loss has nothing to do with congestion, and queues are often enormous. So it asks a different question: what's the fastest this path has delivered, and what's its RTT with nothing queued?

### Experiment 1: under loss

The same plan as step 2, with three algorithms. `iperf3 -C` chooses the algorithm for the sending side. If you're in doubt that it took effect, `ss -ti` names it on the first line.

<!-- file: experiments/loss.sh -->
~~~bash
#!/bin/bash
# Throughput of each congestion control at each loss rate, on a 100 Mbit/s,
# 40 ms link, in shuffled order. Appends "cc loss mbps" lines to results/loss.txt.
set -eu
mkdir -p results
c() { docker compose exec -T "$@"; }
c -d server sh -c 'pgrep iperf3 || iperf3 -s' 2>/dev/null
for run in $(seq 1 "${REPEATS:-5}"); do
  for job in $(for cc in reno cubic bbr; do for l in 0% 0.01% 0.1% 1%; do echo "$cc,$l"; done; done | shuf); do
    cc=${job%,*}; loss=${job#*,}
    ./link.sh 40ms 100mbit "$loss"
    mbps=$(c client iperf3 -c server -R -t 30 -O 5 -C "$cc" -f m | awk '/receiver/ {print $7}')
    echo "$cc $loss $mbps" | tee -a results/loss.txt
  done
done
~~~

<!-- run: chmod +x experiments/loss.sh && bash -n experiments/loss.sh -->

Predict before you run: at 1% loss, which wins, and by how much? It takes about 37 minutes, for 60 runs of 30 seconds.

~~~bash
chmod +x experiments/loss.sh
./experiments/loss.sh
sort results/loss.txt | ./bin/summarise
~~~

Medians of five runs, in Mbit/s, with the interval where it's wide enough to matter:

| Loss | Reno | CUBIC | BBR |
|---|---|---|---|
| 0% | 95.6 | 95.6 | 93.4 |
| 0.01% | 36.3 (25.6 to 66.3) | 44.1 (29.0 to 48.9) | 93.4 |
| 0.1% | 11.3 | 10.6 | 92.3 |
| 1% | 3.32 | 3.22 | 91.3 |

**BBR holds 91 Mbit/s at 1% loss, where the others get 3.** It simply doesn't respond to this loss. Look at it running:

~~~bash
./link.sh 40ms 100mbit 1%
docker compose exec client iperf3 -c server -R -t 8 -C bbr -f m
~~~

and, while that runs, from another terminal:

~~~bash
docker compose exec server ss -tin 'sport = :5201'
~~~

~~~text
bbr wscale:10,10 rto:244 rtt:41.412/0.1 mss:1448 cwnd:323 bytes_sent:64199976 bytes_retrans:637120
bbr:(bw:98097824bps,mrtt:40,pacing_gain:1,cwnd_gain:2) pacing_rate 97116840bps delivery_rate 93184648bps
~~~

That's the model: `bw` is about 98 Mbit/s, and `mrtt` is 40 ms. The window of 323 segments is close to the 345 the pipe holds, and `bytes_retrans` is 1.0% of `bytes_sent`: every lost packet is resent, without any slowing down.

Two other readings deserve care:

- **CUBIC did not beat Reno here,** though it's the newer algorithm. Their intervals overlap at every loss rate. CUBIC's gain shows up on paths with a much larger bandwidth-delay product. On one this size, it deliberately stays close to Reno's rate, so as not to crowd Reno out. Don't report 44 against 36 at 0.01% as a win: these runs are 30 seconds long, each contains few loss events, and the intervals are huge.
- **With no loss, BBR is a little slower,** 93.4 against 95.6. Every ten seconds it deliberately drains the queue to re-measure the minimum RTT. That costs about 2%, and the next experiment shows what it buys.

If you stopped here, you'd conclude that BBR is simply better. This is the point in a blog post where people do. Keep going.

### Experiment 2: what's in the queue

A router's buffer absorbs bursts. How large should it be? For decades the answer was "large", because memory got cheap and dropped packets looked bad in vendors' benchmarks. The result is **bufferbloat**: buffers holding seconds of data. Loss-based senders fill whatever queue they're given, so a big queue adds delay for **everyone** using the link, including the video call sharing it with your download.

You saw this by accident in step 1. Now measure it. A ping shares the queue with the transfer, so it reports what any other traffic would experience:

<!-- file: experiments/bloat.sh -->
~~~bash
#!/bin/bash
# What each congestion control does to latency, at each queue size. No loss:
# drops come only from the queue overflowing. Appends
# "cc queue mbps ping-ms" lines to results/bloat.txt; ping-ms is the average
# RTT that a ping saw while the transfer ran.
set -eu
mkdir -p results
c() { docker compose exec -T "$@"; }
c -d server sh -c 'pgrep iperf3 || iperf3 -s' 2>/dev/null
for run in $(seq 1 "${REPEATS:-3}"); do
  for job in $(for cc in reno cubic bbr; do for q in 100 345 3450; do echo "$cc,$q"; done; done | shuf); do
    cc=${job%,*}; q=${job#*,}
    # netem's limit also counts the 172 packets it's holding for the 20 ms
    # delay, so add them: q is what's left for a queue.
    ./link.sh 40ms 100mbit 0% $((q + 172))
    c client iperf3 -c server -R -t 30 -O 10 -C "$cc" -f m > results/.iperf &
    sleep 15
    ms=$(c client ping -i 0.2 -c 50 -q server | awk -F/ '/rtt/ {print $5}')
    wait
    mbps=$(awk '/receiver/ {print $7}' results/.iperf)
    echo "$cc $q $mbps $ms" | tee -a results/bloat.txt
  done
done
rm -f results/.iperf
~~~

<!-- run: chmod +x experiments/bloat.sh && bash -n experiments/bloat.sh -->

The comment about 172 is another instrument check. netem keeps packets it's delaying in the same queue that `limit` counts, and 20 ms at this rate is about 172 packets. Run `./link.sh 40ms 100mbit 0% 172` under load and ping stays at 40 ms: that "queue" has no room for a queue.

Queue sizes are in packets: 100 (about a third of the bandwidth-delay product), 345 (one) and 3,450 (ten). It takes about 15 minutes.

~~~bash
chmod +x experiments/bloat.sh
./experiments/bloat.sh
awk '{print $1, $2, "ping", $4}' results/bloat.txt | sort | ./bin/summarise
awk '{print $1, $2, "mbps", $3}' results/bloat.txt | sort | ./bin/summarise
~~~

Medians of three runs. Each cell is ping under load, in ms, then throughput in Mbit/s. The empty path is 40 ms.

| Queue (packets) | Reno | CUBIC | BBR |
|---|---|---|---|
| 100 | 43 ms, 87.8 | 46 ms, 95.3 | 43 ms, 94.0 |
| 345 | 67 ms, 95.6 | 72 ms, 95.6 | 43 ms, 93.1 |
| 3,450 | 175 ms, 95.6 | 173 ms, 95.6 | 43 ms, 94.0 |

Read it across, then down:

- **Going from 345 packets to 3,450 buys Reno and CUBIC nothing.** Throughput is identical, and latency is two and a half times worse. The extra packets are just waiting. 175 ms isn't even the worst case: the queue was still filling when the ping ran. A full 3,450-packet queue is 418 ms.
- **BBR's latency doesn't move.** 43 ms at every size. That's what the 2% buys: it keeps the queue nearly empty, so anything sharing the link gets a clean path.
- **The bottom-left number shows why "a buffer of one bandwidth-delay product" is the classic rule.** Reno halves on a loss. If the queue holding it up is smaller than the pipe, then halving empties the queue and the link goes idle for a moment. At 100 packets Reno loses 8% of the link; at 345 it loses none. CUBIC only cuts by 30%, so it needs a smaller queue, and 100 is nearly enough.

In a real network you don't control every sender, so the fix for bufferbloat isn't to ask everyone to run BBR. It's **active queue management**: routers such as CAKE or `fq_codel` drop or mark packets when a queue stays long, and give each flow its own queue. You'll try that in the exercise.

### Experiment 3: sharing a link

Everything so far has been one flow alone. The internet is many flows, and the point of congestion control is that they share without anyone in charge. Reno and CUBIC have a mechanism for that, even if it's a crude one: everyone who overflows the queue backs off.

Two flows, one bottleneck, three queue sizes:

<!-- file: experiments/share.sh -->
~~~bash
#!/bin/bash
# Two flows, one bottleneck. Appends "a+b queue-in-BDPs share-of-a" lines to
# results/share.txt; a fair result is a share of 0.50.
set -eu
mkdir -p results
c() { docker compose exec -T "$@"; }
c -d server sh -c 'ss -tln | grep -q :5201 || iperf3 -s -p 5201' 2>/dev/null
c -d server sh -c 'ss -tln | grep -q :5202 || iperf3 -s -p 5202' 2>/dev/null
sleep 1
for run in $(seq 1 "${REPEATS:-5}"); do
  for job in $(for pair in cubic+cubic reno+cubic bbr+cubic; do for bdp in 0.25 1 8; do echo "$pair,$bdp"; done; done | shuf); do
    pair=${job%,*}; bdp=${job#*,}; a=${pair%+*}; b=${pair#*+}
    ./link.sh 40ms 100mbit 0% "$(awk -v b="$bdp" 'BEGIN {printf "%d", 345 * b + 172}')"
    c client iperf3 -c server -p 5201 -R -t 60 -O 20 -C "$a" -f m > results/.a &
    c client iperf3 -c server -p 5202 -R -t 60 -O 20 -C "$b" -f m > results/.b
    wait
    ra=$(awk '/receiver/ {print $7}' results/.a); rb=$(awk '/receiver/ {print $7}' results/.b)
    awk -v p="$pair" -v q="$bdp" -v a="$ra" -v b="$rb" 'BEGIN {printf "%s %s %.3f\n", p, q, a / (a + b)}' | tee -a results/share.txt
  done
done
rm -f results/.a results/.b
~~~

<!-- run: chmod +x experiments/share.sh && bash -n experiments/share.sh -->

The queue is given in bandwidth-delay products, and each run is 60 seconds, with the first 20 left out so the flows can settle. It takes about 50 minutes.

~~~bash
chmod +x experiments/share.sh
./experiments/share.sh
sort results/share.txt | ./bin/summarise
~~~

Each cell is the share taken by the **first** flow, as a median of five runs. A fair split is 0.50.

| Pair | Queue of ¼ BDP | 1 BDP | 8 BDP |
|---|---|---|---|
| CUBIC with CUBIC | 0.50 | 0.56 | 0.50 |
| Reno with CUBIC | 0.38 | 0.41 | 0.45 |
| **BBR** with CUBIC | **1.00** | **0.85** | **0.44** |

Same-algorithm pairs share well. Reno gets somewhat less than CUBIC, as you'd expect, since CUBIC grows faster after a loss. But look at the last row.

A share of 1.00 looks like a bug: did the second flow crash and get counted as zero? Check before you believe it. The raw shares for those five runs were 0.998 to 0.999, and a separate run shows each flow's own rate:

~~~text
queue 0.25 BDP: bbr 92.9 cubic 0.28 cubic-retrans 0 bbr-retrans 3
queue 1 BDP: bbr 68.9 cubic 25.7 cubic-retrans 0 bbr-retrans 0
queue 8 BDP: bbr 39.4 cubic 56.2 cubic-retrans 0 bbr-retrans 0
~~~

Here's the CUBIC flow from the first line, second by second, with its speed collapsing as BBR took the link:

~~~text
[ ID] Interval           Transfer     Bitrate
[  5]   0.00-1.00   sec  1.62 MBytes  13.6 Mbits/sec
[  5]   1.00-2.00   sec   384 KBytes  3.15 Mbits/sec
[  5]   2.00-3.00   sec  0.00 Bytes  0.00 Mbits/sec
[  5]   3.00-4.01   sec  0.00 Bytes  0.00 Mbits/sec
[  5]   4.01-5.01   sec  0.00 Bytes  0.00 Mbits/sec
[  5]   5.01-6.01   sec  0.00 Bytes  0.00 Mbits/sec
[  5]   6.01-7.01   sec  0.00 Bytes  0.00 Mbits/sec
[  5]   7.01-8.00   sec   128 KBytes  1.06 Mbits/sec
[  5]   8.00-9.00   sec  0.00 Bytes  0.00 Mbits/sec
[  5]   9.00-10.00  sec  0.00 Bytes  0.00 Mbits/sec
[  5]  10.00-11.01  sec  0.00 Bytes  0.00 Mbits/sec
[  5]  11.01-12.02  sec   128 KBytes  1.04 Mbits/sec
~~~

**With a small queue, BBR starves CUBIC completely:** 92.9 Mbit/s against 0.28. BBR ignores the drops that its own traffic causes, while CUBIC treats every one as a reason to slow down. With a large queue it flips, and **CUBIC beats BBR** 56 to 39, because CUBIC fills the queue, and BBR limits how much it keeps in flight.

So neither is simply better. Each row of these tables is true, and each answers a different question:

| You care about | Result |
|---|---|
| A long-distance transfer over a link with random loss | BBR, by a factor of 27 |
| Latency for everyone else on the link, when it's the only busy flow | BBR |
| Being a fair neighbour on a shallow-buffered link | BBR is the worst option here |
| A private link where you own all the traffic | Measure; the fairness problem may not apply |

The `bbr` here is the kernel's original design. Later versions, such as BBRv3, were built to reduce exactly this unfairness, so check which one you're running before you repeat these claims. And what you measured isn't a law of nature: it's this kernel, this RTT, and two flows.

For Phase 8, keep this in mind: a training cluster's network is dominated by a few huge synchronised flows, on links with shallow buffers, and that's why data centres use yet other schemes, such as **DCTCP** (which reacts to ECN marks well before a queue overflows). The principle is the same: decide what signal says "slow down", then look at who pays.

**Explain it:** What does each algorithm treat as its signal? Why did BBR not slow down at 1% loss, and what does it give up? What's bufferbloat, and why does it hurt someone who isn't the one downloading? Why didn't ten times the queue give any more throughput? Why does Reno need a queue the size of the bandwidth-delay product? Why does BBR starve CUBIC on a small queue, and lose to it on a large one? Why was it worth checking that 1.00?

**Read.** Cardwell et al., [*BBR: Congestion-Based Congestion Control*](https://queue.acm.org/detail.cfm?id=3022184) (ACM Queue, 2016). Gettys and Nichols, [*Bufferbloat: Dark Buffers in the Internet*](https://queue.acm.org/detail.cfm?id=2071893) (ACM Queue, 2011). Ware et al., [*Modeling BBR's Interactions with Loss-Based Congestion Control*](https://dl.acm.org/doi/10.1145/3355369.3355604) (IMC 2019). [RFC 9438](https://www.rfc-editor.org/rfc/rfc9438) (CUBIC).

---

## Step 4: Head-of-line blocking

### What this step teaches

- What each version of HTTP changed, and why.
- **Head-of-line blocking**, measured directly.
- How to test a causal claim with a **control**, including the most repeated claim about HTTP/3.

### Three versions of HTTP

| Version | Runs on | Requests |
|---|---|---|
| **HTTP/1.1** | TCP | One at a time per connection, so browsers open about six |
| **HTTP/2** | One TCP connection | Many **streams** multiplexed on it, split into frames |
| **HTTP/3** | **QUIC**, on UDP | Many streams, and the transport itself knows about them |

You saw the problem at the end of step 2. TCP delivers one ordered stream of bytes. When a segment is lost, everything after it waits in the kernel until the hole is filled. HTTP/2 puts every stream into that one ordered stream, so a lost packet from object 3 holds up objects 4 to 50, though their bytes have arrived. That's **head-of-line blocking**: the request is at the back of a queue, behind something that has nothing to do with it.

**QUIC** moves streams into the transport. Each stream has its own order, so a lost packet holds up only the stream it belonged to. QUIC also folds the TLS 1.3 handshake into its own, so a new connection takes one round trip before data, where TCP plus TLS takes two. And it runs on UDP because middleboxes on the internet block new protocols: UDP was the only way to deploy it.

The usual claim follows: "on lossy networks, HTTP/3 is faster than HTTP/2 because it has no head-of-line blocking". You're going to test that, including the "because".

### A page, over all three

The server speaks all three versions on one port number: TCP for the first two, UDP for the third. The client fetches a page of many small objects, and records when each one finishes.

~~~bash
go get github.com/quic-go/quic-go@v0.64.1
~~~

<!-- run: go get github.com/quic-go/quic-go@v0.64.1 -->

<!-- file: page/page.go -->
~~~go
// Package page serves a "web page" of many small objects, and fetches it
// over HTTP/1.1, HTTP/2 or HTTP/3, so the three can be compared.
package page

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"slices"
	"strconv"
	"sync"
	"time"

	"github.com/quic-go/quic-go/http3"
)

// Handler serves /obj/{size}/{n}: size bytes, whatever n is. n only makes
// each URL different, as the objects of a page are.
func Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /obj/{size}/{n}", func(w http.ResponseWriter, r *http.Request) {
		size, err := strconv.Atoi(r.PathValue("size"))
		if err != nil || size < 0 || size > 10<<20 {
			http.Error(w, "bad size", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Length", strconv.Itoa(size))
		w.Write(make([]byte, size))
	})
	return mux
}

// Cert makes a throwaway self-signed certificate. It's for a lab only:
// the client below doesn't verify it.
func Cert() (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "netlab"},
		DNSNames:     []string{"server", "localhost"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, nil
}

// Client returns a fresh HTTP client for proto ("h1", "h2" or "h3"), with
// no connections open, like a browser's first visit. HTTP/1.1 gets six
// connections, as browsers allow; HTTP/2 and HTTP/3 share one.
func Client(proto string) (*http.Client, func(), error) {
	tlsConf := &tls.Config{InsecureSkipVerify: true} // the lab's throwaway certificate
	switch proto {
	case "h1", "h2":
		t := &http.Transport{TLSClientConfig: tlsConf, Protocols: new(http.Protocols)}
		if proto == "h1" {
			t.Protocols.SetHTTP1(true)
			t.MaxConnsPerHost = 6
		} else {
			t.Protocols.SetHTTP2(true)
		}
		return &http.Client{Transport: t}, t.CloseIdleConnections, nil
	case "h3":
		t := &http3.Transport{TLSClientConfig: tlsConf}
		return &http.Client{Transport: t}, func() { t.Close() }, nil
	}
	return nil, nil, fmt.Errorf("unknown protocol %q", proto)
}

// Page is one load of the page.
type Page struct {
	Total   time.Duration   // until the last object finished
	Objects []time.Duration // when each object finished, from the start
}

// Median returns the time by which half the objects had finished.
func (p Page) Median() time.Duration {
	s := slices.Sorted(slices.Values(p.Objects))
	return s[len(s)/2]
}

// Fetch gets n objects of size bytes from base at once, and times each one.
// It fails if any response used another protocol.
func Fetch(ctx context.Context, proto, base string, n, size int) (Page, error) {
	client, closeIt, err := Client(proto)
	if err != nil {
		return Page{}, err
	}
	defer closeIt()
	want := map[string]int{"h1": 1, "h2": 2, "h3": 3}[proto]

	start := time.Now()
	objects := make([]time.Duration, n)
	errs := make(chan error, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Go(func() {
			req, err := http.NewRequestWithContext(ctx, "GET", fmt.Sprintf("%s/obj/%d/%d", base, size, i), nil)
			if err != nil {
				errs <- err
				return
			}
			resp, err := client.Do(req)
			if err != nil {
				errs <- err
				return
			}
			defer resp.Body.Close()
			if resp.ProtoMajor != want {
				errs <- fmt.Errorf("got %s, want %s", resp.Proto, proto)
				return
			}
			if _, err := io.Copy(io.Discard, resp.Body); err != nil {
				errs <- err
				return
			}
			objects[i] = time.Since(start)
		})
	}
	wg.Wait()
	total := time.Since(start)
	select {
	case err := <-errs:
		return Page{}, err
	default:
		return Page{Total: total, Objects: objects}, nil
	}
}
~~~

<!-- file: page/page_test.go -->
~~~go
package page

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/quic-go/quic-go/http3"
)

// serve starts HTTP/1.1, HTTP/2 and HTTP/3 on one port of localhost.
func serve(t *testing.T) string {
	t.Helper()
	cert, err := Cert()
	if err != nil {
		t.Fatal(err)
	}
	conf := &tls.Config{Certificates: []tls.Certificate{cert}}
	h3conf := http3.ConfigureTLSConfig(conf.Clone())
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	s := &http.Server{Handler: Handler(), TLSConfig: conf}
	go s.ServeTLS(ln, "", "")
	t.Cleanup(func() { s.Close() })

	udp, err := net.ListenPacket("udp", addr)
	if err != nil {
		t.Fatal(err)
	}
	h3 := &http3.Server{Handler: Handler(), TLSConfig: h3conf}
	go h3.Serve(udp)
	t.Cleanup(func() { h3.Close(); udp.Close() })
	return "https://" + addr
}

func TestEveryProtocolFetchesThePage(t *testing.T) {
	base := serve(t)
	for _, proto := range []string{"h1", "h2", "h3"} {
		t.Run(proto, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			p, err := Fetch(ctx, proto, base, 20, 1024)
			if err != nil {
				t.Fatal(err)
			}
			if len(p.Objects) != 20 {
				t.Fatalf("%d objects, want 20", len(p.Objects))
			}
			for i, d := range p.Objects {
				if d <= 0 || d > p.Total {
					t.Errorf("object %d finished at %v, page took %v", i, d, p.Total)
				}
			}
		})
	}
}

func TestUnknownProtocol(t *testing.T) {
	if _, err := Fetch(context.Background(), "h9", "https://x", 1, 1); err == nil {
		t.Fatal("want an error")
	}
}

func TestMedian(t *testing.T) {
	p := Page{Objects: []time.Duration{30, 10, 20}}
	if got := p.Median(); got != 20 {
		t.Errorf("Median = %v, want 20", got)
	}
}

func TestSizeIsChecked(t *testing.T) {
	base := serve(t)
	client, closeIt, _ := Client("h2")
	defer closeIt()
	resp, err := client.Get(base + "/obj/nonsense/1")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("status %d", resp.StatusCode)
	}
}
~~~

<!-- file: cmd/pageserver/main.go -->
~~~go
// Command pageserver serves the page over HTTP/1.1, HTTP/2 (TCP) and
// HTTP/3 (UDP), on the same port number.
package main

import (
	"crypto/tls"
	"log"
	"net/http"

	"github.com/quic-go/quic-go/http3"

	"netlab/page"
)

func main() {
	cert, err := page.Cert()
	if err != nil {
		log.Fatal(err)
	}
	// Each server gets its own config: both change the one they're given.
	conf := &tls.Config{Certificates: []tls.Certificate{cert}}
	h3conf := http3.ConfigureTLSConfig(conf.Clone())
	go func() {
		s := &http3.Server{Addr: ":8443", Handler: page.Handler(), TLSConfig: h3conf}
		log.Fatal(s.ListenAndServe())
	}()
	s := &http.Server{Addr: ":8443", Handler: page.Handler(), TLSConfig: conf}
	log.Fatal(s.ListenAndServeTLS("", ""))
}
~~~

<!-- file: cmd/pagefetch/main.go -->
~~~go
// Command pagefetch loads the page once, and prints two times in
// milliseconds: when the whole page finished, and when half the objects had.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"time"

	"netlab/page"
)

func main() {
	url := flag.String("url", "https://server:8443", "server")
	proto := flag.String("proto", "h2", "h1, h2 or h3")
	objects := flag.Int("objects", 50, "objects on the page")
	size := flag.Int("size", 20_000, "bytes per object")
	flag.Parse()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	p, err := page.Fetch(ctx, *proto, *url, *objects, *size)
	if err != nil {
		log.Fatal(err)
	}
	ms := func(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }
	fmt.Printf("%.1f %.1f\n", ms(p.Total), ms(p.Median()))
}
~~~

Now that the code imports it, let Go work out the rest of the dependencies:

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race ./... -->

~~~bash
go mod tidy
go vet ./... && go test -race ./...
~~~

`go test -race` matters here. The first version of this code gave both servers the same `tls.Config`, and the race detector caught one server writing to it while the other cloned it. Nothing crashed in normal runs.

Build it without cgo, so the binaries run inside the containers, and try one fetch of each:

~~~bash
CGO_ENABLED=0 go build -o bin/ ./cmd/...
docker compose exec -d server bin/pageserver
./link.sh 40ms 20mbit 0% 105
for p in h1 h2 h3; do docker compose exec client bin/pagefetch -proto $p; done
~~~

Each line is the whole page's time, then the time by which half the objects had finished. 105 packets is one bandwidth-delay product of queue, plus the delay netem holds.

### Check the instrument, again

Step 2 taught you that netem makes one decision per burst. Does HTTP/3 send bursts? TCP isn't the only thing that batches: quic-go uses **UDP GSO**, passing many datagrams to the kernel at once. Count the drops at 2%:

~~~bash
./link.sh 40ms 20mbit 2% 105
docker compose exec server tc -s qdisc show dev eth0 | grep Sent
for i in 1 2 3 4 5 6; do docker compose exec client bin/pagefetch -proto h3; done
docker compose exec server tc -s qdisc show dev eth0 | grep Sent
~~~

Subtract the first line from the second. Then restart the server with `QUIC_GO_DISABLE_GSO=true`, and do it again:

~~~bash
docker compose exec server pkill pageserver
docker compose exec -d -e QUIC_GO_DISABLE_GSO=true server bin/pageserver
~~~

~~~text
h3 default     packets  4695 dropped   33 = 0.70%
h3 GSO off     packets  4646 dropped  100 = 2.11%
~~~

There it is. `gso_max_segs` doesn't stop UDP GSO, so by default a 2% link loses 0.7% of HTTP/3's packets, and HTTP/3 would have looked much better than it deserves. With GSO off, loss is what it should be. The experiment turns it off.

<!-- file: experiments/page.sh -->
~~~bash
#!/bin/bash
# One page of 50 objects over HTTP/1.1, HTTP/2 and HTTP/3, at each loss rate,
# on a 20 Mbit/s, 40 ms link with a queue of one bandwidth-delay product.
# Appends "proto loss page-ms median-object-ms" lines to results/page.txt.
set -eu
mkdir -p results
c() { docker compose exec -T "$@"; }
# quic-go batches UDP packets the way TCP does. Turn that off, or netem's
# one coin toss per burst would flatter HTTP/3.
c server sh -c 'pkill pageserver; true'
c -d -e QUIC_GO_DISABLE_GSO=true server bin/pageserver
sleep 1
for run in $(seq 1 "${REPEATS:-15}"); do
  for job in $(for p in h1 h2 h3; do for l in 0% 0.5% 1% 2% 4%; do echo "$p,$l"; done; done | shuf); do
    proto=${job%,*}; loss=${job#*,}
    ./link.sh 40ms 20mbit "$loss" 105
    echo "$proto $loss $(c client bin/pagefetch -proto "$proto")" | tee -a results/page.txt
  done
done
~~~

<!-- run: chmod +x experiments/page.sh && bash -n experiments/page.sh -->

Predict first: which one wins at 4% loss? It takes about 15 minutes.

~~~bash
chmod +x experiments/page.sh
./experiments/page.sh
~~~

To summarise a column, turn it into "label value" lines:

~~~bash
awk '{print $1, $2, $3}' results/page.txt | sort | ./bin/summarise
~~~

Median page time in ms, 15 runs, 50 objects of 20 KB, at 20 Mbit/s and 40 ms:

| Loss | HTTP/1.1 | HTTP/2 | HTTP/3 |
|---|---|---|---|
| 0% | 584 | 670 | 544 |
| 0.5% | 641 | 745 | 722 |
| 1% | 659 | 1,712 | 991 |
| 2% | 886 | 3,438 | 1,760 |
| 4% | 1,205 | 5,765 | 3,083 |

HTTP/3 is nearly twice as fast as HTTP/2 at 2% and 4%. If you stopped here, you'd say the claim is confirmed.

But there are two problems. **HTTP/1.1 beats both,** by a wide margin, and the textbook story doesn't explain that. And this table can't tell you **why** HTTP/3 beat HTTP/2. It's a different protocol stack, with a different implementation of everything. A win isn't evidence for a particular reason.

### A control: take the multiplexing away

If head-of-line blocking explains the gap, then removing it should remove the gap. With **one** object there's only one stream, so there's nothing to block. Fetch 1 MB, the same bytes as the page, as a single object:

<!-- file: experiments/control.sh -->
~~~bash
#!/bin/bash
# One 1 MB object, so nothing is multiplexed and there's nothing to block.
# What's left between the protocols is their loss recovery. Appends
# "proto loss ms" lines to results/control.txt.
set -eu
mkdir -p results
c() { docker compose exec -T "$@"; }
c server sh -c 'pkill pageserver; true'
c -d -e QUIC_GO_DISABLE_GSO=true server bin/pageserver
sleep 1
for run in $(seq 1 "${REPEATS:-15}"); do
  for job in $(for p in h1 h2 h3; do for l in 0% 1% 4%; do echo "$p,$l"; done; done | shuf); do
    proto=${job%,*}; loss=${job#*,}
    ./link.sh 40ms 20mbit "$loss" 105
    ms=$(c client bin/pagefetch -proto "$proto" -objects 1 -size 1000000 | awk '{print $1}')
    echo "$proto $loss $ms" | tee -a results/control.txt
  done
done
~~~

<!-- run: chmod +x experiments/control.sh && bash -n experiments/control.sh -->

~~~bash
chmod +x experiments/control.sh
./experiments/control.sh
~~~

| Loss | HTTP/1.1, one object | HTTP/2, one object | HTTP/3, one object |
|---|---|---|---|
| 0% | 629 | 632 | 544 |
| 1% | 1,265 | 1,339 | 1,313 |
| 4% | 4,849 | 5,843 | 3,163 |

Compare that with the last table, at 4%. HTTP/2 took 5,765 ms for the page, and 5,843 ms for one object. HTTP/3 took 3,083 and 3,163. **The gap is the same with nothing to block.** So in this experiment, HTTP/3's win over HTTP/2 on page time is **not** head-of-line blocking. Both move 1 MB through one congestion-controlled flow, and quic-go got through it faster than the kernel's TCP at 4% loss. That's a difference between two implementations of loss recovery, not something HTTP/3 guarantees. At 1%, where the one-object times match, there's no gap at all. (The page's 1,712 against 991 at 1% has wide, overlapping intervals.) With no loss, HTTP/3 leads by about 90 ms. Its handshake accounts for one 40 ms round trip. quic-go's first window of 32 packets, against TCP's 10, is a likely reason for the rest, but this guide didn't test that.

The control also explains HTTP/1.1. With one connection it's as slow as HTTP/2: 4,849 ms at 4%. With six it takes 1,205 ms. Six connections are six independent congestion windows, so a loss halves only one of them, and the Mathis formula applies to each. HTTP/2's single connection was designed to be kinder to the network, and on a lossy link that's what costs it. It's also why HTTP/1.1's median object arrives sooner: objects finish one by one, while HTTP/2 interleaves them, so they all finish at about the same time.

### Measuring the blocking itself

So head-of-line blocking doesn't show up in the time to move a megabyte. It's a **latency** effect: something small waits for something unrelated. Measure that directly. Download a big object, and meanwhile send a tiny request every 50 ms on the same client. In real systems, this is an API call sharing a connection with a large response, or one gRPC call behind another on a shared HTTP/2 connection.

<!-- append: page/page.go -->
~~~go
// Probe downloads one big object and, while that runs, asks for a tiny
// object every interval from the same client. It returns how long each tiny
// request took. On HTTP/2 and HTTP/3 they all share one connection, so a
// packet lost from the big download can hold up a tiny response only if the
// transport delivers strictly in order.
func Probe(ctx context.Context, proto, base string, big int, every time.Duration) ([]time.Duration, error) {
	client, closeIt, err := Client(proto)
	if err != nil {
		return nil, err
	}
	defer closeIt()
	get := func(path string) error {
		req, err := http.NewRequestWithContext(ctx, "GET", base+path, nil)
		if err != nil {
			return err
		}
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		_, err = io.Copy(io.Discard, resp.Body)
		return err
	}
	if err := get("/obj/100/warm"); err != nil { // open the connection first
		return nil, err
	}

	done := make(chan error, 1)
	go func() { done <- get(fmt.Sprintf("/obj/%d/big", big)) }()

	var (
		mu    sync.Mutex
		times []time.Duration
		wg    sync.WaitGroup
	)
	tick := time.NewTicker(every)
	defer tick.Stop()
	for i := 0; ; i++ {
		select {
		case err := <-done:
			wg.Wait()
			return times, err
		case <-tick.C:
			wg.Go(func() {
				start := time.Now()
				if err := get(fmt.Sprintf("/obj/100/%d", i)); err == nil {
					mu.Lock()
					times = append(times, time.Since(start))
					mu.Unlock()
				}
			})
		}
	}
}
~~~

<!-- append: page/page_test.go -->
~~~go
func TestProbeTimesTinyRequestsDuringTheDownload(t *testing.T) {
	base := serve(t)
	for _, proto := range []string{"h1", "h2", "h3"} {
		t.Run(proto, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()
			times, err := Probe(ctx, proto, base, 2<<20, time.Millisecond)
			if err != nil {
				t.Fatal(err)
			}
			if len(times) == 0 {
				t.Fatal("no tiny requests finished during the download")
			}
		})
	}
}
~~~

<!-- file: cmd/holprobe/main.go -->
~~~go
// Command holprobe downloads one big object while timing tiny requests
// alongside it, and prints the 50th, 90th and 99th percentiles in
// milliseconds, and how many tiny requests there were.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"slices"
	"time"

	"netlab/page"
)

func main() {
	url := flag.String("url", "https://server:8443", "server")
	proto := flag.String("proto", "h2", "h1, h2 or h3")
	big := flag.Int("big", 3_000_000, "bytes in the big object")
	every := flag.Duration("every", 50*time.Millisecond, "time between tiny requests")
	flag.Parse()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	times, err := page.Probe(ctx, *proto, *url, *big, *every)
	if err != nil {
		log.Fatal(err)
	}
	slices.Sort(times)
	at := func(pct int) float64 { return float64(times[len(times)*pct/100].Microseconds()) / 1000 }
	fmt.Printf("%.1f %.1f %.1f %d\n", at(50), at(90), at(99), len(times))
}
~~~

<!-- file: experiments/probe.sh -->
~~~bash
#!/bin/bash
# Tiny requests alongside a big download. Appends
# "proto loss p50 p90 p99 count" lines to results/probe.txt, in milliseconds.
set -eu
mkdir -p results
c() { docker compose exec -T "$@"; }
c server sh -c 'pkill pageserver; true'
c -d -e QUIC_GO_DISABLE_GSO=true server bin/pageserver
sleep 1
for run in $(seq 1 "${REPEATS:-10}"); do
  for job in $(for p in h1 h2 h3; do for l in 0% 1% 2%; do echo "$p,$l"; done; done | shuf); do
    proto=${job%,*}; loss=${job#*,}
    ./link.sh 40ms 20mbit "$loss" 105
    echo "$proto $loss $(c client bin/holprobe -proto "$proto")" | tee -a results/probe.txt
  done
done
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race ./... && bash -n experiments/probe.sh -->

~~~bash
CGO_ENABLED=0 go build -o bin/ ./cmd/...
chmod +x experiments/probe.sh
./experiments/probe.sh
awk '{print $1, $2, $3}' results/probe.txt | sort | ./bin/summarise
~~~

Median across 10 runs of the 50th-percentile tiny request, in ms. HTTP/1.1's tiny requests run on a separate connection, so it's the case with no shared stream at all.

| Loss | HTTP/1.1 | HTTP/2 | HTTP/3 |
|---|---|---|---|
| 0% | 65 | 218 | 73 |
| 1% | 42 | 706 | 50 |
| 2% | 42 | 671 | 52 |

Now there's a dramatic difference: at 1% loss, a tiny request takes **14 times longer** on HTTP/2 than on HTTP/3. HTTP/1.1 and HTTP/3 even get **faster** with loss, because the big download slows down and stops filling the queue.

Don't call it all head-of-line blocking yet, because of the first row. HTTP/2 is at 218 ms with **no loss**, and with no loss nothing is blocked. Something else is going on. On TCP, the server hands bytes to the kernel's send buffer, and once they're there, they can't be reordered. The tiny response is a new frame, queued behind whatever's already in that buffer, and step 1 showed you the buffer can hold megabytes.

Linux can limit how much **unsent** data sits there: `tcp_notsent_lowat`. Set that low, and the server holds its data back, so a new frame can go first. That leaves only packets already sent, which is the blocking we want to measure.

<!-- file: experiments/lowat.sh -->
~~~bash
#!/bin/bash
# The tiny-request experiment again for HTTP/2, with the server's unsent
# data limited to 16 KB. Appends lines like probe.sh to results/lowat.txt.
set -eu
mkdir -p results
c() { docker compose exec -T "$@"; }
c server sh -c 'pkill pageserver; true'
# A container's /proc/sys is read-only, even with exec --privileged. A
# privileged container on the server's network namespace can write it.
lowat() { docker run --rm --privileged --network container:netlab-server-1 nettools sysctl -n -w net.ipv4.tcp_notsent_lowat="$1"; }
[ "$(lowat 16384)" = 16384 ] || { echo "sysctl didn't take"; exit 1; }
c -d server bin/pageserver
sleep 1
for run in $(seq 1 "${REPEATS:-10}"); do
  for loss in $(printf '%s\n' 0% 1% 2% | shuf); do
    ./link.sh 40ms 20mbit "$loss" 105
    echo "h2 $loss $(c client bin/holprobe -proto h2)" | tee -a results/lowat.txt
  done
done
lowat 4294967295
~~~

<!-- run: chmod +x experiments/lowat.sh && bash -n experiments/lowat.sh -->

The read-back check is there for a reason. The first version of this script used `exec --privileged`. That printed "Read-only file system", carried on, and ran 30 measurements of nothing. The results matched the baseline, which looks exactly like "the setting makes no difference". A setting you haven't read back is a guess.

Median 50th and 99th percentiles of the tiny requests, in ms:

| Loss | HTTP/2 | HTTP/2, `notsent_lowat` 16 KB | HTTP/3 | HTTP/1.1 |
|---|---|---|---|---|
| 0% | 218 / 315 | 86 / 118 | 73 / 148 | 65 / 165 |
| 1% | 706 / 1,345 | 182 / 376 | 50 / 83 | 42 / 163 |
| 2% | 671 / 1,150 | 281 / 560 | 52 / 102 | 42 / 303 |

Now each piece has a size:

- **The send buffer accounts for most of the 706 ms.** Limiting it brings 706 ms down to 182 ms, with a one-line setting and no new protocol.
- **Head-of-line blocking is what's left, and it's real.** With the buffer limited and no loss, HTTP/2 nearly matches HTTP/3. With loss, it's still 4 to 5 times slower, at the median and at p99. That's the effect the textbooks describe, and it grows with loss.
- **HTTP/3 doesn't have it.** Tiny requests stay near 50 ms however much is being lost.

### What to say in an interview

"HTTP/3 is faster because it has no head-of-line blocking" is half right. A better answer:

- HTTP/3 removes head-of-line blocking between streams, and you see that in the latency of small requests that share a connection with large ones: roughly 4 to 5 times better here at 1–2% loss.
- It doesn't by itself make a bulk transfer faster. In this lab the throughput gap came with one stream too, so it was the implementation's loss recovery.
- Six HTTP/1.1 connections beat one multiplexed connection on a lossy link, since they get six congestion windows.
- Much of what gets blamed on protocols is queueing. Fix the queue first.

And the limits: this is random, independent loss on one emulated link, with two particular implementations. Real browsers, real loss patterns and other QUIC stacks will give different numbers. What you can carry away is the method: **change one thing, keep a baseline, and ask what result would prove your explanation wrong.**

**Explain it:** Why can't an HTTP/2 server get around TCP's ordering? What did the one-object control show, and why was it needed? Why did HTTP/1.1 win the page test? Why did HTTP/2 have slow tiny requests with no loss at all? What does `tcp_notsent_lowat` change? How would you decide whether your gRPC service should open more than one connection? Why was a run that matched the baseline suspicious?

**Read.** [RFC 9000](https://www.rfc-editor.org/rfc/rfc9000) (QUIC), [RFC 9114](https://www.rfc-editor.org/rfc/rfc9114) (HTTP/3) and [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113) (HTTP/2). Langley et al., [*The QUIC Transport Protocol*](https://dl.acm.org/doi/10.1145/3098822.3098842) (SIGCOMM 2017).

---

## Step 5: CDNs, anycast and BGP

### What this step teaches

- What a **content delivery network** saves, split into its parts: handshakes, the distance to the origin, and loss recovery.
- A network namespace: what a container's network really is.
- **Anycast** and **BGP**, with a small simulator of a site failing.

### The physics a CDN works around

Everything so far has one RTT. Step 2's formula says throughput falls as RTT grows, and step 1 says a new connection pays several round trips before any data moves. A CDN attacks the RTT itself: put a server near the user, and let it answer, or at least do the expensive part of the conversation nearby.

Three things can happen at an edge, and it's worth measuring them separately:

| Path | What happens | What should it save? |
|---|---|---|
| **Direct** | Packets pass through; the client talks to the origin | Nothing: the baseline |
| **Proxy** | The edge finishes TLS, and forwards the request on a connection it keeps open | The handshakes, and retransmissions now cross only the last mile |
| **Cache** | The edge answers by itself | The trip to the origin too |

### A lab of three hosts

You need `client -- edge -- origin`, with a short lossy last mile and a long clean backbone. The direct path has to go **through** the edge without stopping, as packets through a router do, or it isn't a fair baseline.

The obvious design, three containers on two Docker networks, doesn't work: Docker drops traffic for a container that arrives from another of its networks. So build the network yourself. A **network namespace** is a kernel feature that gives a process its own interfaces, routes and sockets. That's all a container's network is. A **veth pair** is a virtual cable: what goes in one end comes out of the other. Three namespaces and two cables make the whole lab, in one container:

<!-- file: compose.cdn.yaml -->
~~~yaml
# One privileged container, holding three network namespaces (see cdn.sh).
name: netcdn
services:
  lab:
    image: nettools
    command: sleep infinity
    privileged: true
    volumes: [".:/lab"]
    working_dir: /lab
~~~

<!-- file: cdn.sh -->
~~~bash
#!/bin/bash
# The three-host lab, as three network namespaces in one container, joined
# by virtual cables:   client --c0--e0-- edge --e1--o0-- origin
# A last mile of 10 ms RTT at 20 Mbit/s, with the given loss on the way to
# the client, and a backbone of 100 ms RTT.
#   ./cdn.sh 1%
set -eu
c() { docker compose -f compose.cdn.yaml exec -T lab "$@"; }
n() { c ip netns exec "$@"; }
if ! c ip netns list | grep -q client; then
  for ns in client edge origin; do
    c ip netns add "$ns"
    n "$ns" ip link set lo up
  done
  c ip link add c0 netns client type veth peer name e0 netns edge
  c ip link add e1 netns edge type veth peer name o0 netns origin
  n client ip addr add 10.10.1.10/24 dev c0
  n edge ip addr add 10.10.1.2/24 dev e0
  n edge ip addr add 10.10.2.2/24 dev e1
  n origin ip addr add 10.10.2.10/24 dev o0
  n client ip link set c0 up
  n edge ip link set e0 up
  n edge ip link set e1 up
  n origin ip link set o0 up
  n client ip route add default via 10.10.1.2
  n origin ip route add default via 10.10.2.2
  n edge sysctl -qw net.ipv4.ip_forward=1
  # Send packet-sized units, and don't let the edge glue forwarded packets
  # together: netem must see each packet (step 2).
  n client ip link set c0 gso_max_segs 1
  n edge ip link set e0 gso_max_segs 1
  n edge ip link set e1 gso_max_segs 1
  n origin ip link set o0 gso_max_segs 1
  n edge ethtool -K e0 gro off
  n edge ethtool -K e1 gro off
fi
n client tc qdisc replace dev c0 root netem delay 5ms
n edge tc qdisc replace dev e0 root netem delay 5ms loss "$1" rate 20mbit limit 200
n edge tc qdisc replace dev e1 root netem delay 50ms limit 10000
n origin tc qdisc replace dev o0 root netem delay 50ms limit 10000
~~~

<!-- run: chmod +x cdn.sh && bash -n cdn.sh -->

`privileged: true` is needed to create namespaces. Here, it's a lab on your laptop; never use it for a service.

### The edge

The edge is a reverse proxy with an optional cache. It's short because Go's standard library has done the hard parts:

<!-- file: edge/edge.go -->
~~~go
// Package edge is a small content-delivery node: it proxies HTTP over a warm
// connection to the origin, and can also cache responses.
package edge

import (
	"bytes"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sync"
)

// Proxy forwards requests to origin over connections it keeps open, so a
// request pays one round trip to the origin and no handshake.
func Proxy(origin *url.URL, transport http.RoundTripper) http.Handler {
	p := httputil.NewSingleHostReverseProxy(origin)
	p.Transport = transport
	return p
}

// Cache stores successful GET responses in memory, forever. A real cache
// has eviction (DSA guide 06) and expiry; this one shows what a hit saves.
func Cache(next http.Handler) http.Handler {
	var mu sync.RWMutex
	store := map[string][]byte{}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.URL.Path
		mu.RLock()
		body, hit := store[key]
		mu.RUnlock()
		if r.Method == http.MethodGet && hit {
			w.Header().Set("X-Cache", "hit")
			w.Write(body)
			return
		}
		rec := &recorder{ResponseWriter: w, status: http.StatusOK}
		w.Header().Set("X-Cache", "miss")
		next.ServeHTTP(rec, r)
		if r.Method == http.MethodGet && rec.status == http.StatusOK {
			mu.Lock()
			store[key] = rec.buf.Bytes()
			mu.Unlock()
		}
	})
}

// recorder passes a response through, and keeps a copy of it.
type recorder struct {
	http.ResponseWriter
	status int
	buf    bytes.Buffer
}

func (r *recorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *recorder) Write(p []byte) (int, error) {
	r.buf.Write(p)
	return r.ResponseWriter.Write(p)
}
~~~

<!-- file: edge/edge_test.go -->
~~~go
package edge

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync/atomic"
	"testing"
)

func originCounting(t *testing.T) (*httptest.Server, *atomic.Int64) {
	t.Helper()
	var hits atomic.Int64
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.URL.Path == "/missing" {
			http.NotFound(w, r)
			return
		}
		io.WriteString(w, "body of "+r.URL.Path)
	}))
	t.Cleanup(s.Close)
	return s, &hits
}

func get(t *testing.T, url string) (string, string, int) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return string(b), resp.Header.Get("X-Cache"), resp.StatusCode
}

func TestCacheServesTheSecondRequestItself(t *testing.T) {
	origin, hits := originCounting(t)
	u, _ := url.Parse(origin.URL)
	e := httptest.NewServer(Cache(Proxy(u, http.DefaultTransport)))
	defer e.Close()

	body1, state1, _ := get(t, e.URL+"/a")
	body2, state2, _ := get(t, e.URL+"/a")
	if body1 != "body of /a" || body2 != body1 {
		t.Errorf("bodies %q and %q", body1, body2)
	}
	if state1 != "miss" || state2 != "hit" {
		t.Errorf("X-Cache %q then %q, want miss then hit", state1, state2)
	}
	if n := hits.Load(); n != 1 {
		t.Errorf("the origin saw %d requests, want 1", n)
	}
}

func TestErrorsAreNotCached(t *testing.T) {
	origin, hits := originCounting(t)
	u, _ := url.Parse(origin.URL)
	e := httptest.NewServer(Cache(Proxy(u, http.DefaultTransport)))
	defer e.Close()
	get(t, e.URL+"/missing")
	if _, _, status := get(t, e.URL+"/missing"); status != http.StatusNotFound {
		t.Errorf("status %d", status)
	}
	if n := hits.Load(); n != 2 {
		t.Errorf("the origin saw %d requests, want 2: a 404 mustn't be cached", n)
	}
}
~~~

<!-- file: cmd/edge/main.go -->
~~~go
// Command edge sits between clients and the origin, as a proxy that
// terminates TLS and keeps a warm connection to the origin, with or without
// an in-memory cache.
package main

import (
	"crypto/tls"
	"flag"
	"log"
	"net/http"
	"net/url"

	"netlab/edge"
	"netlab/page"
)

func main() {
	cache := flag.Bool("cache", false, "cache responses")
	listen := flag.String("listen", ":8443", "address to listen on")
	origin := flag.String("origin", "10.10.2.10:8443", "origin host:port")
	flag.Parse()

	cert, err := page.Cert()
	if err != nil {
		log.Fatal(err)
	}
	transport := &http.Transport{
		TLSClientConfig:     &tls.Config{InsecureSkipVerify: true}, // the lab's throwaway certificate
		MaxIdleConnsPerHost: 64,
		ForceAttemptHTTP2:   true,
	}
	var h http.Handler = edge.Proxy(&url.URL{Scheme: "https", Host: *origin}, transport)
	if *cache {
		h = edge.Cache(h)
	}
	s := &http.Server{Addr: *listen, Handler: h, TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}}}
	log.Fatal(s.ListenAndServeTLS("", ""))
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race ./... -->

The test that a 404 isn't cached is doing real work: serving one user's error to everyone is a classic CDN outage. A real cache also needs expiry, invalidation and eviction (DSA guide 06), and has to care about which headers change the response.

Check the instrument first, as ever. Bring the lab up, and count drops on the last mile, on both kinds of path:

~~~bash
CGO_ENABLED=0 go build -o bin/ ./cmd/...
chmod +x cdn.sh
docker compose down
docker compose -f compose.cdn.yaml up -d
./cdn.sh 0%
docker compose -f compose.cdn.yaml exec lab ip netns exec client ping -c 3 -q 10.10.1.2
docker compose -f compose.cdn.yaml exec lab ip netns exec client ping -c 3 -q 10.10.2.10
~~~

The two RTTs should be about 10 ms to the edge and 110 ms to the origin. At a loss setting of 2%, the edge's `tc -s` counters gave:

~~~text
https://10.10.2.10:8443 packets 2211 dropped 38 = 1.69%
https://10.10.1.2:8443 packets 2242 dropped 45 = 1.97%
~~~

Close to 2% on both, so forwarded packets aren't being glued together. That's what the `gro off` in `cdn.sh` is for.

### The experiment

<!-- file: experiments/edge.sh -->
~~~bash
#!/bin/bash
# What an edge saves. A new client each time fetches one object: straight
# through to the origin, through the edge as a proxy, or from the edge's
# cache. Appends "path size loss ms" lines to results/edge.txt.
set -eu
mkdir -p results
c() { docker compose -f compose.cdn.yaml exec -T lab "$@"; }
n() { c ip netns exec "$@"; }
c sh -c 'pkill pageserver; pkill edge; true'
./cdn.sh 0%
docker compose -f compose.cdn.yaml exec -d lab ip netns exec origin bin/pageserver
docker compose -f compose.cdn.yaml exec -d lab ip netns exec edge bin/edge -listen :8443
docker compose -f compose.cdn.yaml exec -d lab ip netns exec edge bin/edge -cache -listen :8444
sleep 1
url() { case $1 in
  direct) echo https://10.10.2.10:8443 ;;
  proxy) echo https://10.10.1.2:8443 ;;
  cache) echo https://10.10.1.2:8444 ;;
esac; }
# Warm the proxy's connection to the origin, and fill the cache.
for size in 20000 1000000; do
  n client bin/pagefetch -proto h2 -objects 1 -size $size -url "$(url proxy)" > /dev/null
  n client bin/pagefetch -proto h2 -objects 1 -size $size -url "$(url cache)" > /dev/null
done
for run in $(seq 1 "${REPEATS:-15}"); do
  for job in $(for p in direct proxy cache; do for s in 20000 1000000; do for l in 0% 1%; do echo "$p,$s,$l"; done; done; done | shuf); do
    IFS=, read -r path size loss <<< "$job"
    ./cdn.sh "$loss"
    ms=$(n client bin/pagefetch -proto h2 -objects 1 -size "$size" -url "$(url "$path")" | awk '{print $1}')
    echo "$path $size $loss $ms" | tee -a results/edge.txt
  done
done
~~~

<!-- run: chmod +x experiments/edge.sh && bash -n experiments/edge.sh -->

Predict first, using round trips. A new HTTPS connection takes one round trip for TCP, one for TLS, and one for the request. TCP's first window is 10 packets, about 14 KB, so a 20 KB object needs one more. What should each path take? It takes about 15 minutes.

~~~bash
chmod +x experiments/edge.sh
./experiments/edge.sh
awk '{print $1, $2, $3, $4}' results/edge.txt | sort | ./bin/summarise
~~~

Median time for a new client to fetch one object, in ms, 15 runs:

| Path | 20 KB, no loss | 20 KB, 1% loss | 1 MB, no loss | 1 MB, 1% loss |
|---|---|---|---|---|
| Direct | 460 | 459 | 1,136 | 1,611 (1,313 to 4,649) |
| Proxy | 258 | 257 | 886 | 1,077 (988 to 1,099) |
| Cache | 51 | 51 | 464 | 670 (615 to 734) |

Check your prediction against the first column:

- **Direct:** four round trips of 110 ms is 440 ms. Measured: 460.
- **Cache:** four round trips of 10 ms is 40 ms. Measured: 51. **Nine times faster,** with no change to the code, the server or the protocol.
- **Proxy:** the cache's 51, plus 200 ms. That's two trips to the origin, not one.

Why two? The proxy's connection to the origin is warm, so a request should cost one 100 ms round trip. A 1 KB object does take 137 ms. But a 20 KB one needs a second round trip, as if the connection were new. Here's the suspect:

~~~bash
docker compose -f compose.cdn.yaml exec lab ip netns exec origin sysctl net.ipv4.tcp_slow_start_after_idle
~~~

~~~text
net.ipv4.tcp_slow_start_after_idle = 1
~~~

When a connection has been idle, Linux assumes what it learned about the path is out of date, and drops the window back to 10 packets. So a "warm" connection that isn't busy isn't warm. Test it: set that to 0 on the origin, send a big object to grow the window, and time the same fetch again:

~~~text
after idle reset on (default): 256.6 ms
after idle reset off:          153.3 ms
~~~

That's the whole missing round trip. Whether to change it in production is a real trade-off, since the setting exists because old estimates can overwhelm a path. The point is that "we keep connections open" doesn't mean what it sounds like.

The other columns:

- **For 1 MB without loss, bandwidth starts to dominate.** 1 MB at 20 Mbit/s takes 400 ms whatever you do, so the cache's 464 is close to the floor. Direct still pays for slow start across 110 ms.
- **The 20 KB column doesn't change with 1% loss.** An object of 14 packets usually loses none of them. Loss hurts small objects in the tail, which a median doesn't show.
- **1 MB at 1% loss is the Mathis formula again.** The loss is on the last mile, for all three. Direct has to recover across 110 ms, and its interval reaches 4.6 seconds. The proxy recovers across 10 ms. That's why a proxy helps with content that **can't** be cached, such as your API's personal responses: it splits one long, lossy connection into a short lossy one and a long clean one.

**The cost.** To finish TLS, the edge must hold your certificate and see your traffic in plaintext. You're trusting the CDN with your users' data.

### How the user finds the edge: anycast

An edge only helps if each user reaches a nearby one. The two usual answers:

- **DNS:** answer with a different address depending on where the query came from.
- **Anycast:** announce the **same** address from every site, and let internet routing deliver each user to the nearest. If a site dies, it stops announcing, and traffic moves by itself. Cloudflare and the public DNS root servers work this way.

Routing between networks is done by **BGP**. The internet is about 75,000 independently run networks, called **autonomous systems** (ASes). Each tells its neighbours which addresses it can reach, and by what path. It's a **path-vector** protocol: an announcement carries the full list of ASes it passed through. So a network can reject a path that already contains itself, which prevents loops without anyone having a map of the whole internet.

Here's that idea in code. Each round, every AS hears its neighbours' paths from the round before and picks one. Keeping what each AS believes between rounds matters: after a failure, old paths don't vanish at once.

<!-- file: anycast/anycast.go -->
~~~go
// Package anycast simulates how path-vector routing (BGP's idea) picks a
// route to a prefix announced from several places.
package anycast

import "slices"

// AS is a network, identified by its number.
type AS int

// Net is the graph of who peers with whom, which ASes announce the shared
// address, and the path each AS currently believes in.
type Net struct {
	peers map[AS][]AS
	sites map[AS]bool
	best  map[AS][]AS
}

// New returns a network with no links.
func New() *Net {
	return &Net{peers: map[AS][]AS{}, sites: map[AS]bool{}, best: map[AS][]AS{}}
}

// Link connects a and b in both directions.
func (n *Net) Link(a, b AS) {
	n.peers[a] = append(n.peers[a], b)
	n.peers[b] = append(n.peers[b], a)
}

// Announce makes as a site of the anycast address; Withdraw stops it.
func (n *Net) Announce(as AS) { n.sites[as] = true }

// Withdraw removes a site, as when it fails.
func (n *Net) Withdraw(as AS) { delete(n.sites, as) }

// Routes runs the protocol until nothing changes, and returns each AS's
// chosen AS path (ending at a site) and the rounds that took. Each round,
// every AS hears its peers' paths from the round before; it ignores paths
// containing itself (loop prevention), prefers the shortest, and breaks ties
// by the lowest next hop. It starts from what each AS already believes, so
// after a Withdraw, old paths have to die out, as they do in real routing.
func (n *Net) Routes() (map[AS][]AS, int) {
	for round := 1; ; round++ {
		next := map[AS][]AS{}
		changed := false
		for as := range n.peers {
			var choice []AS
			if n.sites[as] {
				choice = []AS{as}
			} else {
				for _, peer := range n.peers[as] {
					path, ok := n.best[peer]
					if !ok || slices.Contains(path, as) {
						continue
					}
					candidate := append([]AS{as}, path...)
					if better(candidate, choice) {
						choice = candidate
					}
				}
			}
			if choice != nil {
				next[as] = choice
			}
			if !slices.Equal(choice, n.best[as]) {
				changed = true
			}
		}
		n.best = next
		if !changed {
			return n.best, round
		}
	}
}

func better(a, b []AS) bool {
	if b == nil {
		return true
	}
	if len(a) != len(b) {
		return len(a) < len(b)
	}
	return a[1] < b[1]
}

// Catchment returns which site as's traffic reaches, or false if none.
func Catchment(routes map[AS][]AS, as AS) (AS, bool) {
	path, ok := routes[as]
	if !ok {
		return 0, false
	}
	return path[len(path)-1], true
}
~~~

<!-- file: anycast/anycast_test.go -->
~~~go
package anycast

import (
	"slices"
	"testing"
)

// A line of networks, with sites at both ends:
//
//	1 - 2 - 3 - 4 - 5
func line() *Net {
	n := New()
	for a := AS(1); a < 5; a++ {
		n.Link(a, a+1)
	}
	n.Announce(1)
	n.Announce(5)
	return n
}

func TestEachNetworkReachesItsNearestSite(t *testing.T) {
	routes, _ := line().Routes()
	for as, want := range map[AS]AS{2: 1, 4: 5} {
		if got, ok := Catchment(routes, as); !ok || got != want {
			t.Errorf("AS %d reaches %d, want %d", as, got, want)
		}
	}
}

func TestATieGoesToTheLowestNextHop(t *testing.T) {
	routes, _ := line().Routes()
	if got, _ := Catchment(routes, 3); got != 1 {
		t.Errorf("AS 3 reaches %d, want 1: the path through 2", got)
	}
}

func TestWithdrawingASiteMovesItsCatchment(t *testing.T) {
	n := line()
	n.Withdraw(5)
	routes, _ := n.Routes()
	got, ok := Catchment(routes, 4)
	if !ok || got != 1 {
		t.Fatalf("AS 4 reaches %d (%v), want 1", got, ok)
	}
	if want := []AS{4, 3, 2, 1}; !slices.Equal(routes[4], want) {
		t.Errorf("path %v, want %v", routes[4], want)
	}
}

func TestWithdrawingEverySiteLeavesNoRoute(t *testing.T) {
	n := line()
	n.Withdraw(1)
	n.Withdraw(5)
	routes, _ := n.Routes()
	if _, ok := Catchment(routes, 3); ok {
		t.Error("no site remains, so no route should")
	}
}

func TestALoopIsNotChosen(t *testing.T) {
	// A ring, with one site: paths must not pass through a network twice.
	n := New()
	n.Link(1, 2)
	n.Link(2, 3)
	n.Link(3, 4)
	n.Link(4, 1)
	n.Announce(1)
	routes, _ := n.Routes()
	for as, path := range routes {
		seen := map[AS]bool{}
		for _, hop := range path {
			if seen[hop] {
				t.Errorf("AS %d's path %v has a loop", as, path)
			}
			seen[hop] = true
		}
	}
	if len(routes[3]) != 3 {
		t.Errorf("AS 3's path %v, want 3 hops", routes[3])
	}
}

func TestBadNewsTravelsHopByHop(t *testing.T) {
	// 1 - 2 - 3 - 4 - 5, and only site 5 at first: after it's withdrawn,
	// each network still believes its neighbour until that neighbour hears.
	n := New()
	for a := AS(1); a < 5; a++ {
		n.Link(a, a+1)
	}
	n.Announce(5)
	n.Routes()
	n.Withdraw(5)
	routes, rounds := n.Routes()
	if len(routes) != 0 {
		t.Errorf("routes %v, want none", routes)
	}
	if rounds < 5 {
		t.Errorf("%d rounds, want at least 5: one for each network to hear", rounds)
	}
}
~~~

<!-- file: cmd/anycast/main.go -->
~~~go
// Command anycast builds a small internet with three sites announcing one
// address, and shows where each network's traffic goes before and after a
// site fails.
package main

import (
	"fmt"
	"maps"
	"slices"

	"netlab/anycast"
)

const (
	london    anycast.AS = 100
	virginia  anycast.AS = 200
	singapore anycast.AS = 300
)

func main() {
	n := anycast.New()
	for _, l := range [][2]anycast.AS{
		{london, 1}, {virginia, 3}, {singapore, 5}, // the sites' transit providers
		{1, 2}, {2, 3}, {3, 4}, {4, 5}, {5, 1}, // a ring of transit networks
		{10, 1}, {20, 2}, {30, 3}, {40, 4}, {50, 5}, // users' networks
	} {
		n.Link(l[0], l[1])
	}
	for _, s := range []anycast.AS{london, virginia, singapore} {
		n.Announce(s)
	}
	routes, rounds := n.Routes()
	show("all three sites up", routes, rounds)
	n.Withdraw(virginia)
	routes, rounds = n.Routes()
	show("Virginia (AS 200) withdrawn", routes, rounds)
}

func show(title string, routes map[anycast.AS][]anycast.AS, rounds int) {
	fmt.Printf("%s: settled in %d rounds\n", title, rounds)
	for _, as := range slices.Sorted(maps.Keys(routes)) {
		if as >= 10 && as < 100 {
			site, _ := anycast.Catchment(routes, as)
			fmt.Printf("  users in AS %d reach site %d via %v\n", as, site, routes[as])
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race ./... -->

~~~bash
go run ./cmd/anycast
~~~

~~~text
all three sites up: settled in 5 rounds
  users in AS 10 reach site 100 via [10 1 100]
  users in AS 20 reach site 100 via [20 2 1 100]
  users in AS 30 reach site 200 via [30 3 200]
  users in AS 40 reach site 200 via [40 4 3 200]
  users in AS 50 reach site 300 via [50 5 300]
Virginia (AS 200) withdrawn: settled in 5 rounds
  users in AS 10 reach site 100 via [10 1 100]
  users in AS 20 reach site 100 via [20 2 1 100]
  users in AS 30 reach site 100 via [30 3 2 1 100]
  users in AS 40 reach site 300 via [40 4 5 300]
  users in AS 50 reach site 300 via [50 5 300]
~~~

Each network reaches its nearest site, with no central control and no site knowing about the others. Withdraw Virginia, and its users split between the two survivors. Each one's path gets longer, and so does its latency. `TestBadNewsTravelsHopByHop` shows the catch: news of a failure moves one hop per round, because each network believes its neighbours until they say otherwise.

What the simulator leaves out matters more than what it has:

- **Real BGP chooses by policy first.** Business relationships (who pays whom) come before path length. The nearest site by AS path may be far away by distance.
- **A round isn't instant.** Routers limit how often they send updates, with a suggested interval of 30 seconds for neighbours in other networks, so convergence can take minutes.
- **TCP and anycast disagree.** If routing shifts in the middle of a connection, packets arrive at a site that's never heard of it, and the connection resets. Long-lived connections need more care than short web requests.
- **BGP runs on trust.** A network can announce addresses it doesn't own, and neighbours may believe it. That has taken real services offline. RPKI signs who may announce what, but it doesn't cover everything yet.

**Explain it:** Why does a new HTTPS connection take four round trips for 20 KB? What did each row of the table save? Why does a proxy help content that can't be cached? What's `tcp_slow_start_after_idle` for, and what did it cost? What do you give up by letting a CDN finish your TLS? How does a path vector prevent loops? Why would a long-lived connection worry about anycast?

**Read.** Cloudflare's [learning center on anycast](https://www.cloudflare.com/learning/cdn/glossary/anycast-network/) and on [BGP](https://www.cloudflare.com/learning/security/glossary/what-is-bgp/). Nygren, Sitaraman and Sun, [*The Akamai Network*](https://dl.acm.org/doi/10.1145/1842733.1842736) (2010). [RFC 4271](https://www.rfc-editor.org/rfc/rfc4271) (BGP-4).

---

## Step 6: The method

### What this step teaches

- A checklist for "the network is slow", which you can use on a live system.
- Four kinds of slow, told apart by one command.

### Is it even the network?

Most "the network is slow" tickets aren't. Before anything else, split the time up. `curl` will do that for any URL. Go back to the two-host lab, and try it on the page server:

~~~bash
docker compose -f compose.cdn.yaml down
docker compose up -d
docker compose exec -d server bin/pageserver
./link.sh 40ms 100mbit 0%
docker compose exec client curl -sk --http1.1 -o /dev/null -w 'connect  %{time_connect}\ntls      %{time_appconnect}\nfirst    %{time_starttransfer}\ntotal    %{time_total}\n' https://server:8443/obj/1000000/1
~~~

~~~text
connect  0.041577
tls      0.128466
first    0.168451
total    0.428437
~~~

Those times are cumulative, in seconds. `connect` is one RTT: 41 ms. **A slow `connect` is the network, or a full accept queue.** The gap from `tls` to `first` is the server thinking: a big gap there is your application, not the network. `first` to `total` is the transfer. Note the TLS handshake took 87 ms, more than the one round trip you'd expect. This guide didn't chase that: it's the sort of thing you now know how to look into, with `tcpdump`.

### Four kinds of slow

Step 1 said `ss -ti` shows you the kernel's view. Here's why that's the most useful command in this bridge. This script breaks the link in one of four ways, and doesn't tell you which:

<!-- file: experiments/mystery.sh -->
~~~bash
#!/bin/bash
# Break the link in one of four ways, chosen at random, and don't say which.
# Then run a transfer and work out what's wrong. MYSTERY=1 to 4 picks one.
# The answer goes to results/.mystery; read it after you've decided.
set -eu
mkdir -p results
c() { docker compose exec -T "$@"; }
c -d server sh -c 'pgrep iperf3 || iperf3 -s' 2>/dev/null
pick=${MYSTERY:-$((RANDOM % 4 + 1))}
args="-c server -R -t 30 -C cubic -f m"
case $pick in
  1) ./link.sh 40ms 100mbit 1%;            answer="packet loss" ;;
  2) ./link.sh 40ms 100mbit 0% 3622;       answer="a deep queue at the bottleneck" ;;
  3) ./link.sh 40ms 100mbit 0%; args="$args -w 64K"; answer="small socket buffers" ;;
  4) ./link.sh 40ms 100mbit 0%; args="$args -b 5M";  answer="a sender with little to send" ;;
esac
echo "$answer" > results/.mystery
echo "Running. Look at the connection with ss -ti from another terminal."
c client iperf3 $args
~~~

<!-- run: chmod +x experiments/mystery.sh && bash -n experiments/mystery.sh -->

Run it. While it runs, look from a second terminal, and decide before you read the answer:

~~~bash
chmod +x experiments/mystery.sh
./experiments/mystery.sh
docker compose exec server ss -tin 'sport = :5201'
cat results/.mystery
~~~

These are the four cases, each captured on a run of the script, and trimmed:

~~~text
# 1: 3.2 Mbit/s
cubic rtt:43.657/5.532 cwnd:19 ssthresh:15 bytes_sent:6207576 bytes_retrans:56472 busy:15296ms retrans:0/39 minrtt:40
# 2: 95 Mbit/s
cubic rtt:189.599/1.93 cwnd:1779 ssthresh:739 bytes_sent:184203024 bytes_retrans:1448 busy:15432ms unacked:1527 minrtt:40.307
# 3: 12 Mbit/s
cubic rtt:41.757/0.57 cwnd:114 bytes_sent:25018072 busy:16196ms rwnd_limited:1160ms(7.2%) sndbuf_limited:14688ms(90.7%) minrtt:40.179 snd_wnd:77312
# 4: 5 Mbit/s
cubic rtt:49.156/1.782 cwnd:182 bytes_sent:9699328 app_limited busy:3924ms unacked:91 minrtt:40.463 snd_wnd:708608
~~~

Each has a different signature. Compare `rtt` with `minrtt`, look for retransmissions, and look for what the connection says is limiting it:

| Signature | Rate | Diagnosis | Fix |
|---|---|---|---|
| `bytes_retrans` around 1% of `bytes_sent`, small `cwnd`, `rtt` close to `minrtt` | Low | **Loss.** The window keeps being cut | Find the bad link; consider BBR for long paths |
| `rtt` many times `minrtt`, huge `cwnd`, few retransmissions | Fine | **A queue.** Bufferbloat: the transfer is fine, and everyone else suffers | Active queue management; BBR; a smaller buffer |
| `sndbuf_limited` or `rwnd_limited` taking most of `busy` time | Low | **Buffers or windows.** TCP would go faster if it were allowed | Raise the limit; check `tcp_wmem`, `tcp_rmem` and any fixed `SO_SNDBUF` |
| `busy` far below the connection's age, spare `cwnd`, no retransmissions | Low | **The application.** The network's waiting for you | Profile the sender (Performance Bridge) |

Case 3 is `iperf3 -w`, which fixes both socket buffers. That's a classic: a config file sets a buffer size that was sensible on a 10 Mbit/s LAN.

One warning from those captures: the `app_limited` flag means only "at this instant, the sender had nothing to send", so it shows up in cases 2 and 3 as well (it's trimmed from them above). Read `busy` over the connection's life, not a single flag.

### Counters over time

`ss` shows you connections alive now. For a whole machine, use counters. `nstat` shows what changed since it last ran:

~~~bash
docker compose exec server nstat -n
docker compose exec client iperf3 -c server -R -t 5 -C cubic -f m
docker compose exec server nstat TcpOutSegs TcpRetransSegs
~~~

~~~text
#kernel
TcpOutSegs                      1233               0.0
TcpRetransSegs                  17                 0.0
~~~

17 retransmissions out of 1,233 segments: 1.4%. Graph `TcpRetransSegs` divided by `TcpOutSegs` on your hosts, and you'll see trouble before users report it.

### The checklist: "the network is slow"

**Name the symptom first.** Is it slow to connect, slow to first byte, or slow to transfer? For one user, or for all? Since when? What changed?

1. **Split the time.** `curl -w` as above. If the time is before the first byte and after TLS, it's the server. Stop here, and use the Performance Bridge.
2. **Rule out DNS.** Add `%{time_namelookup}` to `curl -w`. Cold DNS can add hundreds of milliseconds, and a timed-out resolver adds seconds. Phase 5 covers this.
3. **Measure RTT idle, then under load.** `ping` while nothing's running, and again during the transfer. If it rises sharply under load, there's a queue.
4. **Read the connection.** `ss -ti`, and use the table above: loss, queue, window or application?
5. **Look at the counters.** `nstat` for retransmissions, and `ip -s link` for interface errors and drops. `tc -s qdisc` for queue drops.
6. **Find where.** `mtr` shows loss by hop, though a router dropping `ping` replies isn't always a router dropping your traffic. Compare from two vantage points, and test each hop's segment on its own.
7. **Capture.** `tcpdump` on both ends, if you can. Compare what one side sent with what the other received. Know where the capture point sits (step 2).
8. **Test an MTU problem** if small requests work and large ones hang: `ping -M do -s 1472`. A firewall that blocks ICMP can break path MTU discovery.
9. **Change one thing, and measure again** with repeats and a baseline. Check the setting took effect, by reading it back.

**And out loud, in an interview:** say what you're ruling out and why, and give the number you'd expect before you look.

### What this bridge found

| Question | Answer, on this lab |
|---|---|
| What does 1% loss cost Reno? | 96% of a 95 Mbit/s link, within the Mathis formula at every point |
| Does BBR fix that? | Yes: 91 Mbit/s against 3, on random loss |
| What does it cost? | On a shallow queue, it starved CUBIC: 92.9 Mbit/s to 0.28 |
| What's a big buffer worth? | Nothing in throughput, and 130 ms of added latency for everyone |
| Is HTTP/3 faster than HTTP/2? | For small requests next to big ones, roughly 4 to 5 times, from no head-of-line blocking. For bulk transfer, the gap was an implementation's loss recovery |
| Why's HTTP/2 slow at no loss? | Mostly its send buffer: `tcp_notsent_lowat` took a tiny request from 218 ms to 86 |
| What does a CDN save? | Nine times, on a small object served from cache |
| What's a warm connection worth? | One round trip less than you'd think, unless idle reset is off |

Four times in this bridge a measurement looked fine and was wrong, or looked clear and meant something else: netem's per-burst loss on TCP, then on UDP; a sysctl that never applied; and HTTP/3's win that had nothing to do with blocking. None of them failed loudly. That's the skill to keep. If an AI assistant gives you a network experiment, ask what it checked about its own instrument.

**Explain it:** Name the four kinds of slow, and how you'd tell them apart. What can `curl -w` rule out in ten seconds? Why isn't `app_limited` enough by itself? Which three steps of the checklist would you do first for a user who reports that uploads are slow?

**Read.** Brendan Gregg, *Systems Performance*, 2nd edition, chapter 10 (network). Julia Evans, [*Networking! ACK!*](https://wizardzines.com/zines/networking/) and [*Bite Size Networking*](https://wizardzines.com/zines/bite-size-networking/).

---

## Checkpoint

You've finished when you can do all of this, without looking anything up:

- Work out a bandwidth-delay product, and say what window a link needs.
- Derive the Mathis formula, and predict what happens when loss or RTT changes.
- Read a retransmission in `tcpdump` output and a connection in `ss -ti`.
- Explain what each of Reno, CUBIC and BBR treats as its signal, and what each one costs.
- Explain bufferbloat, and what actually fixes it.
- Say what HTTP/3 does and doesn't change, with numbers.
- Say what a CDN saves, and what you give up for it.
- Explain anycast, a path vector, and how BGP can go wrong.
- Work through "the network is slow", out loud.

Then do the [exercise](exercises.md): your own path, your own numbers.

## If it goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: Specified qdisc kind is unknown` | `sch_netem` isn't loaded | The `modprobe` from step 1 |
| `bbr` isn't in the list, or `iperf3 -C bbr` fails | `tcp_bbr` isn't loaded, or a WSL restart unloaded it | The `modprobe` from step 1 |
| Results far better than the formula | Bursts are being dropped as one | Run `experiments/drops.sh`; check `gso_max_segs` |
| `iperf3: the server is busy` | A last run is still finishing, or two experiments overlap | Wait; run one experiment at a time |
| The clock jumps, and a run has very few results | The laptop slept, and froze the lab | Throw those runs away, and keep it awake |
| `Read-only file system` from `sysctl` | A container's `/proc/sys` is read-only | The privileged container in `lowat.sh` |
| The direct path fails with three containers | Docker drops traffic between its networks | Use the namespaces in `cdn.sh` |
| `bin/pagefetch: not found` in a container | Built with cgo, or not built | `CGO_ENABLED=0 go build -o bin/ ./cmd/...` |
| `ping: time of day goes back` | The VM's clock is being corrected, often after sleep. Durations from wall-clock timestamps can't be trusted | Ignore that sample. Restarting WSL doesn't clear it reliably. If `timedatectl timesync-status` shows an offset over 0.4 s on a 32 s poll, WSL's `chrony` and `timesyncd` are fighting: run `sudo timedatectl set-ntp false` |
| A setting seems to make no difference | It may never have applied | Read it back |

## Reading list for this phase

- Peterson and Davie, [*Computer Networks: A Systems Approach*](https://book.systemsapproach.org/), with their companion [*TCP Congestion Control: A Systems Approach*](https://tcpcc.systemsapproach.org/).
- Kurose and Ross, *Computer Networking: A Top-Down Approach*, 8th edition: chapters 3 and 5.
- Brendan Gregg, *Systems Performance*, 2nd edition: chapter 10.
- The papers linked from each step.
