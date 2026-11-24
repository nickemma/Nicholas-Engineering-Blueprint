# 02 Names: DNS

> Module: Python and the internet from zero · Time: ~3 h · Builds on: 01

## The problem

Packets carry addresses, but people and configuration files use names: `example.com`, `db.internal`, `one.one.one.one`. Something has to turn each name into an address before a single packet is sent, and when it fails, nothing else even starts. "It works with the IP but not the name", "it works on my machine but not on the server", "I changed the record an hour ago and it still goes to the old server": all of these are name problems. This lesson shows you where a name's address comes from, and how to ask each source directly.

## The mental model

~~~text
 your program asks: "what's the address of example.com?"
        │
        ▼
 1. /etc/hosts         a local file. If the name is here, that's the answer.
        │ not there
        ▼
 2. a resolver         a DNS server your machine is set to ask (/etc/resolv.conf).
        │              It answers from its cache, or finds out:
        ▼
 3. the DNS tree       root servers  ──▶  "ask the .com servers"
                       .com servers  ──▶  "ask example.com's own servers"
                       example.com's servers ──▶ "104.20.23.154, good for 300 seconds"
~~~

- **DNS**, the Domain Name System, is a worldwide, distributed database of names. Nobody holds all of it: each part of a name is answered by whoever owns it.
- A **record** is one fact about a name. An `A` record gives an IPv4 address; `AAAA` an IPv6 address; `CNAME` says "this name is an alias for another name".
- Every record has a **TTL** (time to live), in seconds: how long anyone may keep a copy before asking again. It's why a changed record can take a while to reach everyone.
- A **resolver** does the walk down the tree for you and caches the answers, so most lookups take a millisecond or two.

## The pattern

**Ask each layer separately.** `getent hosts NAME` asks the way programs ask (the hosts file first, then DNS). `dig NAME` asks a DNS server directly, skipping the hosts file. When they disagree, you've found which layer is wrong.

## Build it

### Step 1: How your programs look up a name

~~~bash
getent hosts localhost
~~~

~~~text
::1             localhost ip6-localhost ip6-loopback
~~~

`getent hosts` looks a name up exactly the way most programs on Linux do, and prints the address it got: `::1`, the IPv6 loopback (when a name has both kinds of address, IPv6 usually comes first). `localhost` resolved without any network at all, because the answer is in a local file:

~~~bash
cat /etc/hosts
~~~

~~~text
127.0.0.1	localhost
::1	localhost ip6-localhost ip6-loopback
fe00::	ip6-localnet
ff00::	ip6-mcastprefix
ff02::1	ip6-allnodes
ff02::2	ip6-allrouters
172.17.0.2	552c41f25429
~~~

Each line is an address followed by names for it. `localhost` is here twice: `127.0.0.1` for IPv4 and `::1` for IPv6. The last line is the container's own name; your file will have your machine's.

**macOS:** there's no `getent`. Use `dscacheutil -q host -a name localhost`.

### Step 2: Which DNS server you ask

Names that aren't in `/etc/hosts` go to a resolver. Its address is in another file:

~~~bash
grep -v "^#" /etc/resolv.conf | grep .
~~~

~~~text
nameserver 10.255.255.254
~~~

`10.255.255.254` is WSL's own resolver, which passes questions on to Windows. On a Linux laptop you'll often see `nameserver 127.0.0.53`, a small resolver (`systemd-resolved`) running on your own machine, which caches answers and forwards questions to your router or provider.

**macOS:** `scutil --dns | head -20` shows the resolvers.

### Step 3: Ask DNS directly with `dig`

~~~bash
dig example.com
~~~

~~~text

; <<>> DiG 9.18.39-0ubuntu0.24.04.9-Ubuntu <<>> example.com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 27877
;; flags: qr rd ra; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 4096
;; QUESTION SECTION:
;example.com.			IN	A

;; ANSWER SECTION:
example.com.		104	IN	A	104.20.23.154
example.com.		104	IN	A	172.66.147.243

;; Query time: 56 msec
;; SERVER: 10.255.255.254#53(10.255.255.254) (UDP)
;; WHEN: Thu Nov 19 08:56:41 UTC 2026
;; MSG SIZE  rcvd: 72
~~~

Read it from the top:

- `status: NOERROR` means the name exists and the server answered. `ANSWER: 2` means two records came back.
- The `QUESTION SECTION` repeats what was asked: `example.com`, class `IN` (internet), type `A` (an IPv4 address). `A` is `dig`'s default.
- The `ANSWER SECTION` has the records. Each line reads: name, TTL in seconds, class, type, value. `example.com` has two addresses; a client may use either, which spreads the load.
- `Query time` is how long the resolver took. `SERVER` is the resolver that answered, the one from `/etc/resolv.conf`.

Ask for a different type with `dig example.com AAAA` (IPv6 addresses), and get just the answer with `dig +short example.com`.

### Step 4: Caching, seen through the TTL

Ask twice, ten seconds apart. `+noall +answer` prints only the answer lines:

~~~bash
dig +noall +answer example.com; sleep 10; dig +noall +answer example.com
~~~

~~~text
example.com.		103	IN	A	172.66.147.243
example.com.		103	IN	A	104.20.23.154
example.com.		93	IN	A	104.20.23.154
example.com.		93	IN	A	172.66.147.243
~~~

The TTL went *down* by ten. The resolver didn't ask again: it answered from its cache, and the TTL now says how long that cached copy has left. When it reaches zero, the resolver throws the copy away and asks example.com's servers again, and the TTL starts from the top. This is why changing a record isn't instant: every resolver that has a copy keeps using it until its TTL runs out. (The two addresses also swapped places. Resolvers often rotate the order, so that clients that take the first address spread across both.)

### Step 5: The whole walk, with `+trace`

`dig +trace` walks the tree itself, from the root down, printing each step. It needs one resolver to give it the list of root servers; `@1.1.1.1` asks Cloudflare's public resolver for that, because WSL's resolver doesn't answer that question (see "If it goes wrong"):

~~~bash
dig +trace +nodnssec @1.1.1.1 example.com
~~~

~~~text

; <<>> DiG 9.18.39-0ubuntu0.24.04.9-Ubuntu <<>> +trace +nodnssec @1.1.1.1 example.com
; (1 server found)
;; global options: +cmd
.			508842	IN	NS	a.root-servers.net.
.			508842	IN	NS	b.root-servers.net.
.			508842	IN	NS	c.root-servers.net.
.			508842	IN	NS	d.root-servers.net.
.			508842	IN	NS	e.root-servers.net.
.			508842	IN	NS	f.root-servers.net.
.			508842	IN	NS	g.root-servers.net.
.			508842	IN	NS	h.root-servers.net.
.			508842	IN	NS	i.root-servers.net.
.			508842	IN	NS	j.root-servers.net.
.			508842	IN	NS	k.root-servers.net.
.			508842	IN	NS	l.root-servers.net.
.			508842	IN	NS	m.root-servers.net.
;; Received 239 bytes from 1.1.1.1#53(1.1.1.1) in 175 ms

com.			172800	IN	NS	l.gtld-servers.net.
com.			172800	IN	NS	c.gtld-servers.net.
com.			172800	IN	NS	m.gtld-servers.net.
com.			172800	IN	NS	i.gtld-servers.net.
com.			172800	IN	NS	d.gtld-servers.net.
com.			172800	IN	NS	g.gtld-servers.net.
com.			172800	IN	NS	j.gtld-servers.net.
com.			172800	IN	NS	e.gtld-servers.net.
com.			172800	IN	NS	h.gtld-servers.net.
com.			172800	IN	NS	k.gtld-servers.net.
com.			172800	IN	NS	a.gtld-servers.net.
com.			172800	IN	NS	b.gtld-servers.net.
com.			172800	IN	NS	f.gtld-servers.net.
;; Received 864 bytes from 192.33.4.12#53(c.root-servers.net) in 395 ms

example.com.		172800	IN	NS	hera.ns.cloudflare.com.
example.com.		172800	IN	NS	elliott.ns.cloudflare.com.
;; Received 359 bytes from 192.31.80.30#53(d.gtld-servers.net) in 235 ms

example.com.		300	IN	A	104.20.23.154
example.com.		300	IN	A	172.66.147.243
;; Received 72 bytes from 173.245.58.162#53(hera.ns.cloudflare.com) in 271 ms
~~~

Read it in four blocks:

1. `.` (the root) and 13 servers, `a.root-servers.net` to `m.root-servers.net`, from `1.1.1.1`. Every resolver keeps this list.
2. One root server (`c.root-servers.net` this time; `dig` picks one) answered with the servers for `com.`. It doesn't know `example.com`; it knows who's responsible for `com`.
3. A `com` server answered with the servers for `example.com.`, which are Cloudflare's.
4. One of example.com's own servers answered with the `A` records, each with a TTL of 300: five minutes, the full TTL, because this answer came from the source and not from a cache.

Every lookup that isn't cached goes through these steps. `+nodnssec` leaves out the signatures that DNSSEC adds to prove the answers weren't forged; you'll meet DNSSEC in the cloud and network track.

## Break it

**A name that doesn't exist.** The `.invalid` top-level domain is reserved, so nothing under it ever exists:

~~~bash
dig nosuch.invalid | grep -E "status|ANSWER:"; getent hosts nosuch.invalid; echo "getent exit: $?"
~~~

~~~text
;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 3413
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 1, ADDITIONAL: 1
getent exit: 2
~~~

`NXDOMAIN` ("non-existent domain") is DNS saying no such name. `getent` printed nothing and exited with 2. In a program, it shows up as `no such host` (Go) or `Name or service not known` (Python).

**The hosts file wins.** Give a made-up name an address in `/etc/hosts`, then ask both ways:

~~~bash
echo "127.0.0.1 blueprint.test" | sudo tee -a /etc/hosts
getent hosts blueprint.test
dig +short blueprint.test; echo "dig printed nothing: exit $?"
ping -c 1 blueprint.test
~~~

~~~text
127.0.0.1 blueprint.test
127.0.0.1       blueprint.test
dig printed nothing: exit 0
PING blueprint.test (127.0.0.1) 56(84) bytes of data.
64 bytes from localhost (127.0.0.1): icmp_seq=1 ttl=64 time=0.238 ms

--- blueprint.test ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 0.238/0.238/0.238/0.000 ms
~~~

`getent` and `ping` found it, because they read `/etc/hosts` first. `dig` found nothing, because it only asks DNS. This is the most common "it works here but not there" with names: an old line in someone's `/etc/hosts`. When a name resolves differently on two machines, compare `getent hosts` and `dig` on both.

Take the line out again (`sudo sed -i '/blueprint.test/d' /etc/hosts`) once you've seen it. On WSL, `/etc/hosts` is rewritten from Windows each time WSL starts, unless `/etc/wsl.conf` says otherwise.

## Check it

Without looking back:

1. Find the addresses of `go.dev` with `dig +short`, and its TTL with `dig +noall +answer`.
2. Which resolver does your machine use?
3. Make `getent hosts` and `dig` disagree about a name, explain why they disagree, then undo it.

That proves you can find out where an address comes from. It doesn't say how a program uses the address to open a conversation: that's the next lesson.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `dig: command not found` | `dnsutils` isn't installed | `sudo apt install -y dnsutils` |
| `;; connection timed out; no servers could be reached` | The resolver in `/etc/resolv.conf` doesn't answer | Check the network (lesson 01). Try another resolver: `dig @1.1.1.1 example.com` |
| `dig +trace` prints `communications error to 10.255.255.254#53: timed out` three times, then `no servers could be reached` | WSL's resolver doesn't answer the question `+trace` asks first (which servers are the root?) | Name another resolver: `dig +trace @1.1.1.1 example.com` |
| `dig +trace @1.1.1.1` stops with timeouts | Your network blocks DNS to servers other than its own resolver | Common on company and some home networks. Read the walk from this lesson's output instead |
| The TTL doesn't go down between two `dig`s | Your resolver didn't cache it, or the two queries went to different resolvers | Try again with `dig @1.1.1.1` both times |
| WSL: your edit to `/etc/hosts` disappeared | WSL regenerates the file when it starts | Expected; set `generateHosts = false` under `[network]` in `/etc/wsl.conf` to keep your own |
