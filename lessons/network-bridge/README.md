# Networking Bridge: the network under load

**Question:** what does the network itself do when it's busy, lossy or far away, what does that do to your service, and how do you prove which of those you're looking at?

**Time:** about 2 weeks, plus some hours of experiments that run by themselves. **Prerequisites:** [Phase 5](../05-constrained-operations/README.md), Docker, and [Phase 7](../07-utility-evaluation/README.md)'s way of planning an experiment. The [Performance Bridge](../perf-bridge/README.md) pairs well with it.

## Syllabus

You build `netlab`: containers joined by a link you control with `tc netem`, and Go programs to measure across it. Every experiment is planned, repeated, shuffled and reported with a confidence interval.

| Step | Topic | You'll learn |
|---|---|---|
| 1 | A network you can break | RTT and its parts; bandwidth; the bandwidth-delay product; `rate ≤ window / RTT`; reading `ss -ti` |
| 2 | What loss does to TCP | Checking your instrument; GSO; additive increase, multiplicative decrease; deriving and testing the Mathis formula; SACK and fast retransmit in `tcpdump` |
| 3 | Congestion control | Reno, CUBIC and BBR under loss; bufferbloat; buffer sizing; fairness, and when BBR starves CUBIC |
| 4 | Head-of-line blocking | HTTP/1.1, HTTP/2 and HTTP/3 (QUIC); UDP GSO; using a control to test a causal claim; `tcp_notsent_lowat` |
| 5 | CDNs, anycast and BGP | Network namespaces and veth pairs; what proxying and caching each save; `tcp_slow_start_after_idle`; a path-vector simulator of anycast failover |
| 6 | The method | Telling four kinds of slow apart with `ss -ti`; `curl -w` and `nstat`; a checklist for "the network is slow" |

## What you'll be able to do

- Predict a link's throughput from its loss and RTT, and check the prediction.
- Read a live TCP connection, and say whether it's limited by loss, a queue, a buffer or the application.
- Choose a congestion control algorithm, and say who pays for that choice.
- Say what HTTP/3 does and doesn't change, with numbers of your own.
- Say what a CDN saves, part by part, and what you give up for it.
- Explain anycast and BGP, and how each fails.
- Check a measurement tool before you believe it.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md), typing every piece of code yourself.
2. Answer [learned.md](learned.md).
3. Do the exercise, **[fix the queue, and measure a real path](exercises.md)**.
4. Take the [self-test](../../notes/learned/network-bridge.md).

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where | Evidence |
|---|---|---|
| Sockets, TCP/UDP, DNS (row 11) | Steps 1, 2, 4, 6 | The Mathis formula tested over two orders of magnitude; a retransmission read from a capture |
| Caching (row 18) | Step 5 | What a cache hit and a warm proxy each save, measured |
| The network under load (row 41) | Every step | Loss, queues, congestion control, HTTP/3 and CDNs, each measured with a control |

## Patterns introduced

- **Measure the instrument:** count what the tool really did, from a second, independent number.
- **Read the setting back:** a change that didn't apply looks like a change that didn't help.
- **Use a control to test a "because":** remove the supposed cause, and see if the effect goes.
- **Fix the queue first:** much of what gets blamed on protocols is waiting.

## Known limits

An emulated link has random, independent loss and one bottleneck, and the real internet has neither. BBR here is the kernel's built-in version, and the HTTP/3 stack is quic-go; other implementations will differ. The live measurements were captured by hand on one laptop, and steps 3 to 6 ran with its clock about 4–5% fast after a sleep: ratios hold, but absolute milliseconds may be that far off. CI rebuilds the code and runs its tests, but it doesn't rerun the experiments.
