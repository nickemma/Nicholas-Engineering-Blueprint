# 09 Run the consensus and recovery gate

> Consensus in depth · Week 4 · Builds on lessons 01–08

## The problem

One test can pass while another guarantee fails. A restart may preserve the current value but lose a retry receipt. A client history may be valid while the election model exposes two winners in the same term. The gate collects evidence for each guarantee.

## The mental model

Track three views of the system. The client records calls and responses, the replicas record terms and committed indexes, and the disk stores a snapshot boundary and suffix. On a timeline, mark the event that makes a write safe to acknowledge. Then mark which evidence would survive a crash at that point.

## Build it

### Step 1 — Predict each boundary

Write down what you expect to see before the snapshot record, after the record with old entries still on disk, and after WAL replacement. For the shard move, identify the last point where the source can acknowledge a write and the first point where the destination can. For a prepared transfer, write the outcome recovery must choose with and without a durable commit record.

### Step 2 — Run the reference and controls

From the assembled learner workspace, run the gate with a fresh evidence directory.

~~~bash
export CONSENSUS_EVIDENCE_DIR="$(mktemp -d)"
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/02-consensus-in-depth/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/02-consensus-in-depth/gate/run.sh" "$PWD" replay -->

The gate must accept the captured single-key client history and reject its stale-read control. The bounded election model must finish with no errors, and the double-vote control must produce two elections in one term. Check that the WAL shrinks in the repeated-write fixture, that both restart paths preserve votes and receipts, and that the range and transfer checks finish at the expected values. [Gate instructions](../gate/README.md) · [Reference evidence](../evidence/README.md)

## Check it

Open the last operation in `history.json` beside the last operation in `stale.json`. Identify the completed write that prevents the stale value from being legal. Open the last state of `tlc-double-vote.txt`. Write the two elected leaders and shared term, then find the earlier state where a peer granted a second vote.

## If it goes wrong

| Symptom | Check |
|---|---|
| The lagging peer misses snapshot installation | Check that it is still behind the leader’s compaction point when you heal its links. |
| The restarted minority peer applies a suffix | Check whether it received a new commit from the majority before the status sample. |
| The source accepts writes after a handoff | Check the replicated range phase before the epoch comparison and mutation. |
| One prepared transaction remains | Compare its GID with the coordinator’s durable decision and verify recovery contacted both participants. |

Continue with the [self-check](../self-check.md) and [exercises](../exercises.md).
