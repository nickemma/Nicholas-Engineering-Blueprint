"""The kload command line."""

import argparse
import asyncio
import sys
from pathlib import Path

import httpx

from kload.client import ApiError, JobsClient
from kload.load import RequestFn, run_closed_loop, run_open_loop
from kload.results import write_results
from kload.stats import summarize

TARGETS: dict[str, RequestFn] = {
    "health": lambda client: client.get("/health"),
    "create": lambda client: client.post("/jobs", json={"description": "load test"}),
}


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


def cmd_load(args: argparse.Namespace) -> int:
    async def go():
        # Keep every connection open between requests. httpx keeps only 20 idle
        # connections by default, so at high rates it would keep opening new
        # ones, and the generator would measure its own handshakes.
        limits = httpx.Limits(
            max_connections=args.max_in_flight, max_keepalive_connections=args.max_in_flight
        )
        async with httpx.AsyncClient(base_url=args.url, timeout=10, limits=limits) as client:
            if args.mode == "closed":
                count = round(args.rate * args.duration)
                return await run_closed_loop(client, TARGETS[args.target], count)
            return await run_open_loop(
                client,
                TARGETS[args.target],
                rate=args.rate,
                duration_s=args.duration,
                max_in_flight=args.max_in_flight,
            )

    results = asyncio.run(go())
    settings = {k: v for k, v in vars(args).items() if k != "handler"}
    settings_path = write_results(results, Path(args.out), settings)
    print(f"wrote {len(results)} results to {args.out} (settings: {settings_path})")
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

    p = sub.add_parser("load", help="send open-loop load and save raw results")
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--target", choices=sorted(TARGETS), default="health")
    p.add_argument(
        "--mode",
        choices=["open", "closed"],
        default="open",
        help="closed sends rate*duration requests back to back (for comparison only)",
    )
    p.add_argument("--rate", type=float, required=True, help="requests per second")
    p.add_argument("--duration", type=float, required=True, help="seconds")
    p.add_argument("--max-in-flight", type=int, default=200)
    p.add_argument("--out", default="results/run.csv")
    p.set_defaults(handler=cmd_load)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
