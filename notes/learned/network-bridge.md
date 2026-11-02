# Networking Bridge self-test

Answer from memory, then check yourself against [the lesson](../../lessons/network-bridge/TEACHING.md). Write each "predict" answer before running anything.

## A. The pipe

1. What are the four components of RTT? Which one changes with load?
2. Work out the bandwidth-delay product of 10 Gbit/s at 80 ms, in megabytes.
3. Predict: a 256 KB window at a 100 ms RTT. What's the best possible rate?
4. Why does 100 Mbit/s of link carry about 95 Mbit/s of `iperf3` data?
5. What's slow start, and when does it stop?

## B. Loss

6. Derive the Mathis formula from the sawtooth.
7. Predict: a Reno flow gets 40 Mbit/s at 0.01% loss. What about at 0.04%? What about at 0.01% with twice the RTT?
8. Why does an ACK alone not say what's missing? What does SACK add?
9. What's the difference between fast retransmit and a retransmission timeout?
10. What's GSO, and why did it make netem's loss wrong?
11. What independent number showed that the loss setting wasn't working?

## C. Congestion control

12. Say what Reno, CUBIC and BBR each use as a signal.
13. Why does BBR keep going at 1% random loss? Why's that dangerous on a congested link?
14. What's bufferbloat? Who pays for it?
15. Why is one bandwidth-delay product the classic buffer size for Reno? Why does CUBIC need less?
16. Predict: BBR and CUBIC share a link with a queue of a quarter of a bandwidth-delay product. And with a queue of eight?
17. What does active queue management do, and why isn't "use BBR" a fix for the whole internet?
18. Why do data centres use something like DCTCP?

## D. HTTP and QUIC

19. What did HTTP/2 change from HTTP/1.1? What did HTTP/3 change from HTTP/2?
20. Define head-of-line blocking. Where does it live in HTTP/2?
21. Why does QUIC run on UDP?
22. How many round trips before the first request, for TCP with TLS 1.3 and for QUIC?
23. Someone says "HTTP/3 is faster because it has no head-of-line blocking". What experiment would test the "because"?
24. Why can six HTTP/1.1 connections beat one HTTP/2 connection on a lossy link?
25. What does `tcp_notsent_lowat` do? What problem does it solve?

## E. Edges and routing

26. What does a cache hit save that a proxy doesn't? What does a proxy save that a direct path doesn't?
27. Why does splitting a connection at the edge help at the same loss rate?
28. What must you give a CDN so that it can finish your TLS?
29. What's a network namespace? What's a veth pair?
30. What's anycast? How does traffic move when a site fails?
31. What's an autonomous system? What's a path vector, and how does it prevent loops?
32. Why isn't the shortest AS path always what BGP picks?
33. How can BGP take a service offline by mistake, or on purpose? What does RPKI do about it?

## F. Method

34. Show the four kinds of slow, and the `ss -ti` signature of each.
35. What can `curl -w` tell you in ten seconds?
36. Work through "uploads are slow for one customer" out loud, in order, and say what each step rules out.
37. Why should a run that exactly matches your baseline make you suspicious?
38. An AI assistant gives you a netem script and a clean graph. Name three things you'd check before you believed it.
