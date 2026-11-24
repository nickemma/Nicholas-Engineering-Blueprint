# Rust edge proxy self-check

Answer aloud or write the answers before re-opening the lessons.

1. After the client sends FIN, which copy direction should finish? What still has to happen on the other direction before the relay returns?
2. Where does the next hop's authority come from? Which part of the incoming target is preserved? How do the origin counters distinguish a routing error from a local rejection?
3. Why do separate downstream connections make the pooling check stronger? What two counters prove that pooling worked?
4. When does the per-origin permit release? Which status does the client see when the permit is unavailable or when the upstream hits its deadline?
5. What decides whether a request is the recovery probe? Why can an old success be ignored? What does cancellation do to the probe slot?
6. Why does the load generator calculate latency from the scheduled start? Which conclusion becomes weaker if the direct path shows driver-cap drops?
7. What exact observations should change in each negative control? Which errors would tell you the test failed before reaching the invariant?

## From memory

Sketch the path from the downstream socket to the configured origin. Mark the two independent connection lifetimes, the per-origin permit, and the breaker. Then write a timeline in which one origin fails three times, a late completion arrives, a probe fails, and a later probe succeeds. For every request, state whether the upstream sees it and whether its completion changes the breaker phase.
