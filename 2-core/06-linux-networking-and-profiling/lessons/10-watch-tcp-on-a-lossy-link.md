# 10 Watch TCP on a lossy link

## The problem

A slow response can come from a busy process, packets in flight, or loss recovery. You need evidence from a connection to tell them apart.

## The mental model

A TCP connection has a handshake, a send window, and queues on the path. RTT multiplied by bandwidth gives one flight of data. Sending past that window can make a queue grow.

## The pattern

Use a private link you can impair, verify the qdisc counters, and read at least one independent signal from the socket or packet capture.

## Build it

### Step 1. See a readiness event before receiving bytes

Create `labs/readiness.py`.

<!-- file: labs/readiness.py -->
~~~python
import select
import socket

reader, sender = socket.socketpair()
with reader, sender, select.epoll() as poller:
    poller.register(reader, select.EPOLLIN)
    assert not poller.poll(0)
    sender.sendall(b"job")
    ready = poller.poll(1)
    assert any(fd == reader.fileno() and flags & select.EPOLLIN for fd, flags in ready)
    print(f"ready fd; read {reader.recv(3)!r}")

bandwidth_bits_per_second = 100_000_000
round_trip_seconds = 0.040
print(f"100 Mbit/s * 40 ms / 8 = {bandwidth_bits_per_second * round_trip_seconds / 8:.0f} bytes")
~~~

~~~bash
python3 labs/readiness.py
~~~

<!-- run: python3 labs/readiness.py -->

~~~text
ready fd; read b'job'
100 Mbit/s * 40 ms / 8 = 500000 bytes
~~~

Epoll reports eligible file descriptors. With io_uring, applications can place I/O operations on a submission ring and consume their completion entries later. Those entries carry operation results. Keep the actual readiness drill and the completion model separate when explaining latency. [Linux epoll manual](https://man7.org/linux/man-pages/man7/epoll.7.html) · [liburing manual](https://kernel.googlesource.com/pub/scm/linux/kernel/git/axboe/liburing/+/refs/heads/master/man/io_uring.7)

### Step 2. Put two endpoints on their own lab network

The image contains the tools for this lab and lesson 14. Capabilities apply to the lab containers. Their egress qdiscs can shape delay and loss on traffic leaving them.

Create `wire/tools/Dockerfile`.

<!-- file: wire/tools/Dockerfile -->
~~~text
FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 iperf3 iputils-ping tcpdump ethtool ca-certificates \
 && rm -rf /var/lib/apt/lists/*
~~~

Create `labs/tcp.sh`.

<!-- file: labs/tcp.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail

image=${WIRE_NET_IMAGE:-switchyard-wire-tools:lab}
id="wire-tcp-$(id -u)-$$"
server="$id-server"
client="$id-client"
data=$(mktemp -d)
capture=
cleanup() {
  if [[ -n "$capture" ]]; then
    kill "$capture" 2>/dev/null || true
    wait "$capture" 2>/dev/null || true
  fi
  docker rm -f "$client" "$server" >/dev/null 2>&1 || true
  docker network rm "$id" >/dev/null 2>&1 || true
  rm -rf "$data"
}
trap cleanup EXIT
docker network create "$id" >/dev/null
docker run -d --name "$server" --network "$id" --network-alias server \
  --cap-add NET_ADMIN "$image" iperf3 -s >/dev/null
docker run -d --name "$client" --network "$id" --cap-add NET_ADMIN "$image" sleep infinity >/dev/null

for box in "$client" "$server"; do
  docker exec "$box" ethtool -K eth0 tso off gso off gro off
  docker exec "$box" tc qdisc replace dev eth0 root netem delay 20ms
done
docker exec "$server" tc qdisc replace dev eth0 root netem delay 20ms rate 100mbit limit 2000
docker exec "$client" ping -q -c 3 -W 2 server | tail -2

timeout 15 docker exec "$server" tcpdump -U -nn -i eth0 -c 3 'tcp port 5201' >"$data/handshake.txt" 2>&1 &
capture=$!
for ((attempt=0; attempt<40; attempt++)); do
  if grep -q 'listening on' "$data/handshake.txt"; then break; fi
  sleep .1
done
docker exec "$client" iperf3 -c server -R -t 3 -J >"$data/clean.json"
wait "$capture"
capture=
grep 'Flags' "$data/handshake.txt"

docker exec "$server" tc qdisc replace dev eth0 root netem delay 20ms loss 0.1% rate 100mbit limit 2000
docker exec "$client" iperf3 -c server -R -t 4 -J >"$data/loss.json" &
traffic=$!
sleep 1
docker exec "$server" ss -ti '( sport = :5201 )'
wait "$traffic"
docker exec "$server" tc -s qdisc show dev eth0
python3 - "$data" <<'RESULT'
import json
from pathlib import Path
import sys

for kind in ("clean", "loss"):
    path = Path(sys.argv[1]) / f"{kind}.json"
    end = json.loads(path.read_text())["end"]
    received = end["sum_received"]["bits_per_second"] / 1_000_000
    retransmits = end["sum_sent"]["retransmits"]
    print(f"{kind}: {received:.1f} Mbit/s; sender retransmits={retransmits}")
RESULT
~~~

### Step 3. Read the handshake and count the drops

The first three packets show SYN, SYN+ACK, and ACK. The reverse transfer sends from the server toward the client. Both runs use the same delay and 100 Mbit/s limit. The second adds random loss on the server's egress.

~~~bash
docker build -t switchyard-wire-tools:lab wire/tools
bash labs/tcp.sh
~~~

~~~text
rtt min/avg/max/mdev = 40.369/54.953/83.706/20.332 ms
10:14:02.065412 IP 172.27.0.3.57978 > 172.27.0.2.5201: Flags [S], seq 759390959, win 64240, options [mss 1460,sackOK,TS val 4088240583 ecr 0,nop,wscale 10], length 0
10:14:02.085731 IP 172.27.0.2.5201 > 172.27.0.3.57978: Flags [S.], seq 811599742, ack 759390960, win 65160, options [mss 1460,sackOK,TS val 2646117489 ecr 4088240583,nop,wscale 10], length 0
10:14:02.106138 IP 172.27.0.3.57978 > 172.27.0.2.5201: Flags [.], ack 1, win 63, options [nop,nop,TS val 4088240624 ecr 2646117489], length 0
qdisc netem 8008: root refcnt 17 limit 2000 delay 20ms loss 0.1% rate 100Mbit
 Sent 88555432 bytes 58524 pkt (dropped 3, overlimits 0 requeues 0)
clean: 90.1 Mbit/s; sender retransmits=0
loss: 91.5 Mbit/s; sender retransmits=17
~~~

The bandwidth-delay product estimates bytes in flight at a given RTT and rate. Read `rtt`, `cwnd`, and retransmission fields in the socket snapshot. A short transfer can also be limited by startup and loss recovery. Check the drop count against the direction and number of packets you actually sent.

## Check it

Find the three handshake flags in the capture. Compute the BDP for the configured rate and measured RTT. Explain why a packet that is lost can add much more than its transmission time to a request.

## If it goes wrong

If a qdisc command reports permission denied, check NET_ADMIN on the lab containers. If shaped drops and retransmits disagree, inspect offloads and the direction of the measurement.
