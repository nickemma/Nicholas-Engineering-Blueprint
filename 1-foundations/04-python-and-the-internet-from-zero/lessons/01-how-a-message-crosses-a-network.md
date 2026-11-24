# 01 How a message crosses a network

> Module: Python and the internet from zero · Time: ~3 h · Builds on: Foundations 03

## The problem

So far, every program you've written has talked only to files and to your terminal. Almost everything you'll build from here talks to another program, often on another machine: a client calls a server, a server calls a database, a node calls the other nodes in its cluster. When that goes wrong, the error says things like `connection refused`, `no route to host` or `i/o timeout`, and you can't fix what you can't picture. This lesson gives you the picture: what an address is, what a port is, and how a message gets from one machine to another.

## The mental model

~~~text
 your laptop                                                         a server
 ┌───────────────────────┐                                     ┌───────────────────────┐
 │ program ──▶ port 51234 │                                     │ port 443 ──▶ program  │
 │ address 192.168.0.23   │                                     │ address 104.20.23.154 │
 └──────────┬────────────┘                                     └──────────▲────────────┘
            │ packet: from 192.168.0.23:51234, to 104.20.23.154:443, data   │
            ▼                                                               │
       home router ───▶ your provider's routers ───▶ ... ───▶ the server's network
       each router reads only the "to" address and passes the packet one hop closer
~~~

- Every machine on a network has an **IP address**, such as `192.168.0.23`. It says *which machine*.
- On each machine, many programs use the network at once. A **port**, a number from 1 to 65535, says *which program* on that machine. A web server usually listens on port 80 (HTTP) or 443 (HTTPS).
- Data travels in **packets**: small pieces, each carrying the address and port it's from and the address and port it's going to, then some data.
- A **router** forwards packets between networks. It doesn't know the whole path: it looks at the destination address and passes the packet to the next router that's closer. Your home router is the first one; the internet is thousands more.

## The pattern

**Name the layer before you debug.** "It doesn't work" becomes one of: this machine has no address on the right network; the address is right but nothing is listening on that port; or the packets get lost on the way. Each has its own tool, and this lesson introduces three of them: `ip`, `ping` and `traceroute`.

## Build it

There's no code in this lesson. You'll look at your own machine's network with the tools engineers use on every Linux server.

### Step 1: Install the network tools

These are the tools for this lesson and the next two. Some may already be installed:

~~~bash
sudo apt update && sudo apt install -y iproute2 iputils-ping traceroute dnsutils netcat-openbsd tcpdump curl
~~~

~~~text
Setting up tcpdump (4.99.4-3ubuntu4.24.04.1) ...
Setting up dnsutils (1:9.18.39-0ubuntu0.24.04.9) ...
Processing triggers for libc-bin (2.39-0ubuntu8.12) ...
~~~

**macOS:** `ping`, `traceroute`, `dig`, `nc`, `tcpdump` and `curl` come with the system. There's no `ip` command; use `ifconfig` instead (step 2 shows the difference).

### Step 2: Your machine's addresses

~~~bash
ip addr
~~~

~~~text
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host 
       valid_lft forever preferred_lft forever
2: eth0@if175: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default 
    link/ether b2:35:3e:a5:3e:b7 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
       valid_lft forever preferred_lft forever
~~~

Each numbered block is a **network interface**: a way into a network, real or virtual.

- `lo` is the **loopback** interface, with the address `127.0.0.1`. It isn't connected to any wire: anything sent to `127.0.0.1` comes straight back to the same machine. It's how two programs on one machine talk over the network, and you'll use it in every lesson of this module.
- The second interface is the one that leads off the machine: `eth0` here (on a laptop with Wi-Fi it may be `wlan0` or `wlp2s0`). Its line `inet 172.17.0.2/16` gives the address, and `/16` says how much of it names the network: the first 16 bits, `172.17`. Every address starting `172.17.` is on the same local network and can be reached directly; anything else has to go through a router.
- The `link/ether` line is the interface's hardware (MAC) address. It's only used to reach the next device on the same local network, never further.
- `inet6` lines are IPv6 addresses, the newer, longer kind. `::1` is IPv6's loopback.

This output was captured in a container, so it shows a container's virtual network. On WSL you'll see `eth0` with an address like `172.28.x.x`; on a laptop running Linux directly, your Wi-Fi or Ethernet interface with your home network's address, often `192.168.x.x`. Addresses that start `10.`, `172.16.` to `172.31.`, or `192.168.` are **private**: they're reused inside millions of separate networks and never appear on the internet itself. Your home router swaps your private address for its one public address on the way out.

**macOS:** `ifconfig` shows the same information. `lo0` is the loopback, and `en0` is usually Wi-Fi.

### Step 3: Where packets go next

~~~bash
ip route
~~~

~~~text
default via 172.17.0.1 dev eth0 
172.17.0.0/16 dev eth0 proto kernel scope link src 172.17.0.2 
~~~

This is the **routing table**: the machine's rules for where to send each packet.

- `172.17.0.0/16 dev eth0` says: addresses on the local network go straight out of `eth0`.
- `default via 172.17.0.1` says: everything else goes to the router at `172.17.0.1`, the **default gateway**. That's the first hop of every packet to the internet.

**macOS:** `netstat -rn` shows the routing table; `route -n get default` shows the gateway.

### Step 4: Is it reachable? `ping`

`ping` sends a small packet that asks the destination to send it straight back, and times the round trip. First, the loopback:

~~~bash
ping -c 3 127.0.0.1
~~~

~~~text
PING 127.0.0.1 (127.0.0.1) 56(84) bytes of data.
64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.702 ms
64 bytes from 127.0.0.1: icmp_seq=2 ttl=64 time=0.077 ms
64 bytes from 127.0.0.1: icmp_seq=3 ttl=64 time=0.056 ms

--- 127.0.0.1 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2051ms
rtt min/avg/max/mdev = 0.056/0.278/0.702/0.299 ms
~~~

`-c 3` sends three and stops (without it, `ping` runs until you press Ctrl+C). Each reply line shows the round-trip time. A tiny fraction of a millisecond: the packet never left the machine.

Now a server on the internet, run by Cloudflare:

~~~bash
ping -c 3 one.one.one.one
~~~

~~~text
PING one.one.one.one (1.0.0.1) 56(84) bytes of data.
64 bytes from one.one.one.one (1.0.0.1): icmp_seq=1 ttl=45 time=181 ms
64 bytes from one.one.one.one (1.0.0.1): icmp_seq=2 ttl=45 time=240 ms
64 bytes from one.one.one.one (1.0.0.1): icmp_seq=3 ttl=45 time=252 ms

--- one.one.one.one ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 4361ms
rtt min/avg/max/mdev = 180.755/224.236/252.100/31.149 ms
~~~

- `one.one.one.one` is a name. `ping` looked up its address first (`1.0.0.1`); lesson 02 is about how.
- The round trip is now many milliseconds, thousands of times longer than the loopback: the packet crossed real networks, there and back. Your times depend on where you are: tens of milliseconds is common, and hundreds if the nearest Cloudflare server is far away.
- The times vary from one packet to the next. The network is shared, and every router on the way has a queue. You'll measure this kind of variation properly in lesson 09.
- `ttl` (time to live) is a counter in every packet. Each router subtracts one, and a router that brings it to zero drops the packet instead of passing it on, so a packet caught in a loop doesn't circle forever. The reply started at 64 or so and arrived with fewer: roughly how many routers it crossed.

Some servers and networks block ping, so "no reply" doesn't prove the server is down. It only proves ping didn't get through.

### Step 5: The path packets take: `traceroute`

`traceroute` uses `ttl` to map the path. It sends a packet with `ttl` 1, which the first router drops, and that router sends back an error naming itself. Then `ttl` 2 reaches the second router, and so on.

~~~bash
traceroute -n -m 3 -q 1 1.1.1.1
~~~

~~~text
traceroute to 1.1.1.1 (1.1.1.1), 3 hops max, 60 byte packets
 1  172.17.0.1  1.779 ms
 2  172.28.240.1  0.702 ms
 3  192.168.0.1  2.379 ms
~~~

- `-n` shows addresses without looking up their names (faster). `-q 1` sends one probe per hop instead of three. `-m 3` stops after three hops.
- Hop 1 is the container's gateway, hop 2 is WSL's virtual router (WSL runs Linux behind its own small network on Windows), and hop 3 is the home router. All three addresses are private.

Run it yourself without `-m 3`: the path continues through your internet provider's routers until it reaches `1.1.1.1`, usually in 8 to 20 hops. We stopped this capture at three because the later hops belong to the author's provider. A `*` means a router didn't answer the probe; many don't, and the trace carries on past them.

## Break it

**An address on no network.** `10.255.255.1` is a private address that, on most home networks, belongs to nothing:

~~~bash
ping -c 2 -W 1 10.255.255.1
~~~

~~~text
PING 10.255.255.1 (10.255.255.1) 56(84) bytes of data.

--- 10.255.255.1 ping statistics ---
2 packets transmitted, 0 received, 100% packet loss, time 1019ms
~~~

The packets went to the default gateway like any others, and vanished. No error came back, only silence: `-W 1` gave up waiting after a second for each, and `ping` exited with 1. This is what a lost packet looks like, and why every network program needs a time limit (you'll add one to a server in lesson 04).

## Check it

Without looking back, answer from your own machine:

1. What's your loopback address, and what's your main interface's address? Is it private?
2. What's your default gateway?
3. Roughly how long is a round trip to `one.one.one.one` from where you are?

This lesson gives you the map. It doesn't cover how a name like `one.one.one.one` became an address, or how two programs keep a conversation going across lost and reordered packets: those are the next two lessons.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `ip: command not found` | `iproute2` isn't installed, or you're on macOS | `sudo apt install -y iproute2`; on macOS use `ifconfig` |
| `ping: socket: Operation not permitted` | Some systems only let administrators send ping packets | Run it with `sudo` |
| `ping` to a public name: `Temporary failure in name resolution` | No working DNS (lesson 02), often no network at all | Check `ip route` has a `default` line, then try `ping -c 3 1.1.1.1` |
| `traceroute` shows only `* * *` after a few hops | Those routers don't answer, or a firewall drops the probes | Normal. Try `traceroute -I` (uses ping packets, needs `sudo`) |
| WSL: `ping` works but the times look odd | WSL's virtual network adds a hop and some delay | Expected. It's the same on every WSL machine |
