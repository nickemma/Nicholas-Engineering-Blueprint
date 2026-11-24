# Exercises: Python runtime and honest measurement

Each exercise is a **different** project that uses the module's ideas, so you can't just retrace the lessons. No solution code, anywhere.

## Exercise 1: `logstat`, a log analyser and health prober

Build this **on your own**, as a new uv project, after [lesson 07](README.md#lessons). It uses the module's ideas on a new problem:

- a package with a command and subcommands;
- dataclasses and exceptions;
- pytest with fixtures and fakes;
- nearest-rank percentiles;
- `asyncio` on an open-loop schedule;
- pandas and a plot.

### What you're building

`logstat` reads the JSON request logs Switchyard writes (core 01 lesson 11), and answers the questions you'd ask during an incident: which routes are slow, which are failing, and when did it start? It can also **probe** several services' health endpoints on a fixed schedule, and report how available and how fast each one was.

### The finished result

**Commands:**

| Command | What it does |
|---|---|
| `logstat routes FILE` | One row per route: requests, 4xx count, 5xx count, and the p50, p95 and p99 of `duration_ms` over all requests to that route. Sorted by request count, highest first, then by route name |
| `logstat timeline FILE --bucket 10s [--plot out.png]` | One row per time bucket that holds at least one request, in order: requests, 5xx count, p95 `duration_ms`. `--plot` saves a chart of p95 and 5xx over time |
| `logstat probe URL... --interval 1s --duration 30s --out probes.csv` | Probes every URL once per interval, concurrently and on schedule (open loop), with a 2-second timeout per probe. Writes one CSV row per probe, then prints each URL's availability and p95 latency |

**Rules:**

- Input lines are JSON objects. Only lines with `"msg":"request"` are request records.
- Lines that aren't valid JSON are **skipped and counted**, never fatal. So are request records missing a field (`time`, `route`, `status` or `duration_ms`). Other valid JSON lines (`"msg":"listening"`, for example) are ignored, and counted separately.
- After the output, print one line to **standard error**: `skipped N malformed line(s); ignored M non-request line(s)`.
- Percentiles use the nearest-rank method, as in this module. Write your own; don't use pandas' `quantile`, which interpolates.
- `--bucket` accepts values like `10s`, `1m` and `5m`. Anything else is a usage error with exit status 2. Buckets start on whole multiples of their size since the Unix epoch (12:00:00, 12:00:10, ...), in UTC.
- A probe "succeeds" if it gets a status from 200 to 399 within the timeout. Availability is successes ÷ probes. The p95 is over successful probes only, and `-` when there were none.
- Probe latency is measured from each probe's **scheduled** time, so a stalled target can't hide behind a stalled prober.
- The prober's HTTP client is injected, so its tests use `httpx.MockTransport` and never touch the network. (At one probe a second, httpx's cost per request doesn't matter; at `kload`'s rates it did.)

**Structure:**

~~~text
pyproject.toml          a [project.scripts] entry: logstat = "logstat.cli:main"
src/logstat/
  records.py            parse lines into Request records; count the skipped and ignored lines
  stats.py              percentiles, and per-route and per-bucket summaries
  probe.py              the async open-loop prober
  cli.py                argparse subcommands; main(argv) returns an exit status
tests/                  one test file per module
~~~

### A sample session

Save this as `sample.log`. It's the shape Switchyard writes, with one line that isn't a request, one broken line, and one request record missing its `duration_ms`:

~~~text
{"time":"2026-11-20T12:00:00Z","level":"INFO","msg":"listening","addr":"127.0.0.1:8080","grpc_addr":"127.0.0.1:9090","lease_ttl":"3s"}
{"time":"2026-11-20T12:00:01Z","level":"INFO","msg":"request","method":"GET","route":"GET /health","status":200,"duration_ms":1}
{"time":"2026-11-20T12:00:02Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs","status":201,"duration_ms":2}
{"time":"2026-11-20T12:00:03Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs","status":201,"duration_ms":3}
{"time":"2026-11-20T12:00:04Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs","status":400,"duration_ms":0}
this line was cut off by a crash
{"time":"2026-11-20T12:00:11Z","level":"INFO","msg":"request","method":"GET","route":"GET /jobs/{id}","status":200,"duration_ms":1}
{"time":"2026-11-20T12:00:12Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs","status":503,"duration_ms":0}
{"time":"2026-11-20T12:00:13Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/cancel","status":409,"duration_ms":0}
{"time":"2026-11-20T12:00:14Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs","status":201}
{"time":"2026-11-20T12:00:21Z","level":"INFO","msg":"request","method":"POST","route":"POST /jobs/{id}/cancel","status":200,"duration_ms":1}
{"time":"2026-11-20T12:00:22Z","level":"INFO","msg":"request","method":"GET","route":"GET /jobs/{id}","status":404,"duration_ms":0}
{"time":"2026-11-20T12:00:24Z","level":"ERROR","msg":"request","method":"GET","route":"GET /metrics","status":500,"duration_ms":120}
{"time":"2026-11-20T12:00:25Z","level":"INFO","msg":"request","method":"GET","route":"GET /metrics","status":200,"duration_ms":2}
~~~

~~~text
$ logstat routes sample.log
route                      requests  4xx  5xx  p50_ms  p95_ms  p99_ms
POST /jobs                        4    1    1       0       3       3
GET /jobs/{id}                    2    1    0       0       1       1
GET /metrics                      2    0    1       2     120     120
POST /jobs/{id}/cancel            2    1    0       0       1       1
GET /health                       1    0    0       1       1       1
skipped 2 malformed line(s); ignored 1 non-request line(s)

$ logstat timeline sample.log --bucket 10s
bucket                 requests  5xx  p95_ms
2026-11-20T12:00:00Z          4    0       3
2026-11-20T12:00:10Z          3    1       1
2026-11-20T12:00:20Z          4    1     120
skipped 2 malformed line(s); ignored 1 non-request line(s)

$ logstat timeline sample.log --bucket 7x
usage: logstat timeline [-h] [--bucket BUCKET] [--plot PLOT] file
logstat timeline: error: argument --bucket: invalid duration '7x'
~~~

Column spacing may differ, but every number must match. The last line of each successful run goes to standard error.

With Switchyard running and nothing on port 9999:

~~~text
$ logstat probe http://127.0.0.1:8080/health http://127.0.0.1:9999/health --interval 1s --duration 5s --out probes.csv
url                              probes  ok  availability  p95_ms
http://127.0.0.1:8080/health          5   5        100.0%     0.9
http://127.0.0.1:9999/health          5   0          0.0%       -
~~~

Probe latencies vary from machine to machine. The counts and availability must match.

### Done when

1. `routes` and `timeline` print exactly the numbers above for `sample.log`, and a test asserts them.
2. Malformed lines, records with missing fields, and non-request lines each have a test, and none of them crashes the tool.
3. Your percentile function has parametrised tests, including a single value, an empty input (which raises), and p100.
4. The prober's tests use `MockTransport` with one healthy target, one that always errors, and one that **stalls**, and show the stall is recorded in every probe scheduled during it.
5. `probe` writes a CSV with the columns `scheduled_s,url,status,latency_ms,error`, and a `.json` settings file beside it.
6. `timeline --plot` writes a PNG, and a test checks the PNG signature.
7. `ruff format --check`, `ruff check` and `pytest` pass.
8. You've run `logstat routes` on a real Switchyard log taken while `kload` loaded it (lesson 07's saturation experiment is a good one), and written down one thing it showed that `kload`'s own numbers didn't.

### Stretch goals

- `logstat routes --since 12:00:10 --until 12:00:20` filters by time.
- `logstat compare before.log after.log` prints each route's p95 change, using lesson 08's bootstrap over buckets to say whether it's real.
- Read the log from standard input when `FILE` is `-`, so `./bin/switchyard | logstat routes -` works live.

### Hints

- `json.loads` raises `json.JSONDecodeError` (a `ValueError`) on bad input. Catch it, count it, and move on.
- `datetime.fromisoformat` parses the timestamps. Round a time down to a bucket with integer arithmetic on seconds since the epoch.
- An argparse `type=` can be any function that raises `argparse.ArgumentTypeError` for a bad value.
- For the prober, reuse the structure of `run_open_loop`: a dispatcher that starts each probe when it's due, and latency measured from the schedule.
