# Consensus and recovery gate

Run from the learner workspace after lesson 09. Use Linux, Go, Rust, Python, Java 21, and Docker with the PostgreSQL 17 image. The full gate creates its own Unix sockets and processes, and creates and removes two isolated PostgreSQL containers.

~~~bash
export CONSENSUS_EVIDENCE_DIR="$(mktemp -d)"
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/02-consensus-in-depth/gate/run.sh" "$PWD"
~~~

Set `TLA2TOOLS_JAR` to an absolute path to the pinned TLC 1.8.0 JAR if you already have a copy. Otherwise the gate downloads and checks it. The `recovery`, `tla`, `range`, and `transfer` modes run individual checks when supplied after the learner directory. The `replay` mode runs the same checks with PostgreSQL enabled through `SWITCHYARD_CONSENSUS_PG_LIVE=1`, as in CI.

| Check | Required result |
|---|---|
| Snapshot and disk | Install on a lagging peer, restore hard state and the snapshot boundary after a restart, and preserve the suffix while reclaiming covered records. |
| Election safeguards | Hold a healthy majority in one term under the seeded partial partition. Step down when quorum contact expires. Detect the term disruption in the run with safeguards disabled. |
| Client history | Accept the real history, including its pending write, and reject the completed stale read. A checker timeout fails the gate. |
| Election model | Exhaust the bounded reference state space, then report the invariant violation in the double-vote configuration. |
| Range movement | Fence the source, recover the image after restarting a peer, and activate the destination with the acknowledged values and original retry receipts. |
| Transfer and saga | Recover both prepared-transaction outcomes, clear every prepared transaction, and apply the repeated compensation once. |

When the evidence directory is set, it contains the client history, its negative control, and both TLC transcripts. The gate prints the main observations to standard output.
