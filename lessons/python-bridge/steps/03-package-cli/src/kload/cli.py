"""The kload command line."""

import argparse
import sys
from pathlib import Path

from kload.stats import summarize


def cmd_summarize(args: argparse.Namespace) -> int:
    text = Path(args.file).read_text()
    values = [float(word) for word in text.split()]
    summary = summarize(values)
    for name in ("count", "mean", "p50", "p95", "p99", "max"):
        print(f"{name:>5}: {getattr(summary, name):g}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="kload", description=__doc__)
    sub = parser.add_subparsers(required=True)

    p = sub.add_parser("summarize", help="summarize numbers from a file")
    p.add_argument("file")
    p.set_defaults(handler=cmd_summarize)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
