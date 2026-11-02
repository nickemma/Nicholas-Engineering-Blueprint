# Python Bridge exercise: logstat, a log analyser and health prober

Build this **on your own**, as a new uv project, after the [checkpoint](TEACHING.md#checkpoint). It uses every idea from the bridge on a new problem:
- a package with a CLI;
- dataclasses and exceptions;
- pytest with fixtures and fakes;
- percentiles;
- asyncio with httpx, on an open-loop schedule;
- pandas and a plot.

There's no solution in this repository. This page shows exactly what the finished tool does.

## What you're building

`logstat` reads the JSON request logs your Phase 1 service writes, and answers the questions you'd ask during an incident: which routes are slow, which are failing, and when did it start? It can also **probe** several services' health endpoints on a fixed schedule, and report how available and how fast each one was.

## The finished result

### Commands

| Command | What it does |
|---|---|
| `logstat routes FILE` | One row per route: requests, 4xx count, 5xx count, and p50/p95/p99 of `duration_ms` over all requests to that route. Sorted by request count, highest first, then by route name |
| `logstat timeline FILE --bucket 10s [--plot out.png]` | One row per time bucket, starting from the bucket that holds the first request: requests, 5xx count, p95 `duration_ms`. `--plot` saves a chart of p95 and 5xx over time |
| `logstat probe URL... --interval 1s --duration 30s --out probes.csv` | Probes every URL once per interval, concurrently and on schedule (open loop), with a 2-second timeout per probe. Writes one CSV row per probe, then prints each URL's availability and p95 latency |

### Rules

- Input lines are JSON objects. Only lines with `"msg":"request"` are request records.
- Lines that aren't valid JSON are **skipped and counted**, never fatal. So are records missing a field. Other valid JSON lines (`"msg":"listening"`, for example) are ignored.
- After the output, print one line to **stderr**: `skipped N malformed line(s); ignored M non-request line(s)`.
- Percentiles use the nearest-rank method, exactly as in the bridge. Write your own; don't use pandas' default `quantile`.
- `--bucket` accepts values like `10s`, `1m` and `5m`. Anything else is a usage error with exit status 2.
- A probe "succeeds" if it gets a status from 200 to 399 within the timeout. Availability is successes ÷ probes. The p95 is over successful probes only.
- Probe latency is measured from each probe's **scheduled** time, so a stalled target can't hide behind a stalled prober.
- The HTTP client is injected, so tests use `httpx.MockTransport` and never touch the network.

### Structure

~~~text
pyproject.toml          a [project.scripts] entry: logstat = "logstat.cli:main"
src/logstat/
  records.py            parse lines into Request records; count the skipped and ignored lines
  stats.py              percentiles and per-route and per-bucket summaries
  probe.py              the async open-loop prober
  cli.py                argparse subcommands; main(argv) returns an exit code
tests/                  one test file per module
~~~

## Sample input

Save this as `sample.log`. It's the shape your Phase 1 service writes, plus one line that isn't a request and one broken line:

~~~text
{"time":"2026-10-04T12:00:00Z","level":"INFO","msg":"listening","addr":"127.0.0.1:8080"}
{"time":"2026-10-04T12:00:01Z","level":"INFO","msg":"request","method":"GET","route":"GET /health","status":200,"duration_ms":1}
{"time":"2026-10-04T12:00:02Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs","status":201,"duration_ms":2}
{"time":"2026-10-04T12:00:03Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs","status":201,"duration_ms":3}
{"time":"2026-10-04T12:00:04Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs","status":400,"duration_ms":0}
oops this line is broken
{"time":"2026-10-04T12:00:11Z","level":"INFO","msg":"request","method":"GET","route":"GET /jobs/{id}","status":200,"duration_ms":1}
{"time":"2026-10-04T12:00:12Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/run","status":200,"duration_ms":300}
{"time":"2026-10-04T12:00:13Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/run","status":409,"duration_ms":0}
{"time":"2026-10-04T12:00:21Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/run","status":504,"duration_ms":1005}
{"time":"2026-10-04T12:00:22Z","level":"INFO","msg":"request","method":"GET","route":"GET /jobs/{id}","status":404,"duration_ms":0}
{"time":"2026-10-04T12:00:25Z","level":"INFO","msg":"request","method":"GET","route":"GET /metrics","status":200,"duration_ms":2}
~~~

## Sample session

~~~text
$ logstat routes sample.log
route                 requests  4xx  5xx  p50_ms  p95_ms  p99_ms
POST /jobs                   3    1    0       2       3       3
POST /jobs/{id}/run          3    1    1     300    1005    1005
GET /jobs/{id}               2    1    0       0       1       1
GET /health                  1    0    0       1       1       1
GET /metrics                 1    0    0       2       2       2
skipped 1 malformed line(s); ignored 1 non-request line(s)

$ logstat timeline sample.log --bucket 10s
bucket                 requests  5xx  p95_ms
2026-10-04T12:00:00Z          4    0       3
2026-10-04T12:00:10Z          3    0     300
2026-10-04T12:00:20Z          3    1    1005
skipped 1 malformed line(s); ignored 1 non-request line(s)

$ logstat timeline sample.log --bucket 7x
usage: logstat timeline [-h] [--bucket BUCKET] [--plot PLOT] file
logstat timeline: error: argument --bucket: invalid duration '7x'
~~~

Column spacing may differ, but every number must match. The last line of each successful run goes to stderr.

With your Phase 1 service running and nothing on port 9999:

~~~text
$ logstat probe http://127.0.0.1:8080/health http://127.0.0.1:9999/health --interval 1s --duration 5s --out probes.csv
url                              probes  ok  availability  p95_ms
http://127.0.0.1:8080/health          5   5        100.0%     2.1
http://127.0.0.1:9999/health          5   0          0.0%       -
~~~

Probe latencies vary from machine to machine. The counts and availability must match.

## Acceptance checks

You're done when all of these are true:

1. `routes` and `timeline` print exactly the numbers above for `sample.log`, and a test asserts them.
2. Malformed lines, records with missing fields, and non-request lines each have a test, and none of them crashes the tool.
3. Your percentile function has parametrised tests, including a single value, an empty input (which raises), and p100.
4. The prober's tests use `MockTransport` with one healthy target, one that always errors, and one that **stalls**. They show the stall is recorded in every probe scheduled during it.
5. `probe` writes a CSV with columns `scheduled_s,url,status,latency_ms,error`, plus a `.json` settings file beside it.
6. `timeline --plot` writes a PNG, and a test checks the PNG signature.
7. `ruff format --check`, `ruff check` and `pytest` pass, and CI is green.
8. You've run `logstat routes` on a real log from your Phase 1 service under `kload` load, and written down one thing it revealed.

## Stretch goals

- `logstat routes --since 12:00:10 --until 12:00:20` filters by time.
- `logstat compare before.log after.log` prints each route's p95 change, flagging changes over 20%.
- Read the log from stdin when `FILE` is `-`, so `./api | logstat routes -` works live.

## Hints

- `json.loads` raises `json.JSONDecodeError` (a `ValueError`) on bad input. Catch it, count it, and move on.
- `datetime.fromisoformat` parses the timestamps. Round a time down to a bucket with integer arithmetic on seconds since the epoch.
- An argparse `type=` can be any function that raises `argparse.ArgumentTypeError` for a bad value.
- For the prober, reuse the structure of `run_open_loop`: schedule first, send second, measure from the schedule.
