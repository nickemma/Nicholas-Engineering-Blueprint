# Core 07 evidence

These are reference captures from Linux with Go 1.26.6, Rust 1.94.1, and Python 3.14.7. The simulation seeds and hash key set are fixed. Test durations and actual election timing in the process runs depend on the host.

| Check | Capture |
|---|---|
| Directed link, seeded replay, heartbeat silence | [01-network](lessons/01-network.txt) |
| Split vote, higher-term election, 100 election seeds | [02-election](lessons/02-election.txt) |
| Repair of a divergent suffix | [03-repair](lessons/03-repair.txt) |
| Figure 8 and the current-term negative control | [04-commit](lessons/04-commit.txt), [04-broken](lessons/04-broken.txt) |
| Save/send ordering and 1,200 simulated restarts | [05-restart](lessons/05-restart.txt) |
| Go ↔ Rust replay, torn tail, complete corruption | [06-wal](lessons/06-wal.txt) |
| Three real peers and a killed leader | [07-smoke](lessons/07-smoke.txt) |
| Native crash-and-partition gate, including early-ack negative control | [08-gate](lessons/08-gate.txt) |
| Fencing, renewal and live lease API | [09-lease](lessons/09-lease.txt), [09-lease-api](lessons/09-lease-api.txt) |
| Consistent-hash movement, balance, hot-key traffic, and tests | [10-ring](lessons/10-ring.txt), [10-ring-tests](lessons/10-ring-tests.txt) |
