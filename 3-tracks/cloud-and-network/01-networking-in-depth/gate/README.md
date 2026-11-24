# Networking gate

Run from the assembled learner workspace. The portable gate uses Go, Python, and local sockets. It checks the TLS clients, the cache, the route model, and the partial-partition fixture. Two disposable source controls must fail because an origin sees an unexpected request and because a one-way link is treated as symmetric.

~~~bash
module="$BLUEPRINT_ROOT/3-tracks/cloud-and-network/01-networking-in-depth"
bash "$module/gate/run.sh" "$PWD"
~~~

The full live gate uses the Docker tools image. Build it from the learner workspace and choose a fresh evidence directory.

~~~bash
docker build -t switchyard-netlab:lab tools
export NETWORK_EVIDENCE_DIR="$(mktemp -d)"
bash "$module/gate/run.sh" "$PWD" live
~~~

You can set `NETWORK_IMAGE` to an equivalent existing tools image. The live gate runs two disposable containers with external networking disabled. Each creates its own namespaces and veth pairs. The container needs permission to manage those namespaces. BBR is measured when available and otherwise recorded as unavailable.

| Check | Required evidence |
|---|---|
| Calibration and loss | Rate metadata and receiver goodput agree with the programmed bottleneck. Idle RTT reflects the configured delay. Loss trials show qdisc drops and TCP retransmissions. |
| Congestion and queues | Sender output identifies the selected controller. Both concurrent flows make progress. The repeated FIFO and FQ-CoDel trials record loaded RTT and goodput under the same rate. |
| HTTP workloads | Both negotiated protocols return the same content hashes for matched cold and warm trials. Per-object completions are retained for zero and one percent programmed loss. |
| Edge | Direct, proxied, prime, and warm-cache paths agree on content. The origin’s request counter stays fixed for the warm hit. |
| Route and partition | The model switches sites after withdrawal. Directed UDP probes disagree during the live one-way outage, and the bounded job request recovers after healing. |

The live output folders contain the raw per-trial data and `summary.json`. For the captured run, see the [evidence](../evidence/README.md).
