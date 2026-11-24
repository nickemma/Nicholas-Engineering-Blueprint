# 06 Verify the two crash boundaries

> Event streams · Week 2

## The problem

A correct final count alone can hide an untested fault. Collect process exit codes and Kafka coordinates so you can distinguish a relay republish from a projector reread.

## The mental model

~~~text
event-1 published again  → same event ID, next offset
event-1 fetched again    → same event ID, same offset
~~~

## Build it

Run the [gate](../gate/README.md) against the code you built.

~~~bash
SWITCHYARD_STREAMS_LIVE=1 bash "$blueprint/3-tracks/shared-units/event-streams/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/shared-units/event-streams/gate/run.sh" "$PWD" -->

Compare `job_history` and the outbox after the forced rollback, then compare the Kafka positions from the two relay processes. The projector must apply one effect after it rereads the first offset and handles the duplicate at the next offset. Finally the live and rebuilt models must agree.

## Check it

The reference run recorded these outcomes.

~~~text
relay: resent event-1 in partition 1 at offsets 0 and 1
projector: reread the uncommitted offset and suppressed both duplicates
replay: a fresh group rebuilt {'job-a': 2, 'job-b': 1} from four Kafka records
negative control: the same replay invariant rejected the duplicate count {'job-a': 3, 'job-b': 1}
~~~

## If it goes wrong

| Symptom | Check |
|---|---|
| Kafka connects at first, then times out | Check the advertised listener and its mapped host address. |
| The replacement skips the first offset | Check whether the fault happened before the group offset commit. |
| The rebuilt model counts three updates to job-a | Compare event IDs and verify that each inbox claim gates the count increment. |

The [evidence](../evidence/README.md) records a passing replay and a variant that counts a duplicated event twice.
