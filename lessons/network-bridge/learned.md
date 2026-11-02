# Networking Bridge: what I learned

Fill this in as you go, with evidence: commands, outputs and result files saved in your repository.

## Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | Which part of RTT changes with load? | | |
| 1 | What's the bandwidth-delay product of 1 Gbit/s at 200 ms, and what window does it need? | | |
| 1 | From `ss -ti` alone, how can you tell a queue is full? | | |
| 2 | Why did 5 drops cause 46 retransmissions, and why didn't `ethtool` fix it? | | |
| 2 | Derive the Mathis formula. What happens if loss quadruples? If RTT quadruples? | | |
| 2 | Why three duplicate ACKs, and not one? | | |
| 3 | What does each of Reno, CUBIC and BBR treat as its signal? | | |
| 3 | Why did BBR not slow down at 1% loss, and what does it give up? | | |
| 3 | Why didn't ten times the queue give any more throughput? | | |
| 3 | Why does BBR starve CUBIC on a small queue, and lose to it on a large one? | | |
| 4 | Why can't an HTTP/2 server get around TCP's ordering? | | |
| 4 | What did the one-object control show, and why was it needed? | | |
| 4 | Why did six HTTP/1.1 connections win the page test? | | |
| 4 | Why were HTTP/2's tiny requests slow with no loss? What does `tcp_notsent_lowat` change? | | |
| 5 | Why does a new HTTPS connection take four round trips for 20 KB? | | |
| 5 | Why does a proxy help content that can't be cached? | | |
| 5 | What does `tcp_slow_start_after_idle` protect against, and what did it cost? | | |
| 5 | How does a path vector prevent loops? Why would a long-lived connection worry about anycast? | | |
| 6 | Name the four kinds of slow, and how you'd tell them apart | | |
| 6 | Why isn't `app_limited` enough by itself? | | |

## What surprised me

## What I'd do differently
