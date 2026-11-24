# 05 Promote versioned artifacts

> ML for infrastructure · Week 3

## The problem

Replacing files in place makes it hard to tell which model produced a prediction and what to serve when the change goes wrong.

## The mental model

~~~text
immutable version → manifest + digest-checked weights
                     ↑
         active pointer ── previous pointer
~~~

## The pattern

Register content-addressed artifacts with a data fingerprint, feature version, scales, and evaluation. Keep one alias file with a generation number. Compare reports from the same dataset and contract. Move the pointer only if the declared improvement and pool guardrails pass. A generation check prevents a stale release from silently changing a newer decision.

## Build it

### Publish versions and move the active pointer

Serialize pointer changes under a local file lock and replace the alias atomically. Keep the previous version selectable for rollback.

Create `ml_lab/registry.py`.

<!-- file: ml_lab/registry.py -->
~~~python
"""Track immutable artifacts and an atomic champion pointer."""

import fcntl
import json
import math
import os
import re
import tempfile
from contextlib import contextmanager
from pathlib import Path

from .contract import POOLS
from .dataset import canonical, digest

ID = re.compile(r"[0-9a-f]{64}\Z")
MIN_GAIN = 0.15
POOL_MARGIN_MS = 5.0


class PromotionRefused(ValueError):
    """The challenger failed the declared quality policy."""


def promotion_policy(active: dict, candidate: dict) -> None:
    compare = ("dataset_id", "feature_version", "replay_contract")
    if any(active[key] != candidate[key] for key in compare):
        raise PromotionRefused("comparison requires the same data and contract")
    incumbent, proposal = active["holdout"], candidate["holdout"]
    baseline = min(incumbent["mae_ms"], candidate["size_baseline"]["mae_ms"])
    if baseline <= 0 or proposal["mae_ms"] > baseline * (1 - MIN_GAIN):
        raise PromotionRefused("MAE did not improve on the stronger reference by 15%")
    for pool in POOLS:
        if proposal["pool_mae_ms"][pool] > incumbent["pool_mae_ms"][pool] + POOL_MARGIN_MS:
            raise PromotionRefused("a worker-pool slice regressed")


class Registry:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.objects = root / "objects"
        self.alias = root / "active.json"
        self.objects.mkdir(parents=True, exist_ok=True)

    @contextmanager
    def locked(self):
        with (self.root / ".lock").open("a") as file:
            fcntl.flock(file, fcntl.LOCK_EX)
            yield

    def publish(self, meta: dict, weights: bytes) -> str:
        report = canonical({**meta, "weights_sha256": digest(weights)})
        ident = digest(report)
        destination = self.objects / ident
        with self.locked():
            if destination.exists():
                self.artifact(ident)
                return ident
            with tempfile.TemporaryDirectory(dir=self.objects) as tmp:
                staged = Path(tmp) / "artifact"
                staged.mkdir()
                (staged / "manifest.json").write_bytes(report)
                (staged / "weights.safetensors").write_bytes(weights)
                staged.rename(destination)
        return ident

    def artifact(self, ident: str) -> tuple[dict, bytes]:
        if not ID.fullmatch(ident):
            raise ValueError("invalid artifact ID")
        path = self.objects / ident
        manifest = (path / "manifest.json").read_bytes()
        weights = (path / "weights.safetensors").read_bytes()
        if digest(manifest) != ident:
            raise ValueError("artifact manifest digest mismatch")
        meta = json.loads(manifest)
        if digest(weights) != meta["weights_sha256"]:
            raise ValueError("weights digest mismatch")
        return meta, weights

    def state(self) -> dict:
        try:
            return json.loads(self.alias.read_bytes())
        except FileNotFoundError:
            return {"active": None, "previous": None, "generation": 0}

    def _move(self, state: dict, ident: str) -> dict:
        new = {"active": ident, "previous": state["active"],
               "generation": state["generation"] + 1}
        with tempfile.TemporaryDirectory(dir=self.root) as tmp:
            staged = Path(tmp) / "alias.json"
            with staged.open("wb") as handle:
                handle.write(canonical(new))
                handle.flush()
                os.fsync(handle.fileno())
            staged.replace(self.alias)
        return new

    def bootstrap(self, ident: str) -> dict:
        with self.locked():
            state = self.state()
            if state["active"] is not None:
                raise ValueError("registry already bootstrapped")
            meta, _ = self.artifact(ident)
            if meta["kind"] != "median":
                raise ValueError("bootstrap needs the median baseline")
            return self._move(state, ident)

    def promote(self, ident: str, expected_generation: int) -> dict:
        with self.locked():
            state = self.state()
            if state["active"] is None or state["generation"] != expected_generation:
                raise ValueError("registry generation changed or no active model")
            active, _ = self.artifact(state["active"])
            candidate, _ = self.artifact(ident)
            if not math.isfinite(candidate["holdout"]["mae_ms"]):
                raise PromotionRefused("invalid candidate metric")
            promotion_policy(active, candidate)
            return self._move(state, ident)

    def rollback(self, expected_generation: int) -> dict:
        with self.locked():
            state = self.state()
            previous = state["previous"]
            if previous is None or state["generation"] != expected_generation:
                raise ValueError("registry generation changed or no rollback target")
            self.artifact(previous)
            return self._move(state, previous)
~~~

## Check it

~~~bash
uv run --locked python -c "from tempfile import TemporaryDirectory; from pathlib import Path; from ml_lab.registry import Registry; t=TemporaryDirectory(); print(Registry(Path(t.name)).state())"
~~~

<!-- run: uv run --locked python -c "from tempfile import TemporaryDirectory; from pathlib import Path; from ml_lab.registry import Registry; t=TemporaryDirectory(); assert Registry(Path(t.name)).state()['generation'] == 0" -->

A new registry has generation 0 and no active version. The full gate bootstraps a baseline, refuses a baseline-quality candidate, accepts the trained candidate, and rolls back. These hashes verify content at the local registry boundary. The [model supply-chain lesson](../../02-serving-and-scaling-models/lessons/07-a-supply-chain-for-code-and-weights.md) covers signed release artifacts.
