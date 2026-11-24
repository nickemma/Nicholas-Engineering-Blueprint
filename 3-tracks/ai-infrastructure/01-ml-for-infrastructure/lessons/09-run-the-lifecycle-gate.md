# 09 Run the lifecycle gate

> ML for infrastructure · Week 5

## The problem

A polished model report is easy to reproduce without reproducing the lifecycle that created it. The gate rebuilds the data, uses the real release and serving code, and checks both the reference and the failure paths.

## The mental model

~~~text
clean source export → trained versions → release decision → prediction
           source conflict, weak version, changed weights, or drift
~~~

## Build it

### Prove the boundaries with the reference fixture

Rebuild the pipeline, repeat fixed-seed training, compare the baseline and candidate, inject a feature shift, and confirm the old prediction returns after rollback. The live flag also checks the loopback endpoint.

Create `tests/test_lab.py`.

<!-- file: tests/test_lab.py -->
~~~python
import json
import os
import tempfile
import threading
import unittest
from dataclasses import replace
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pyarrow.parquet as pq

from ml_lab.contract import ContractError
from ml_lab.dataset import SCHEMA, ingest, load_split
from ml_lab.fixture import CANARY, generate
from ml_lab.model import Predictor, fit
from ml_lab.observe import drift, schedule
from ml_lab.registry import PromotionRefused, Registry
from ml_lab.serve import Service, bind


class Lab(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(tmp.cleanup)
        cls.root = Path(tmp.name)
        cls.raw = cls.root / "jobs.jsonl"
        cls.data = cls.root / "dataset"
        generate(cls.raw)
        cls.manifest = ingest(cls.raw, cls.data)
        cls.split = load_split(cls.data)

    def test_pipeline_and_cutoffs(self):
        self.assertEqual(self.manifest["duplicates"], 1)
        self.assertEqual(self.manifest["rejected"], 2)
        self.assertEqual(self.manifest["rows"], 1281)
        self.assertEqual(len(self.manifest["shards"]), 20)
        self.assertEqual((len(self.split.train), len(self.split.valid), len(self.split.test), self.split.late),
                         (640, 256, 384, 1))
        self.assertTrue(any(CANARY.encode() in row for row in self.raw.read_bytes().splitlines()))
        for name in self.manifest["shards"]:
            table = pq.read_table(self.data / name)
            self.assertEqual(table.schema, SCHEMA)
            self.assertFalse(any(CANARY in str(row) for row in table.to_pylist()))
        quarantine = [json.loads(line) for line in
                      (self.data / "quarantine.jsonl").read_text().splitlines()]
        self.assertEqual({record["reason"] for record in quarantine}, {"schema", "invalid_json"})
        self.assertTrue(all(set(record) == {"line", "reason"} for record in quarantine))
        self.assertNotIn(CANARY, (self.data / "quarantine.jsonl").read_text())
        print("pipeline: 20 Parquet shards, 1 duplicate, 2 quarantined, private canary absent", flush=True)
        print("time split: 640 train / 256 validation / 384 holdout; 1 late label excluded", flush=True)

    def test_conflicting_event_cannot_publish_snapshot(self):
        path = self.root / "conflict.jsonl"
        original = self.raw.read_bytes()
        # Take one valid row and keep its ID while changing an allowed feature.
        row = next(json.loads(line) for line in original.splitlines() if b'"work_units":' in line
                   and b'"schema":"switchyard.job.completed.v1"' in line)
        row["work_units"] += 1
        path.write_bytes(original + json.dumps(row).encode() + b"\n")
        destination = self.root / "conflicting-snapshot"
        with self.assertRaisesRegex(ValueError, "conflicting copies"):
            ingest(path, destination)
        self.assertFalse(destination.exists())

    def test_train_serve_promote_and_rollback(self):
        split = self.split
        registry = Registry(self.root / "registry")
        active, reference = fit(split, "median")
        challenger, weights = fit(split, "candidate")
        again, repeated = fit(split, "candidate")
        self.assertEqual(challenger, again)
        self.assertEqual(weights, repeated)
        champion_id = registry.publish(active, reference)
        candidate_id = registry.publish(challenger, weights)
        repeat_id = registry.publish(again, repeated)
        self.assertEqual(candidate_id, repeat_id)
        self.assertNotEqual(champion_id, candidate_id)
        original = registry.bootstrap(champion_id)
        print(f"holdout MAE ms: median={active['holdout']['mae_ms']:.2f}; "
              f"size-only={challenger['size_baseline']['mae_ms']:.2f}; "
              f"PyTorch={challenger['holdout']['mae_ms']:.2f}; "
              f"selected_epoch={challenger['selected_epoch']}", flush=True)

        unfit, unfit_weights = fit(split, "median", seed=11)
        unfit_id = registry.publish(unfit, unfit_weights)
        with self.assertRaisesRegex(PromotionRefused, "MAE did not improve"):
            registry.promote(unfit_id, original["generation"])
        self.assertEqual(registry.state(), original)
        print("negative control: promotion refused the baseline-quality artifact; pointer unchanged", flush=True)

        target = split.test[0]
        body = {"work_units": target.work_units, "queue_depth": target.queue_depth, "pool": target.pool}
        serving = Service(registry)
        first = serving.predict(body)
        self.assertEqual(first["artifact"], champion_id)
        with self.assertRaises(ContractError):
            serving.predict({**body, "runtime_ms": target.runtime_ms})

        current = registry.promote(candidate_id, original["generation"])
        candidate = serving.predict(body)
        self.assertEqual(candidate["artifact"], candidate_id)
        predictor = Predictor.from_artifact(challenger, weights)
        self.assertAlmostEqual(candidate["runtime_ms"], predictor.predict([target.features()])[0], places=5)
        with self.assertRaisesRegex(ValueError, "generation changed"):
            registry.rollback(original["generation"])

        waits = schedule(split.test, predictor)
        self.assertLess(waits["predicted_first"]["mean_wait_ms"], waits["fifo"]["mean_wait_ms"])
        print(f"schedule mean wait ms: FIFO={waits['fifo']['mean_wait_ms']:.1f}; "
              f"predicted-first={waits['predicted_first']['mean_wait_ms']:.1f}; "
              f"p95={waits['fifo']['p95_wait_ms']} → {waits['predicted_first']['p95_wait_ms']}", flush=True)
        stable = drift([row.features() for row in split.test], challenger)
        shifted = drift([replace(row.features(), queue_depth=row.queue_depth + 40) for row in split.test],
                        challenger)
        self.assertFalse(stable["alert"])
        self.assertTrue(shifted["alert"])
        self.assertGreater(shifted["mean_shifts_sd"]["queue_depth"], 1.25)
        print(f"drift: stable={stable['alert']}; shifted={shifted['alert']}; "
              f"shifted outside-range share={shifted['outside_range_rate']:.2f}", flush=True)

        if os.environ.get("SWITCHYARD_ML_LIVE") == "1":
            with bind(registry, 0) as server:
                worker = threading.Thread(target=server.serve_forever, daemon=True)
                worker.start()
                try:
                    url = f"http://127.0.0.1:{server.server_port}/predict"

                    def request(data):
                        with urlopen(Request(url, data=json.dumps(data).encode(), method="POST"), timeout=4) as reply:
                            return json.load(reply)

                    self.assertEqual(request(body), candidate)
                    with self.assertRaises(HTTPError) as failure:
                        request({**body, "runtime_ms": target.runtime_ms})
                    self.assertEqual(failure.exception.code, 400)
                    failure.exception.close()
                    registry.rollback(current["generation"])
                    self.assertEqual(request(body), first)
                    print("loopback API: offline predictions matched; label rejected; rollback restored baseline",
                          flush=True)
                finally:
                    server.shutdown()
                    worker.join(timeout=5)
                    self.assertFalse(worker.is_alive())
        else:
            registry.rollback(current["generation"])

        self.assertEqual(serving.predict(body), first)
        self.assertEqual(registry.state()["generation"], 3)
        artifact_file = registry.objects / candidate_id / "weights.safetensors"
        artifact_file.write_bytes(weights + b"fixture-change")
        with self.assertRaisesRegex(ValueError, "weights digest mismatch"):
            registry.artifact(candidate_id)
        self.assertEqual(registry.state()["active"], champion_id)
        print("registry: fixed-seed repeat matched; rollback restored predictions; changed weights refused", flush=True)


if __name__ == "__main__":
    unittest.main()
~~~

## Check it

~~~bash
SWITCHYARD_ML_LIVE=1 bash "$blueprint/3-tracks/ai-infrastructure/01-ml-for-infrastructure/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/ai-infrastructure/01-ml-for-infrastructure/gate/run.sh" "$PWD" -->

Compare your output with the [evidence](../evidence/README.md). Write a report with the dataset fingerprint, split windows, models and seed, MAE by pool, scheduling metrics, alert results, and limitations. Save the generation before and after each release decision. See the [independent exercise](../exercises.md) for a new problem.

## If it goes wrong

| Symptom | Check |
|---|---|
| A privacy canary appears in curated data | Verify that each dataset row comes from the typed event, and check that quarantine stores reason codes only. |
| The holdout looks much better than expected | Check feature availability and the training, validation, and holdout cutoffs. |
| The challenger is refused | Compare against the stronger baseline and check both worker-pool errors. |
| The served artifact does not change after rollback | Inspect the generation, the alias path, and the last loaded version. |
