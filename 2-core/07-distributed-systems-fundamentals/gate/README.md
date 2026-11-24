# Core 07 gate

Run the gate from your Core 07 scratch directory after [lesson 08](../lessons/08-kill-a-writer-during-a-partition.md). In the setup lesson, you stored the Blueprint checkout path in `$blueprint`.

~~~bash
bash "$blueprint/2-core/07-distributed-systems-fundamentals/gate/run.sh" "$PWD"
~~~

Use Linux with Go, Rust, Python 3.11+, and permission to bind and connect to Unix-domain sockets. The gate starts three Go processes and their Rust writers under temporary directories. Linux assigns each test peer its own process group. The gate sends SIGKILL to the chosen group to stop the node and writer at the same point. The test uses a feature-gated Rust barrier and cleans up its peers and files on exit.

| Check | A passing run shows |
|---|---|
| Completed local write during isolation | The log grows and the isolated client's request finishes with HTTP 504. |
| Interrupted on-disk append | The file contains the original prefix plus a 12-byte header. The writer is killed before the payload, and the client receives no success. |
| Majority progress | The reachable pair elects a higher-term leader and acknowledges a new write during the partition. |
| Recovery and agreement | The restarted peer trims exactly 12 bytes. After healing, all peers agree at every applied index and the history has one winner per term. |
| Client-visible state | Reads through the cluster return both acknowledged values and report the interrupted key absent. |
| Disk integrity | Rust verifies all three logs. Startup refuses a separately corrupted copy and preserves its bytes. |
| Negative control | A disposable build acknowledging before quorum triggers the minority-ack assertion. |

Success exits 0. The last two lines are the expected failed assertion in the altered binary and confirmation that the test caught it. Regular builds omit the Rust fault-injection feature. The run exercises process crashes while the host and its filesystem stay up.

For an ordinary failover without the write barrier, append `smoke` to the command. From [lesson 09](../lessons/09-fence-a-worker-that-outlives-its-lease.md) onward, append `leases` to check the live lease API. [Captured gate output](../evidence/lessons/08-gate.txt)
