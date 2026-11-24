# 04 Measure a deep queue under load

> Networking in depth · Week 2 · Builds on lesson 03

## The problem

A transfer can fill the bottleneck while a tiny probe waits behind many data packets. A throughput-only graph can miss the user-visible delay.

## The mental model

Hold the rate and endpoint delays fixed. Run the same flow with a deep FIFO and with FQ-CoDel below the same limiter. Ping first while idle and then during each transfer. Repeat with alternating order.

## The pattern

Bufferbloat is excess queue delay under load. Use the paired probe times to measure it and qdisc counters to confirm the comparison. Keep goodput beside latency so the effect of changing the queue is visible.

## Build it

### Step 1 — Choose the paired measurements

Label the probes by the same transfer and queue that produced them. Check that the loaded probe period overlaps the transfer.

<details>
<summary>Hint</summary>

Measure RTT on the path whose echo replies use the shaped interface.

</details>

### Step 2 — Read every sample

Extract per-packet echo timings and summarize medians across the repeated runs. Validate queue kind and unchanged rate.

<details>
<summary>Hint</summary>

Keep each run’s idle and loaded values and the shaped queue’s own drops.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `experiments/figures.py` in order.

<!-- edit: experiments/figures.py -->
~~~python
    return round(median(samples), 2)


if __name__ == "__main__":
    import sys

    print(json.dumps(transport(Path(sys.argv[1])), indent=2))
~~~

Replace the selected lines with this block.

~~~python
    return round(median(samples), 2)


def queues(directory):
    idle = rtt(directory / "idle-40.txt")
    assert 30 <= idle <= 65, idle
    comparisons = {}
    for mode, kind in [("deep", "pfifo"), ("managed", "fq_codel")]:
        runs = []
        for i in (1, 2, 3):
            key = f"{mode}-{i}"
            counters = read(directory / f"{key}-edge-qdisc.json")
            assert counters[0]["options"]["rate"] == 2_500_000
            queue = next(qdisc for qdisc in counters if qdisc["kind"] == kind)
            runs.append({
                "idle_ms": rtt(directory / f"{key}-idle.txt"),
                "loaded_ms": rtt(directory / f"{key}-loaded.txt"),
                "qdisc_drops": queue["drops"],
            } | flow(directory, key))
        comparisons[mode] = runs
    medians = {mode: median(run["loaded_ms"] for run in runs) for mode, runs in comparisons.items()}
    assert medians["deep"] > medians["managed"], (comparisons, medians)
    return {"calibration_rtt_ms": idle, "measurements": comparisons, "loaded_rtt_median_ms": medians}


if __name__ == "__main__":
    import sys

    folder = Path(sys.argv[1])
    print(json.dumps(transport(folder) | {"queues": queues(folder)}, indent=2))
~~~

</details>

### Step 3 — Defend the result

Compare the two sets of raw samples before reporting the median difference. State which queue and workload produced it.

<details>
<summary>Hint</summary>

A quieter queue can change goodput too. Keep both numbers in the report.

</details>

## Check it

~~~bash
python3 -B experiments/figures.py "$NETWORK_EVIDENCE_DIR/transport"
~~~

<!-- run: python3 -B -c 'import ast; ast.parse(open("experiments/figures.py").read())' -->

The reference compares three FIFO and three FQ-CoDel runs and records the loaded RTT and receiver goodput for each. [Queue results](../evidence/README.md)

## If it goes wrong

If idle RTT differs across queue conditions, check that the previous transfer ended and the qdisc was replaced before starting the next trial.
