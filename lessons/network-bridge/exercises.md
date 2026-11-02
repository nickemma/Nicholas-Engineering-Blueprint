# Networking Bridge exercise: fix the queue, and measure a real path

Do this **on your own**, after the [checkpoint](TEACHING.md#checkpoint). The guide told you what to expect at each step. This time, nobody has measured your answer.

There's no solution in this repository, because your numbers are the answer. This page shows exactly what a finished report contains.

## Part 1: fix bufferbloat

Step 3 showed that a queue of 3,450 packets adds about 130 ms for everyone, and said the fix is active queue management. Prove it.

**Requirements.**
1. Put a queueing discipline that manages its queue at the bottleneck: `fq_codel` or `cake` under a rate limiter (`tbf` or `htb`), with the delay still provided by netem. Your new `link` script must take the same arguments as `link.sh`, or a flag to choose.
2. Check your instrument: show that the rate is what you asked for, that the delay is what you asked for, and that drops are counted where you think they are.
3. With CUBIC, measure throughput and ping under load, deep queue against managed queue, with at least five shuffled runs of each.
4. Run a BBR flow against a CUBIC flow on the managed queue, and compare with step 3's fairness table. `fq_codel` gives each flow its own queue, so predict the result first.

## Part 2: measure a real path

Pick a path you can actually use: your laptop to a small cloud server, or between two machines you control.

5. Measure RTT idle and under load, and throughput, with at least five runs at each of two times of day.
6. Work out the bandwidth-delay product, and what the default buffers on each end allow.
7. Compare CUBIC with BBR on that path, if you can load `tcp_bbr` on the sender.
8. Read one transfer with `ss -ti`, and say which of the four kinds of slow applies, or that none does.

Cloud transfer costs money: keep it small, set a budget alert, and delete what you create. Don't load a network you don't own or aren't allowed to test, and never run this against a third party's server.

## Part 3: your own service

9. Take Runway's API and worker from [Phase 5](../05-constrained-operations/README.md). On kind or in Compose, put 40 ms and 1% loss between them, and find out what that does to p99 latency.
10. Find one thing the connection between them could do better (pooling, a number of connections, `tcp_notsent_lowat`, a timeout), change it, and measure the difference.

## What finished looks like

A `REPORT.md` containing:

```text
Part 1: deep queue vs fq_codel, CUBIC, 100 Mbit/s, 40 ms, 5 runs
                  throughput (Mbit/s)     ping under load (ms)
deep queue        <median, interval>      <median, interval>
fq_codel          <median, interval>      <median, interval>

Instrument checks: <the commands, and what each one showed>
Fairness: predicted <...>, measured share <median, interval>

Part 2: <path>, measured <dates and times>
RTT idle <...>, under load <...>; throughput <...>; BDP <...>
Kind of slow: <which, and the ss -ti lines that show it>

Part 3: 40 ms, 1% loss between API and worker
p99 before <...>, after <change> <...>
```

## Done when

- [ ] Every number in the report came from a run saved in your repository, with the command that produced it.
- [ ] Every experiment has at least five shuffled runs and an interval, and you've said how you know the machine wasn't doing something else.
- [ ] You wrote each prediction **before** running the experiment, and say where you were wrong.
- [ ] At least one instrument check found something, or you can say what it would have found.
- [ ] You can explain each result out loud, in terms of a mechanism from the guide.

## Stretch

- Add **ECN** to Part 1: make `fq_codel` mark instead of drop, turn on `net.ipv4.tcp_ecn`, and compare. This is the idea DCTCP builds on.
- Work out why `curl` measured the 87 ms TLS handshake in step 6, with a `tcpdump` capture.
- Extend the anycast simulator with business relationships (customer, peer, provider), and show a site being reached by a longer path.
