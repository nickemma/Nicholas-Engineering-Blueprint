# 9. Learned cache admission

**Field:** data systems · ML for systems · **Difficulty:** medium–high

## Problem

Caches in front of databases and in CDNs decide, for every miss, whether to **admit** the new item and which item to **evict**. A few percent of hit rate means fewer database queries and lower latency and cost at scale. Classic policies (LRU, LFU, and TinyLFU-style admission) are cheap but blind to workload patterns. Learned policies can be smarter, but cost CPU and memory on a very hot path.

## Who

Teams running Redis or Memcached tiers, and CDN operators: anyone whose database bill or tail latency depends on cache hit rate.

## Gap

- **TinyLFU** (Einziger, Friedman and Manes, ACM Transactions on Storage, 2017) admits items by estimated frequency, cheaply and effectively.
- Learned approaches such as **LRB** (Song et al., NSDI 2020) approximate the optimal Belady policy with ML and show real gains for CDNs, at a significant compute cost.
- For in-memory key-value caches with **real production traces**, the trade-off between the hit-rate gain and the per-request CPU and memory cost of a *tiny* model is less understood.

## Research question

> On real key-value cache traces, can a very small learned admission model (a few kilobytes, inference under 1 µs) raise hit rate over LRU and TinyLFU by enough to repay its CPU cost? For which workload shapes does it help or hurt?

## Hypothesis and baseline

- **Baselines:** LRU; LRU with TinyLFU admission; the offline optimum (Belady), as a ceiling.
- **Hypothesis:** the learned policy closes part of the gap to Belady on traces with strong recency/frequency mixtures, and gains little on simple ones. A well-designed small model costs less CPU than the database queries it saves.

## System

- **A cache simulator** in Go or Rust that replays traces at full speed, with pluggable admission and eviction policies.
- **Policies:** LRU, TinyLFU (a count-min sketch: ties to the DSA track), and a learned policy (logistic regression or small gradient-boosted trees over features such as recency, frequency, size and inter-arrival time). Training happens online, or on a sliding window.
- **A live experiment:** the best policies placed in front of PostgreSQL in Runway, under replayed load, measuring end-to-end effects.
- **Analysis** in Python.

## Experiment

| Variable | Values |
|---|---|
| Trace | Public production traces, such as Twitter's cache traces (Yang et al., OSDI 2020) |
| Cache size | 0.1%, 1%, 10% of the working set |
| Policy | LRU; TinyLFU; learned; Belady (offline) |
| Model size | Several sizes, for the cost/benefit curve |

## Measures

- Hit rate and byte hit rate.
- CPU nanoseconds per request.
- Memory overhead.
- In the live experiment: database queries saved, and p99 latency.

## What you might find

The learned policy may win clearly on a few trace families and tie or lose on others. The answer may be "use it only when workload features look like X", which is a useful, publishable kind of finding.

## Limitations to expect

- Trace replay ignores feedback effects (users react to latency).
- Online training complicates the cost accounting.
- Results depend on which traces you use.

## Skills used

DSA (hashing, heaps, sketches), Phases 3 (caching, PostgreSQL), 4 (data partitioning), 7 (ML, evaluation) and the Python Bridge (measurement).

## Read first

- Einziger, Friedman and Manes, *TinyLFU: A Highly Efficient Cache Admission Policy*, ACM ToS 2017
- Song et al., *Learning Relaxed Belady for Content Distribution Network Caching*, NSDI 2020
- Yang et al., *A Large Scale Analysis of Hundreds of In-memory Cache Clusters at Twitter*, OSDI 2020
