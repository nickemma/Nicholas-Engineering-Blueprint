"""The kload command line."""

import argparse
import sys
from pathlib import Path

import httpx

from kload.client import ApiError, JobsClient
from kload.stats import summarize


def cmd_summarize(args: argparse.Namespace) -> int:
    text = Path(args.file).read_text()
    values = [float(word) for word in text.split()]
    summary = summarize(values)
    for name in ("count", "mean", "p50", "p95", "p99", "max"):
        print(f"{name:>5}: {getattr(summary, name):g}")
    return 0


def cmd_smoke(args: argparse.Namespace) -> int:
    with httpx.Client(base_url=args.url, timeout=10) as http:
        client = JobsClient(http)
        try:
            print(f"health: {client.health()}")
            job = client.create_job("smoke test", duration_ms=args.duration_ms)
            print(f"created job {job.id}: {job.state}")
            job = client.run_job(job.id)
            print(f"ran job {job.id}: {job.state} {job.failure_reason}".rstrip())
        except (ApiError, httpx.HTTPError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="kload", description=__doc__)
    sub = parser.add_subparsers(required=True)

    p = sub.add_parser("summarize", help="summarize numbers from a file")
    p.add_argument("file")
    p.set_defaults(handler=cmd_summarize)

    p = sub.add_parser("smoke", help="create and run one job against a live API")
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--duration-ms", type=int, default=100)
    p.set_defaults(handler=cmd_smoke)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
