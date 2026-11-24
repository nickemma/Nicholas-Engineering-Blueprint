# 04 Train a CPU model and score it

> ML for infrastructure · Week 2

## The problem

A model is only useful if it can beat a simple predictor in the units the system cares about.

## The mental model

~~~text
admission features → saved scaling → linear, ReLU, linear → runtime in ms
train gradient updates ── validation chooses checkpoint ── holdout scores both versions
~~~

## The pattern

Fit feature and target scales on training rows. Begin with a median predictor and a size-only baseline. Train a small PyTorch network with Adam and mean squared error on the scaled training targets. Select the lowest validation MAE checkpoint, convert estimates back to milliseconds, and compare errors on the held-out days. Keep the seed and model feature contract in the artifact. Repeatability applies to this pinned CPU environment. [PyTorch reproducibility](https://docs.pytorch.org/docs/2.15/notes/randomness.html)

## Build it

### Fit and score the baselines and candidate

Keep the feature transform and network reconstruction in the same module as prediction. Save only state tensors and plain metadata.

Create `ml_lab/model.py`.

<!-- file: ml_lab/model.py -->
~~~python
"""Use the same feature projection for offline and online predictions."""

from dataclasses import asdict, dataclass
from statistics import fmean, median, pstdev

import torch
from safetensors.torch import load, save
from torch import nn

from .contract import FEATURE_NAMES, FEATURE_VERSION, POOLS, Event, Features
from .dataset import Split


def configure_cpu() -> None:
    torch.set_num_threads(1)
    torch.use_deterministic_algorithms(True)


@dataclass(frozen=True)
class Scale:
    mean: tuple[float, ...]
    std: tuple[float, ...]
    target_mean: float
    target_std: float

    @classmethod
    def fit(cls, train: list[Event]) -> "Scale":
        columns = tuple(zip(*(row.features().numeric() for row in train), strict=True))
        y = [row.runtime_ms for row in train]
        return cls(
            tuple(fmean(column) for column in columns),
            tuple(max(pstdev(column), 1e-6) for column in columns),
            fmean(y),
            max(pstdev(y), 1.0),
        )

    def transform(self, rows: list[Features]) -> torch.Tensor:
        return torch.tensor([
            [(raw - mean) / sd for raw, mean, sd in zip(row.numeric(), self.mean, self.std, strict=True)]
            for row in rows
        ], dtype=torch.float32)


def network() -> nn.Sequential:
    return nn.Sequential(nn.Linear(len(FEATURE_NAMES), 16), nn.ReLU(), nn.Linear(16, 1))


class Predictor:
    def __init__(self, module: nn.Module, scale: Scale) -> None:
        self.module = module.eval()
        self.scale = scale

    @classmethod
    def from_artifact(cls, meta: dict, weights: bytes) -> "Predictor":
        if meta["feature_version"] != FEATURE_VERSION:
            raise ValueError("incompatible feature version")
        module = network()
        module.load_state_dict(load(weights))
        return cls(module, Scale(**meta["scale"]))

    @torch.inference_mode()
    def predict(self, rows: list[Features]) -> list[float]:
        results = self.module(self.scale.transform(rows)).flatten()
        return (results * self.scale.target_std + self.scale.target_mean).clamp_min(1).tolist()


def mae(errors: list[float]) -> float:
    return fmean(abs(error) for error in errors)


def assess(rows: list[Event], predicted: list[float]) -> dict:
    errors = [actual.runtime_ms - estimate for actual, estimate in zip(rows, predicted, strict=True)]
    return {"mae_ms": mae(errors), "rows": len(rows),
            "pool_mae_ms": {pool: mae([error for row, error in zip(rows, errors, strict=True)
                                       if row.pool == pool]) for pool in POOLS}}


def size_baseline(train: list[Event], heldout: list[Event]) -> dict:
    x = [row.work_units for row in train]
    y = [row.runtime_ms for row in train]
    avg_x, avg_y = fmean(x), fmean(y)
    denom = sum((value - avg_x) ** 2 for value in x)
    slope = sum((a - avg_x) * (b - avg_y) for a, b in zip(x, y, strict=True)) / denom if denom else 0
    return assess(heldout, [max(1, avg_y + slope * (row.work_units - avg_x)) for row in heldout])


def fit(split: Split, kind: str, seed: int = 37) -> tuple[dict, bytes]:
    configure_cpu()
    torch.manual_seed(seed)
    scale = Scale.fit(split.train)
    module = network()
    if kind == "median":
        with torch.no_grad():
            for param in module.parameters():
                param.zero_()
        scale = Scale(scale.mean, scale.std, median(row.runtime_ms for row in split.train), 1.0)
        checkpoint, chosen_epoch = save(module.state_dict()), 0
    elif kind == "candidate":
        train_x = scale.transform([row.features() for row in split.train])
        train_y = torch.tensor([(row.runtime_ms - scale.target_mean) / scale.target_std
                                for row in split.train], dtype=torch.float32)
        val_x = scale.transform([row.features() for row in split.valid])
        val_y = torch.tensor([row.runtime_ms for row in split.valid], dtype=torch.float32)
        optimizer = torch.optim.Adam(module.parameters(), lr=0.015)
        loss = nn.MSELoss()
        best = float("inf")
        for epoch in range(1, 201):
            optimizer.zero_grad()
            cost = loss(module(train_x).flatten(), train_y)
            cost.backward()
            optimizer.step()
            with torch.inference_mode():
                estimates = (module(val_x).flatten() * scale.target_std + scale.target_mean).clamp_min(1)
                val_mae = (estimates - val_y).abs().mean().item()
            if val_mae < best:
                best, chosen_epoch = val_mae, epoch
                checkpoint = save(module.state_dict())
    else:
        raise ValueError("unknown model kind")

    meta = {"kind": kind, "seed": seed, "selected_epoch": chosen_epoch,
            "feature_version": FEATURE_VERSION, "scale": asdict(scale),
            "dataset_id": split.dataset_id,
            "replay_contract": "job-duration-promotion.v1",
            "training_range": [[min(column), max(column)] for column in
                               zip(*(row.features().numeric() for row in split.train), strict=True)]}
    predictor = Predictor.from_artifact(meta, checkpoint)
    meta["validation"] = assess(split.valid, predictor.predict([row.features() for row in split.valid]))
    meta["holdout"] = assess(split.test, predictor.predict([row.features() for row in split.test]))
    meta["size_baseline"] = size_baseline(split.train, split.test)
    return meta, checkpoint
~~~

## Check it

~~~bash
uv run --locked python -c "from pathlib import Path; from ml_lab.dataset import load_split; from ml_lab.model import fit; s=load_split(Path('dataset')); print(fit(s, 'candidate')[0]['holdout'])"
~~~

<!-- run: uv run --locked python -c "from pathlib import Path; from ml_lab.dataset import load_split; from ml_lab.model import fit; s=load_split(Path('dataset')); m,_=fit(s,'candidate'); assert m['holdout']['mae_ms'] < m['size_baseline']['mae_ms']" -->

The reference holdout MAE was 175.07 ms for the median, 67.42 ms for the size baseline, and 8.30 ms for PyTorch. The fixture was generated from a learnable cost function. Use the per-pool errors and a new time window to learn how any alternative behaves.
