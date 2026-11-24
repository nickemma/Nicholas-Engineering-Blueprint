# 03 Compare B-tree and LSM paths

> Postgres in depth · Week 1

## The problem

The partial index sped up this listing. A different engine can organize the same sorted key space around batches of writes. Trace both read paths before comparing timings or choosing an engine.

## The mental model

~~~text
PostgreSQL B-tree
  root → internal page → ordered leaves → heap checks when needed

LSM
  write-ahead log + memtable → immutable sorted runs → compaction
  read checks the memtable and relevant runs, then resolves versions
~~~

## The pattern

A B-tree maintains ordered pages. Inserts can split a full page, and readers can descend the tree and walk adjacent leaf keys for a range. In this fixture the predicate excludes completed jobs from the index and the first ready keys satisfy the limit. PostgreSQL still manages heap visibility. An LSM buffers writes and flushes sorted files. Reads may need to consult multiple runs, and compaction rewrites data to control overlap and reclaim obsolete versions. Bloom filters can avoid certain negative probes. The workloads and write/read amplification differ with policy and access pattern. [PostgreSQL B-tree implementation](https://www.postgresql.org/docs/17/btree.html) · [RocksDB engine overview](https://github.com/meta/rocksdb/wiki/RocksDB-Overview)

## Build it

Take the same ordered lookup from lesson 02. Sketch its B-tree leaf walk and a merge across three overlapping LSM runs. Put one newer version of a key and one deletion marker in the runs. List the versions each reader might touch before returning its answer.

Then inspect the real plan. Record the index name, index-only node, and heap fetches. Use the [storage engine module](../../03-rust-storage-engine/README.md) for the later implementation of sorted runs and compaction.

## Check it

Explain how two designs can both return ordered keys while exposing different maintenance work. The [reference plan](../evidence/plan-after.json) measures PostgreSQL. The LSM sketch illustrates its lookup and merge path.
