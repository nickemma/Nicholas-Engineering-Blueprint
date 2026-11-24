# 04. Capacity planning with headroom

A throughput estimate has a scope. It applies to a particular request mix, resource budget, and latency objective. Measure sustainable throughput with those conditions in place before turning a pilot value into a replica count.

## Start with units

- **Concurrency.** Multiply requests per second by mean seconds in the boundary to estimate mean requests in flight. At 1,500 req/s and 25 ms, the estimate is 37.5. Use the mean for this calculation. Check tail latency separately. [Queueing](../01-queueing/README.md)
- **Headroom and a loss.** If a replica has a tested sustainable ceiling of 1,000 req/s, a 75% planning target gives it 750 req/s. At 1,500 req/s, plan for two serving replicas and deploy three to tolerate one loss at the same target. This assumes even distribution and no shared bottleneck.
- **Bursts.** If arrivals reach 2,100 req/s for two seconds while the fleet serves 1,500 req/s, a fluid model accumulates 1,200 requests. At a lower post-burst rate of 1,200 req/s, the 300 req/s spare capacity drains this backlog in four seconds. A bounded queue can instead refuse arrivals.

These rates are worksheet inputs. The measured example below uses the proxy capstone's recorded load.

## Build the worksheet

Use Python 3.11 or later in a fresh directory. Start the model at the client dispatch boundary, so it covers the same interval in both recordings.

Create `capacity.py`.

<!-- file: capacity.py -->
~~~python
import argparse
import json
from math import ceil
from pathlib import Path
from statistics import mean


def concurrency(requests_per_second: float, mean_seconds: float) -> float:
    """Mean requests in the measured boundary."""
    return requests_per_second * mean_seconds


def replicas(peak_rps: float, sustainable_rps: float, utilization: float, losses: int) -> int:
    if peak_rps <= 0 or sustainable_rps <= 0 or not 0 < utilization <= 1 or losses < 0:
        raise ValueError("invalid capacity assumptions")
    return ceil(peak_rps / (sustainable_rps * utilization)) + losses


def burst_backlog(burst_rps: float, serving_rps: float, seconds: float) -> float:
    return max(0, burst_rps - serving_rps) * seconds


def compare(calibration: dict, validation: dict) -> tuple[float, float]:
    for trial in (calibration, validation):
        if not trial["requests"] or any(row["outcome"] != "ok" for row in trial["requests"]):
            raise ValueError("comparison requires clean trials")
    if calibration["offered_rps"] != validation["offered_rps"]:
        raise ValueError("compare trials at the same offered rate")
    duration_us = mean(
        row["finished_us"] - row["started_us"] for row in calibration["requests"]
    )
    predicted = concurrency(validation["offered_rps"], duration_us / 1_000_000)
    window = validation["window_us"]
    # Add the portion of each request that was in flight within the window.
    area = sum(
        max(0, min(window, row["finished_us"]) - max(0, row["started_us"]))
        for row in validation["requests"]
    )
    return predicted, area / window


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("calibration", type=Path)
    parser.add_argument("validation", type=Path)
    args = parser.parse_args()
    predicted, observed = compare(
        json.loads(args.calibration.read_text()), json.loads(args.validation.read_text())
    )
    print(f"mean in-flight requests: predicted {predicted:.4f}, observed {observed:.4f}")
~~~

Create `test_capacity.py`.

<!-- file: test_capacity.py -->
~~~python
import unittest

from capacity import burst_backlog, compare, concurrency, replicas


class CapacityTest(unittest.TestCase):
    def test_units_and_headroom(self):
        self.assertAlmostEqual(concurrency(1500, 0.025), 37.5)
        self.assertEqual(replicas(1500, 1000, 0.75, 0), 2)
        self.assertEqual(replicas(1500, 1000, 0.75, 1), 3)

    def test_burst(self):
        self.assertEqual(burst_backlog(2100, 1500, 2), 1200)
        self.assertEqual(burst_backlog(1200, 1500, 2), 0)

    def test_observation_clips_the_window(self):
        first = {
            "offered_rps": 2,
            "requests": [{"started_us": 0, "finished_us": 100_000, "outcome": "ok"}],
        }
        second = {
            "offered_rps": 2,
            "window_us": 1_000_000,
            "requests": [{"started_us": 900_000, "finished_us": 1_050_000, "outcome": "ok"}],
        }
        self.assertEqual(compare(first, second), (0.2, 0.1))
~~~

## Check it against a capture

From your worksheet directory, set `BLUEPRINT_ROOT` to the Blueprint checkout. Use the first managed steady trial to estimate mean request time and the second to measure mean occupancy by summing time in flight inside its observation window.

~~~bash
python3 -m unittest -v
captures="$BLUEPRINT_ROOT/3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/evidence/reference/managed"
python3 capacity.py "$captures/Steady-1.json" "$captures/Steady-2.json"
~~~

<!-- run: python3 -m unittest -v && captures="$BLUEPRINT_ROOT/3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/evidence/reference/managed" && python3 capacity.py "$captures/Steady-1.json" "$captures/Steady-2.json" -->

Both trials offered 120 req/s. The worksheet predicted 0.1467 mean in-flight requests and observed 0.1409 in the validation trial. The prediction uses the first trial's latency and the observation uses the second trial's timestamps. A local client, proxy, and origin shared one host. These recordings check the concurrency estimate at this rate. Testing sustainable fleet capacity or surviving a replica loss needs a separate load and failure trial. [Proxy capstone measurements](../../3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/evidence/README.md)

## Practice

Calculate the replica count for a 20% higher demand and a 10% lower per-replica ceiling. Recalculate the drain time if post-burst traffic stays at the original serving rate and explain the result.
