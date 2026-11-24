# 08 Operate the local lab

> ML for infrastructure · Week 4

## The problem

Training and deployment should be separate operations with inspectable outputs. You need to choose which version to activate and report what the active version does.

## The mental model

~~~text
fixture → ingest → fit → register → bootstrap or promote → serve and report
                                            ↑                      ↓
                                            └────── rollback ──────┘
~~~

## Build it

### Expose the workflow through the CLI

Use explicit commands for training, alias changes, report generation, and the loopback server.

Create `ml_lab/__main__.py`.

<!-- file: ml_lab/__main__.py -->
~~~python
"""Operate the local model lab from the command line."""

import argparse
import json
from pathlib import Path

from .dataset import ingest, load_split
from .fixture import generate
from .model import Predictor, fit
from .observe import drift, schedule
from .registry import Registry
from .serve import bind


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m ml_lab")
    commands = parser.add_subparsers(dest="command", required=True)
    fixture = commands.add_parser("fixture")
    fixture.add_argument("source", type=Path)
    pipeline = commands.add_parser("ingest")
    pipeline.add_argument("source", type=Path)
    pipeline.add_argument("dataset", type=Path)
    training = commands.add_parser("fit")
    training.add_argument("dataset", type=Path)
    training.add_argument("registry", type=Path)
    training.add_argument("--kind", choices=["median", "candidate"], required=True)
    for name in ("bootstrap", "promote", "rollback", "state", "serve", "report"):
        command = commands.add_parser(name)
        command.add_argument("registry", type=Path)
        if name in ("bootstrap", "promote"):
            command.add_argument("artifact")
        if name in ("promote", "rollback"):
            command.add_argument("--generation", type=int, required=True)
        if name == "serve":
            command.add_argument("--port", type=int, default=8080)
        if name == "report":
            command.add_argument("dataset", type=Path)
    args = parser.parse_args()

    try:
        if args.command == "fixture":
            generate(args.source)
            result = {"source": str(args.source)}
        elif args.command == "ingest":
            result = ingest(args.source, args.dataset)
        elif args.command == "fit":
            split = load_split(args.dataset)
            meta, weights = fit(split, args.kind)
            ident = Registry(args.registry).publish(meta, weights)
            result = {"artifact": ident, "training_rows": len(split.train),
                      "selected_epoch": meta["selected_epoch"], "holdout": meta["holdout"]}
        else:
            registry = Registry(args.registry)
            match args.command:
                case "bootstrap":
                    result = registry.bootstrap(args.artifact)
                case "promote":
                    result = registry.promote(args.artifact, args.generation)
                case "rollback":
                    result = registry.rollback(args.generation)
                case "state":
                    result = registry.state()
                case "serve":
                    with bind(registry, args.port) as http:
                        print(f"listening on {http.server_address[0]}:{http.server_port}", flush=True)
                        http.serve_forever()
                    return
                case "report":
                    split = load_split(args.dataset)
                    ident = registry.state()["active"]
                    if ident is None:
                        raise ValueError("no active artifact")
                    meta, weights = registry.artifact(ident)
                    if meta["dataset_id"] != split.dataset_id:
                        raise ValueError("report requires the registered dataset")
                    predictor = Predictor.from_artifact(meta, weights)
                    result = {"artifact": ident, "schedule": schedule(split.test, predictor),
                              "drift": drift([row.features() for row in split.test], meta)}
    except (ValueError, OSError) as exc:
        parser.exit(1, f"{exc}\n")
    except KeyboardInterrupt:
        return
    print(json.dumps(result, sort_keys=True, allow_nan=False))


if __name__ == "__main__":
    main()
~~~

## Check it

~~~bash
uv run --locked python -m ml_lab --help
~~~

<!-- run: uv run --locked python -m ml_lab --help -->

The commands appear in the help output. The [gate guide](../gate/README.md#run-the-lab-manually) walks through a full version change and rollback.
