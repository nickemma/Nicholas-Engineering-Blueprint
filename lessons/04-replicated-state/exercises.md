# Phase 4 exercise: chainkv, chain replication

Build this **on your own**, in a new repository, after the [checkpoint](TEACHING.md#checkpoint). It's a different replication protocol from Raft, so you can't follow the guide's code. But it needs every Phase 4 idea:
- a deterministic simulator;
- failure detection, and acting on suspicion safely;
- exactly-once client sessions;
- linearizability checked by Porcupine;
- a deliberate bug that the checker must catch.

There's no solution in this repository. This page shows exactly what the finished system does.

## What you're building

**Chain replication** (van Renesse and Schneider, *Chain Replication for Supporting High Throughput and Availability*, OSDI 2004) arranges the replicas in a line:
- **writes** go to the **head**, which applies them and passes them down the chain, node by node;
- the **tail** answers the client once a write reaches it;
- **reads** go to the **tail**, which only ever holds writes every node has.

That's linearizable without any voting. Failures are handled by a separate **master**, which watches the nodes and rewires the chain:
- if the head fails, the next node becomes the head;
- if the tail fails, the one before it becomes the tail;
- if a middle node fails, its predecessor re-sends everything its successor might have missed.

`chainkv` is a library plus a command:
- `internal/sim`: your deterministic network (start from your Phase 4 `simnet`);
- `internal/chain`: the chain nodes;
- `internal/master`: failure detection and reconfiguration. Assume the master itself never fails; making it fault tolerant is a stretch goal;
- `internal/client`: clients with sessions;
- `cmd/chainkv`: runs a scripted scenario, or a random storm.

## The finished result

### Rules

- Every node keeps a key-value store and a list of **sent** updates: writes it has passed down but that the tail hasn't confirmed yet. Updates are numbered by the head, 1, 2, 3, …
- When the tail applies update *n*, it sends an **ack** for *n* back up the chain. Each node then removes everything up to *n* from its sent list. The tail replies to the client.
- **Reads** are answered by the tail only. Any other node that receives a read refuses it and names the tail.
- **Sessions:** clients number their requests, and a retried write is applied once (the same rule as the guide's `metastore`).
- **The master** pings every node each tick and suspects a node after 10 ticks of silence. On suspecting one, it removes the node from the chain and tells the affected neighbours the new configuration. The configuration has a version number that only goes up, and nodes ignore messages that come from an older configuration.
- **Middle failure:** when node X between P and S is removed, P re-sends to S every update in P's sent list. S ignores updates it has already applied (it checks the number).
- **Adding a node** puts it at the tail. The old tail copies its whole store and its last update number to the new node before the master makes the new node the tail. Until then, the old tail stays the tail.
- Everything runs on simulated time, from one seed.

### `chainkv script FILE`

Runs a scenario with no randomness: every message takes exactly 1 tick, nothing is lost, and the script advances time until each command finishes. Commands:

| Command | Meaning |
|---|---|
| `nodes N` | Start a chain of N nodes, numbered 1 to N in chain order |
| `put KEY VALUE` | A client writes, and waits for the reply |
| `get KEY` | A client reads, and waits for the reply |
| `crash N` | Node N stops. Time passes until the master has rewired the chain |
| `add N` | Add a new node N at the tail, and wait until it *is* the tail |
| `chain` | Print the current chain |

## Sample session

`scenario.txt`:

~~~text
nodes 3
put a 1
put b 2
get a
crash 1
put a 3
get a
crash 3
get b
add 4
put c 4
chain
get c
~~~

~~~text
$ chainkv script scenario.txt
chain: 1 -> 2 -> 3
put a=1: ok (head 1)
put b=2: ok (head 1)
get a: 1 (tail 3)
crash 1
chain: 2 -> 3
put a=3: ok (head 2)
get a: 3 (tail 3)
crash 3
chain: 2
get b: 2 (tail 2)
add 4: copied 2 keys from 2
put c=4: ok (head 2)
chain: 2 -> 4
get c: 4 (tail 4)
~~~

That output is exact: there's no randomness in script mode.

### `chainkv storm -seed N -ticks T`

Runs 5 nodes and 4 clients for `T` ticks, with:
- message delays of 1–5 ticks and 5% message loss;
- a random node crashing every ~300 ticks, as long as at least 2 remain;
- a new node added whenever fewer than 4 remain.

It then checks the clients' history with Porcupine, and prints one line:

~~~text
$ chainkv storm -seed 7 -ticks 20000
seed 7: 4281 operations, 9 crashes, 7 nodes added, linearizable
~~~

Your counts will differ from these: they depend on your code's exact behaviour. The last word must be `linearizable`.

## Acceptance checks

You're done when all of these are true:

1. `chainkv script scenario.txt` prints exactly the sample output above.
2. `chainkv storm` reports `linearizable` for every seed from 1 to 100, with `-ticks 20000`, and each run takes under 10 seconds.
3. The same seed always prints the same line. Show two runs of seed 42.
4. **Every rule is defended by a test that breaks without it.** Make each of these mistakes, one at a time, and show the seed (or scenario) that catches it:
   - the head answers reads;
   - a middle failure doesn't re-send the predecessor's sent list;
   - a new node becomes the tail before its copy finishes;
   - a node accepts messages from an older configuration.
5. A unit test for sessions: a write retried after the tail's reply was lost is applied once.
6. A test in which the tail crashes while updates are in flight down the chain: every write a client got `ok` for is still readable afterwards.
7. Your README explains, with a diagram, why reads at the tail are linearizable, and what would break if reads went to any node.
8. `go vet`, `go test -race ./...` and CI are green.

## Stretch goals

- **A fault-tolerant master.** Run the master's configuration on your own Raft from the guide (or on `metad`), so the master can crash too.
- **CRAQ** (Terrace and Freedman, USENIX ATC 2009): let every node answer reads, and mark keys "dirty" while writes are in flight. Measure read throughput against plain chain replication.
- **Partial partitions.** Make the master reachable from a node that can't reach its neighbours. What does your master do? Write down what goes wrong, and design the fix.

## Hints

- Write the scenario runner first, with `nodes`, `put` and `get` only. Then add failures one kind at a time: head, then tail, then middle.
- Draw the sent lists before and after each kind of failure, on paper, before writing any code for it.
- Keep each node a pure state machine (`Step`, `Tick`, outgoing messages), as in the guide's Raft. The simulator then drives everything, and each seed replays exactly.
- Reuse the guide's Porcupine model for `get` and `put`.
