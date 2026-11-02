# Estimation

Estimates exist to **change a decision**: one database or many, a cache or not, a queue or not. Do only the ones that do. Round aggressively, say your assumptions out loud, and keep one significant figure.

## Numbers to carry

| Quantity | Value | Round to |
|---|---|---|
| Seconds in a day | 86,400 | 10⁵ |
| Seconds in a year | 31.5 million | 3 × 10⁷ |
| 1 million requests a day | 11.6 a second | ~10/s |
| 1 billion requests a day | 11,600 a second | ~10⁴/s |
| Peak to average | 2–3× for most products; 10× or more for spiky ones | say which |
| 1 KB × 1 billion | 1 TB | |
| 1 Gbit/s | 125 MB/s | |

Powers of two:
- 2¹⁰ ≈ 10³ (kilo);
- 2²⁰ ≈ 10⁶ (mega);
- 2³⁰ ≈ 10⁹ (giga);
- 2⁴⁰ ≈ 10¹² (tera).

## The four estimates that usually matter

1. **Requests per second, average and peak.** Daily users × actions per user ÷ 10⁵, then multiply for the peak.
2. **Read/write ratio.** This decides caching, replicas, and whether writes or reads drive the design.
3. **Storage per year.** Items per day × size × 365, times replication (usually 3). This decides one disk, one machine, or a partitioned store.
4. **Bandwidth.** Requests per second × response size. Big media turns a compute problem into a network problem.

## A worked example

*"A URL shortener with 100 million new links a month, read 100 times as often as written."*

- **Writes:** a month is 30 × 86,400 ≈ 2.6 × 10⁶ seconds, so 10⁸ ÷ 2.6 × 10⁶ ≈ 40/s average; at a 3× peak, ~120/s.
- **Reads:** 100 × 40 = 4,000/s average; ~12,000/s at peak.
- **Storage:** 10⁸ links × 12 months × 500 bytes ≈ 600 GB a year, or 1.8 TB with three copies.
- **Decision:**
  - Writes are tiny, so one primary database copes.
  - Reads are a hundred times larger and highly cacheable, so a cache in front.
  - 600 GB fits on one machine, so no partitioning for the first years.

## How it goes wrong

- **Precision theatre.** "11,574 requests a second" isn't more correct than "about 10⁴".
- **Estimating what doesn't matter.** Nobody needs the bytes of the users table.
- **Forgetting the peak**, and the replication factor.
- **Not measuring your own components.** How many requests a second does *one* of your servers handle? In the Python Bridge you measured it, along with where the latency knee is. Use real numbers when you have them.

## In an interview

Say: *"Let me estimate only what changes the design: peak QPS, the read/write ratio and storage."* Write the arithmetic where they can see it. Then say what it implies: *"Reads dominate by 100×, so I'll put a cache in front and keep one primary."*

## Where you built it

The [Python Bridge](../../lessons/python-bridge/README.md) measured throughput and latency honestly. [Phase 5](../../lessons/05-constrained-operations/README.md) used capacity numbers for SLOs and autoscaling.
