# 03 TCP and UDP

> Module: Python and the internet from zero · Time: ~4 h · Builds on: 02

## The problem

Packets get lost, arrive twice, or arrive out of order, and a router doesn't care: it forwards what it can. Yet when you download a file, every byte arrives, in order. Something on the two machines puts the conversation back together. That something is **TCP**, and almost everything you'll build runs on it: HTTP, databases, message queues, the Raft cluster in the core. Its sibling **UDP** does none of that work, and some systems want exactly that. This lesson shows both at the level of single packets, so that `connection refused`, `connection reset` and a timeout each mean something precise to you.

## The mental model

~~~text
 TCP: a connection, then a stream of bytes             UDP: separate datagrams, no connection

 client                         server                 sender                       receiver
   │ ── SYN (let's talk) ────────▶ │                    │ ── datagram "one" ─────────▶ │
   │ ◀──── SYN-ACK (ok, let's) ─── │                    │ ── datagram "two" ───X  (lost: nobody knows)
   │ ── ACK (agreed) ────────────▶ │                    │ ── datagram "three" ───────▶ │
   │                               │
   │ ── bytes 1–6 ───────────────▶ │                    no handshake, no acknowledgements,
   │ ◀──── ACK: got up to 6 ────── │                    no order, no retries;
   │ ── FIN (I'm done sending) ──▶ │                    each datagram arrives whole or not at all
   │ ◀──── FIN ─────────────────── │
~~~

**TCP** gives two programs a **connection**: a reliable, ordered **stream of bytes** in each direction.

- It starts with the **three-way handshake**: `SYN`, `SYN-ACK`, `ACK`. Only then does data flow.
- Every byte has a **sequence number**. The receiver **acknowledges** (`ACK`) what it has received; whatever isn't acknowledged in time is sent again (**retransmission**). The receiver uses the numbers to put bytes back in order and drop duplicates.
- Each side says it has finished sending with `FIN`. A connection that something went badly wrong with is ended at once with `RST` (reset).
- It's a stream, not a sequence of messages. Send "hel" then "lo", and the other side may read "h", then "ello". TCP keeps the bytes and their order, never your message boundaries. Lesson 04 deals with that.

**UDP** sends **datagrams**: single packets, each on its own. No connection, no acknowledgement, no retries, no ordering. A datagram arrives whole or not at all. It's used where speed matters more than every packet (video calls, games) or where the program does its own checking (DNS, from the last lesson, and QUIC, the protocol under HTTP/3).

## The pattern

**Watch the packets.** `tcpdump` shows every packet on an interface. When a connection misbehaves, the packets say whether it was refused, reset, lost or never sent, and that tells you which side to look at.

## Build it

You'll use `nc` (netcat), which opens a TCP or UDP connection and connects it to your terminal, and `tcpdump`. Each step gives the commands as one block you can paste; the outputs were captured in one terminal, with the server running in the background (`&`). You can also run the server in one terminal and the client in another, which shows better what's going on.

### Step 1: A server and a client

`nc -l` **listens**: it waits for a connection on an address and port. A plain `nc` **connects** to one.

~~~bash
nc -l 127.0.0.1 9000 > /tmp/got.txt &
sleep 0.5; ss -tln
printf "hello\n" | nc -N 127.0.0.1 9000
sleep 0.3; cat /tmp/got.txt
~~~

~~~text
State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess
LISTEN 0      1          127.0.0.1:9000      0.0.0.0:*          
hello
~~~

- `ss -tln` lists listening sockets: `-t` TCP, `-l` listening, `-n` numbers instead of names. A **socket** is the operating system's handle for one end of a network conversation; a program reads and writes it like a file. The `LISTEN` line is `nc`, waiting on `127.0.0.1:9000`.
- The client sent `hello`, and the server wrote it to the file. `-N` tells the client to close the connection when its input ends; without it, `nc` keeps the connection open, waiting for more.

**macOS:** `ss` doesn't exist. Use `netstat -an -p tcp | grep LISTEN`, or `lsof -iTCP -sTCP:LISTEN -n -P`.

### Step 2: The handshake, packet by packet

Do it again with `tcpdump` watching the loopback interface (it needs `sudo` to see packets). `-n` shows numbers instead of names, and `"port 9000"` is a filter: only packets to or from port 9000.

~~~bash
sudo tcpdump -i lo -n -l "port 9000" > /tmp/td.txt 2>/dev/null &
sleep 1
nc -l 127.0.0.1 9000 > /dev/null &
sleep 0.3; printf "hello\n" | nc -N 127.0.0.1 9000
sleep 0.5; sudo pkill tcpdump; sleep 0.3; cat /tmp/td.txt
~~~

~~~text
08:57:12.805714 IP 127.0.0.1.41840 > 127.0.0.1.9000: Flags [S], seq 3802138859, win 65495, options [mss 65495,sackOK,TS val 245500218 ecr 0,nop,wscale 10], length 0
08:57:12.805742 IP 127.0.0.1.9000 > 127.0.0.1.41840: Flags [S.], seq 1201692600, ack 3802138860, win 65483, options [mss 65495,sackOK,TS val 350427100 ecr 245500218,nop,wscale 10], length 0
08:57:12.805767 IP 127.0.0.1.41840 > 127.0.0.1.9000: Flags [.], ack 1, win 64, options [nop,nop,TS val 245500218 ecr 350427100], length 0
08:57:12.805910 IP 127.0.0.1.41840 > 127.0.0.1.9000: Flags [P.], seq 1:7, ack 1, win 64, options [nop,nop,TS val 245500218 ecr 350427100], length 6
08:57:12.805922 IP 127.0.0.1.9000 > 127.0.0.1.41840: Flags [.], ack 7, win 64, options [nop,nop,TS val 350427100 ecr 245500218], length 0
08:57:12.805937 IP 127.0.0.1.41840 > 127.0.0.1.9000: Flags [F.], seq 7, ack 1, win 64, options [nop,nop,TS val 245500218 ecr 350427100], length 0
08:57:12.805969 IP 127.0.0.1.9000 > 127.0.0.1.41840: Flags [F.], seq 1, ack 8, win 64, options [nop,nop,TS val 350427100 ecr 245500218], length 0
08:57:12.806084 IP 127.0.0.1.41840 > 127.0.0.1.9000: Flags [.], ack 2, win 64, options [nop,nop,TS val 245500218 ecr 350427100], length 0
~~~

Eight packets. Each line is a time, the source address and port, `>`, the destination, then `Flags` and details. The client's port, `41840`, was picked by the system for this one connection (an **ephemeral port**); the server's is the `9000` it listens on.

| # | Direction | Flags | Means |
|---|---|---|---|
| 1 | client → server | `[S]` SYN, `seq 3802138859` | "Let's talk. My bytes will be numbered from here." The number is random, so a stranger can't guess it |
| 2 | server → client | `[S.]` SYN-ACK | "Agreed; here's my starting number, and I acknowledge yours (`ack 3802138860`)" |
| 3 | client → server | `[.]` ACK | "Acknowledged." The connection is open. Three packets, before any data |
| 4 | client → server | `[P.]` data, `seq 1:7`, `length 6` | `hello\n`: six bytes, numbered 1 to 6. (After the handshake, `tcpdump` shows sequence numbers counted from the start) |
| 5 | server → client | `[.]` `ack 7` | "I have everything up to byte 6; send 7 next." If this hadn't come back in time, packet 4 would have been sent again |
| 6 | client → server | `[F.]` FIN | "I'm done sending" (the input ended, and `-N` closed the connection) |
| 7 | server → client | `[F.]` FIN | "So am I" |
| 8 | client → server | `[.]` ACK | The last acknowledgement. The connection is closed |

`win` is the **window**: how much more data the receiver can take right now. It's how a slow receiver stops a fast sender from flooding it. `mss` is the largest piece of data one packet can carry: 65,495 bytes on the loopback, about 1,460 on a real network.

### Step 3: An open connection

While a connection is open, both ends show up in `ss`:

~~~bash
nc -l 127.0.0.1 9000 > /dev/null &
sleep 0.3; sleep 2 | nc -N 127.0.0.1 9000 &
sleep 0.5; ss -tn state established "( sport = :9000 or dport = :9000 )"; wait
~~~

~~~text
Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
0      0          127.0.0.1:9000     127.0.0.1:41854       
0      0          127.0.0.1:41854    127.0.0.1:9000        
~~~

One connection, two sockets: the server's end (`127.0.0.1:9000`, talking to port `41854`) and the client's end (`41854`, talking to `9000`). A connection is identified by four numbers: both addresses and both ports. That's how one server port can hold thousands of connections at once: each client has a different address or port. `Recv-Q` and `Send-Q` are bytes waiting in the socket's buffers; when they stay above zero, someone isn't reading.

### Step 4: Nobody listening: `connection refused`

Connect to a port where nothing listens:

~~~bash
sudo tcpdump -i lo -n -l "port 9001" > /tmp/td.txt 2>/dev/null &
sleep 1; nc -v 127.0.0.1 9001; echo "exit $?"
sleep 0.3; sudo pkill tcpdump; sleep 0.3; cat /tmp/td.txt
~~~

~~~text
nc: connect to 127.0.0.1 port 9001 (tcp) failed: Connection refused
exit 1
09:04:31.339958 IP 127.0.0.1.45942 > 127.0.0.1.9001: Flags [S], seq 2132470828, win 65495, options [mss 65495,sackOK,TS val 3147945111 ecr 0,nop,wscale 10], length 0
09:04:31.339971 IP 127.0.0.1.9001 > 127.0.0.1.45942: Flags [R.], seq 0, ack 2132470829, win 0, length 0
~~~

The client sent its `SYN`, and the machine answered at once with `[R.]`, a reset: "no one here". That's `connection refused`, and it's good news when you're debugging: the address is right and reachable, the machine is up, and nothing is listening on that port. The fix is on the server side: start the server, or check its port. Compare the lost ping in lesson 01: when packets vanish, you get a **timeout** instead, after however long you were willing to wait.

### Step 5: UDP

`-u` switches `nc` to UDP:

~~~bash
sudo tcpdump -i lo -n -l "udp port 9002" > /tmp/td.txt 2>/dev/null &
sleep 1
nc -u -l 127.0.0.1 9002 > /tmp/u.txt &
sleep 0.3; printf "one datagram\n" | nc -u -w1 127.0.0.1 9002
sleep 0.3; sudo pkill tcpdump; sleep 0.3; cat /tmp/td.txt
echo "--- the listener got:"; cat /tmp/u.txt
~~~

~~~text
08:57:19.560907 IP 127.0.0.1.56727 > 127.0.0.1.9002: UDP, length 13

--- the listener got:
one datagram
~~~

One packet, carrying the data. No handshake before it, no acknowledgement after it, nothing to close. `-w1` makes the client quit after a second, because UDP has no "end of conversation" to wait for.

## Break it

**UDP to nobody.** Send a datagram to a port where nothing listens, and watch for anything coming back. `icmp` adds the network's error messages to the filter:

~~~bash
sudo tcpdump -i lo -n -l "udp port 9003 or icmp" > /tmp/td.txt 2>/dev/null &
sleep 1; printf "anyone there?\n" | nc -u -w1 127.0.0.1 9003; echo "exit $?"
sleep 0.3; sudo pkill tcpdump; sleep 0.3; cat /tmp/td.txt
~~~

~~~text
exit 0
08:57:22.425238 IP 127.0.0.1.34599 > 127.0.0.1.9003: UDP, length 14
08:57:22.425255 IP 127.0.0.1 > 127.0.0.1: ICMP 127.0.0.1 udp port 9003 unreachable, length 50
~~~

`nc` exited with 0: as far as the sender knows, it worked. The machine did send back an ICMP "port unreachable" message, but a UDP sender only sees it if it tries to read a reply, and `nc` didn't. Across a real network, even that message is often blocked or lost. With UDP, silence means nothing, and a program that needs to know its data arrived has to ask for an answer and set a time limit itself. TCP does that for you, for every byte.

## Check it

Without looking back:

1. Start `nc -l 127.0.0.1 9000` in one terminal and `nc 127.0.0.1 9000` in another. Type lines in both directions. Then find the connection in `ss` from a third terminal, and name all four numbers that identify it.
2. Capture the handshake with `tcpdump`, and point to the `SYN`, the `SYN-ACK` and the `ACK`.
3. Produce `connection refused` on purpose, and say what it tells you about the server.

That proves you can open, watch and diagnose a connection with standard tools. It doesn't yet put a program of your own on either end: the next lesson writes the server in Go.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `nc: Address already in use` | Something already listens on that port, maybe an `nc` from an earlier step | `ss -tlnp` shows it; stop it, or use another port |
| `nc: invalid option -- 'N'` | Your `nc` is a different netcat (traditional or nmap's `ncat`) | Install `netcat-openbsd`; on macOS use `nc` without `-N` and press Ctrl+D |
| The client never exits | It's waiting for more input or for the server | Use `-N`, or press Ctrl+D (end of input), then Ctrl+C |
| `tcpdump: lo: You don't have permission` | Watching packets needs administrator rights | Use `sudo` |
| `tcpdump` shows nothing | Wrong interface or filter | Loopback is `lo` on Linux and `lo0` on macOS; check the port in the filter |
| WSL: connecting from Windows to a server in WSL fails | WSL is its own small network | Listen on `0.0.0.0` instead of `127.0.0.1` in WSL, or use WSL's mirrored networking mode |
