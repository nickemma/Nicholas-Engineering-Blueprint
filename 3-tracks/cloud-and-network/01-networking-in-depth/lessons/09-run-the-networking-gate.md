# 09 Run the gate and defend the diagnosis

> Networking in depth · Week 4 · Builds on lesson 08

## The problem

A report that lists only averages cannot show whether the instrument, peer, or path caused the result.

## The mental model

Keep the planned change, observed settings, and raw counters together. For each conclusion, find a client observation and an independent corroborating signal. Keep measurements with different conditions in separate rows.

## The pattern

Use matched controls. The portable gate flips the cache behavior and makes directed reachability symmetric in disposable source copies. The live gate checks the actual instruments and retains paired results without a required HTTP winner.

## Build it

### Step 1 — Validate the live evidence

Compare hashes, verified protocol labels, per-object completion, origin request counts, and partition state. Combine the transport and HTTP reports while preserving individual rows.

<details>
<summary>Hint</summary>

An HTTP status can report an upstream timeout while a UDP probe shows which direction stopped.

</details>

<details>
<summary>Implementation</summary>

Create `experiments/report.py`.

<!-- file: experiments/report.py -->
~~~python
"""Validate the live fixture and retain per-trial numbers."""

import json
from pathlib import Path
import sys

from figures import queues, read, transport


def hashes(page):
    return [obj["SHA256"] for obj in page["Objects"]]


def web(directory):
    experiments = []
    expected = None
    for loss in (0, 1):
        for trial in (1, 2, 3):
            for mode in ("cold", "warm"):
                results = {}
                for protocol, wire in (("h2", "HTTP/2.0"), ("h3", "HTTP/3.0")):
                    page = read(directory / f"loss-{loss}-{trial}-{protocol}-{mode}.json")
                    assert len(page["Objects"]) == 12 and page["FixedSize"] == 4096
                    assert [obj["ID"] for obj in page["Objects"]] == list(range(12))
                    assert all(obj["Protocol"] == wire and obj["CompleteNS"] > 0 for obj in page["Objects"])
                    assert (page["WarmupNS"] > 0) == (mode == "warm")
                    if expected is None:
                        expected = hashes(page)
                    assert hashes(page) == expected
                    results[protocol] = round(page["TotalNS"] / 1e6, 2)
                experiments.append({"loss_pct": loss, "trial": trial, "mode": mode, "total_ms": results})

    edge = {label: read(directory / f"{label}.json") for label in ("direct", "proxy", "cache-prime", "cache-hit")}
    before, after = [int((directory / f"origin-{when}-hit.txt").read_text()) for when in ("before", "after")]
    assert before == after and before > 0, (before, after)
    assert all(hashes(page) == hashes(edge["direct"]) for page in edge.values())
    assert all(obj["Cache"] == "hit" for obj in edge["cache-hit"]["Objects"])

    states = {when: (directory / f"{when}-partition.txt").read_text().strip() for when in ("before", "during", "after")}
    for when, status in (("before", 200), ("during", 502), ("after", 200)):
        assert states[when].startswith(f"status={status} "), states
    assert "received" in (directory / "forward.txt").read_text()
    assert "i/o timeout" in (directory / "reverse.txt").read_text()
    assert "received" in (directory / "healed-reverse.txt").read_text()
    assert read(directory / "partition-qdisc.json")[0]["drops"] > 0

    return {
        "http": experiments,
        "edge": {name: round(page["TotalNS"] / 1e6, 2) for name, page in edge.items()},
        "origin_count": before,
        "partition": states,
    }


def main(folder):
    result = {
        "transport": transport(folder / "transport"),
        "queues": queues(folder / "transport"),
    } | web(folder / "http")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
~~~

</details>

### Step 2 — Run the portable controls

Test the reference and require the two broken variants to fail at their actual invariants.

<details>
<summary>Hint</summary>

A compile error or a port failure is different from detecting the changed semantics.

</details>

### Step 3 — Run and explain the live checks

Build the tools image, pick a fresh evidence directory, and run the live gate. Write one paragraph with a prediction, observation, and limitation.

<details>
<summary>Hint</summary>

Keep BBR availability and run order alongside the numbers.

</details>

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/cloud-and-network/01-networking-in-depth/gate/run.sh" "$PWD" live
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/cloud-and-network/01-networking-in-depth/gate/run.sh" "$PWD" -->

The portable gate caught both negative controls. See the [live and portable evidence](../evidence/README.md) and keep your [gate results](../gate/README.md) for the next module.

## If it goes wrong

If a live assertion fails, inspect the corresponding raw counter before changing the threshold. Use the [gate guide](../gate/README.md) to distinguish kernel availability from a failed experiment.
