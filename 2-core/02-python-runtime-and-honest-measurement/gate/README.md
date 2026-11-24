# Gate: Python runtime and honest measurement

## What it checks

Your folder is `~/blueprint/kload`, the uv project you built in this module, with the `kload` command (`[project.scripts]`), `kload load` and `kload compare`.

The gate runs `kload` against **its own server**, built from [delay-fixture/](delay-fixture/): a small Go program whose every answer takes a known time (`-delay`), which the gate can freeze with `SIGSTOP`, and which logs when each request arrived and when it was answered. A `POST` is numbered by the number at the end of its `Idempotency-Key` (`kload-...-37` is request 37). Because the gate knows the truth, it checks your numbers against it:

1. `ruff format --check`, `ruff check` and `pytest` are clean.
2. **Accurate.** `kload load --method POST --path /work --rate 200 --duration 5` against a 5 ms server exits 0, and:
   - its CSV has the header `request,scheduled_s,sent_s,latency_s,status,error` and requests 0 to 999, each once, all answered with `2xx`;
   - the server saw requests 0 to 999, and the p99 of their arrival times is within 10 ms of `kload`'s schedule (request *i* at *i* / 200 s after request 0);
   - no latency is shorter than the server's own time for that request (it can't be);
   - the p50 latency `kload` recorded is within 3 ms of the server's p50.
3. **Open, not closed.** At 100 requests a second for 5 seconds, the server is frozen for 1 second, 2 seconds after `kload` starts:
   - with `--mode open`, `kload` exits 0, and between 40 and 60 requests took 500 ms or more (about 50 were due in the freeze's first half-second, and each waited at least 500 ms from when it was due);
   - with `--mode closed`, `kload` exits 0, at most 2 requests took 500 ms or more, and its output says it ran a closed loop.
4. **Honest about itself.** At 20,000 requests a second for 2 seconds against a server with no delay, `kload` must exit with status 3 and say why on standard error. Every row of its CSV must have a latency at least as long as its send lag (`sent_s - scheduled_s`), and the server's log must show the requests really did arrive over at least 2.4 seconds.
5. **Compares properly.** The gate writes three folders of five runs each, in `kload`'s CSV format: `a`, then `a2` (the same runs in the opposite order, each 0.01 ms slower: the same server, measured again), and `b` (`a`, 2 ms slower). A few rows are `503`s, which a p99 must ignore. `kload compare` must print a line

   ~~~text
   p99 B - A: +2.00 ms, 95% CI [+1.84, +2.17] ms: B is slower
   ~~~

   with the difference inside its own interval; for `a` and `a2` the interval must include 0 and the verdict start `no difference shown`; for `a` and `b` the difference must be within 0.5 ms of +2.00, the interval above 0, and the verdict `B is slower`.

Every command has a time limit, so a `kload` that hangs fails instead of hanging the gate.

## Run it

~~~bash
bash gate/run.sh ~/blueprint/kload
~~~

It needs Go and uv, and takes about a minute. Close other busy programs first: the gate checks timing, and a busy machine makes `kload` late.

## A pass looks like

~~~text
PASS  ruff format
PASS  ruff check
PASS  pytest
PASS  200 requests a second for 5 s against a 5 ms server: on schedule, and accurate
      arrived on schedule: p99 0.74 ms off, worst 1.32 ms
      p50: kload says 6.84 ms; the server took 5.54 ms
PASS  the server freezes for 1 s: open loop
      52 of 500 requests took 500 ms or more
PASS  the server freezes for 1 s: closed loop
      1 of 500 requests took 500 ms or more
PASS  at 20,000 requests a second, kload says it fell behind and exits 3
      kload fell behind its schedule: send lag p99 2489.7 ms is over --max-lag-ms 10. These latencies include time spent waiting inside kload: don't trust them.
      the server saw 40000 requests spread over 4.50 s, not 2 s
PASS  kload compare: two sets of runs from the same server
      p99 B - A: +0.01 ms, 95% CI [-0.16, +0.18] ms: no difference shown: the interval includes 0
PASS  kload compare: B is 2 ms slower in every run
      p99 B - A: +2.00 ms, 95% CI [+1.84, +2.17] ms: B is slower

gate passed
~~~

## A fail looks like

Each of these is one small change to the finished code (the diffs are in [evidence/gate/broken/](../evidence/gate/broken/)). Only the lines that changed from a pass are shown.

**Latency timed from when a request was sent, not when it was due** (`clock() - sent` in `run_open_loop`). Against a server that keeps up, sending is on time and the two are the same, so accuracy and the freeze pass. The run that falls behind gives it away, and so does the module's own test:

~~~text
FAIL  pytest
      =========================== short test summary info ============================
      FAILED tests/test_load.py::test_a_blocking_send_makes_kload_late_and_the_lag_shows_it
      1 failed, 65 passed in 12.68s
FAIL  at 20,000 requests a second, kload says it fell behind and exits 3
      39499 latencies are shorter than the time the request waited inside kload: request 501 was sent 137.2 ms late but has a latency of 66.0 ms. Time latency from when a request was due, not sent
~~~

That's coordinated omission inside an "open" loop: the time a request spent waiting inside `kload` vanished from its latency.

**No `Idempotency-Key`** (`extra = {}` in `make_send`). Ruff notices the unused variable; the gate's server can't tell which request is which, so it can't check the schedule:

~~~text
FAIL  ruff check
      F841 Local variable `run` is assigned to but never used
        --> src/kload/cli.py:58:5
         |
      56 |     so Switchyard creates one job per request, and a retry wouldn't make two.
      57 |     """
      58 |     run = time.time_ns()
         |     ^^^
      59 |     content = body.encode()
      ...
FAIL  200 requests a second for 5 s against a 5 ms server: on schedule, and accurate
      the server saw 0 numbered requests, want 1000: does a POST carry an Idempotency-Key ending in -N, N being the request number?
~~~

**Never exits 3** (`return 0` at the end of `cmd_load`). `kload` still prints that it fell behind, but a script running it can't tell:

~~~text
FAIL  ruff check
      F841 Local variable `fell_behind` is assigned to but never used
        --> src/kload/cli.py:92:5
         |
      90 |     settings = {k: v for k, v in vars(args).items() if k not in ("handler", "settings")}
      91 |     settings_path = write_results(results, Path(args.out), settings)
      92 |     fell_behind = report_run(results, args, wall, cpu)
         |     ^^^^^^^^^^^
      93 |     print(f"wrote {args.out} and {settings_path}")
      ...
FAIL  pytest
      =========================== short test summary info ============================
      FAILED tests/test_cli.py::test_a_run_that_falls_behind_exits_3 - AssertionErr...
      1 failed, 65 passed in 13.51s
FAIL  at 20,000 requests a second, kload says it fell behind and exits 3
      kload exited with 0, want 3:
            open loop: 40000 requests at 20000/s over 2 s
            answers: 201 x40000
            latency (2xx): p50 1478.11 ms, p99 2222.32 ms, max 2231.05 ms
            kload itself: send lag p99 2195.24 ms, max 2208.71 ms; CPU 4.25 s in 4.25 s (100%)
            wrote /tmp/tmp.pcAnbdEn7x/behind.csv and /tmp/tmp.pcAnbdEn7x/behind.json
            kload used 100% of a CPU: close to its limit, so replies may have waited for it to read them. Lower the rate, or split it across processes.
            kload fell behind its schedule: send lag p99 2195.2 ms is over --max-lag-ms 10. These latencies include time spent waiting inside kload: don't trust them.
~~~

**`time.sleep` in the dispatcher** instead of `await asyncio.sleep`. The dispatcher blocks the event loop while it waits for the next request, so no request runs until all are sent:

~~~text
FAIL  pytest
      =========================== short test summary info ============================
      FAILED tests/test_cli.py::test_load_writes_results_and_settings - assert 3 == 0
      FAILED tests/test_cli.py::test_settings_rerun_the_same_experiment - Assertion...
      FAILED tests/test_load.py::test_open_loop_sends_rate_times_duration_requests_on_schedule
      3 failed, 63 passed in 14.67s
FAIL  200 requests a second for 5 s against a 5 ms server
      kload exited with 3, want 0:
            open loop: 1000 requests at 200/s over 5 s
            answers: 201 x1000
            latency (2xx): p50 2637.20 ms, p99 5050.13 ms, max 5100.18 ms
            kload itself: send lag p99 4951.02 ms, max 4999.38 ms; CPU 0.22 s in 5.17 s (4%)
            wrote /tmp/tmp.Gm0AJKlKxH/accuracy.csv and /tmp/tmp.Gm0AJKlKxH/accuracy.json
            kload fell behind its schedule: send lag p99 4951.0 ms is over --max-lag-ms 10. These latencies include time spent waiting inside kload: don't trust them.
FAIL  the server freezes for 1 s: open loop
      kload exited with 3, want 0:
            open loop: 500 requests at 100/s over 5 s
            answers: 201 x500
            latency (2xx): p50 2605.89 ms, p99 5054.62 ms, max 5104.78 ms
            kload itself: send lag p99 4941.88 ms, max 4990.87 ms; CPU 0.18 s in 5.13 s (3%)
            wrote /tmp/tmp.Gm0AJKlKxH/freeze-open.csv and /tmp/tmp.Gm0AJKlKxH/freeze-open.json
            kload fell behind its schedule: send lag p99 4941.9 ms is over --max-lag-ms 10. These latencies include time spent waiting inside kload: don't trust them.
~~~

**A and B swapped in `compare`** (`bootstrap(b, a)`). The statistics are right and the sign is wrong:

~~~text
FAIL  pytest
      =========================== short test summary info ============================
      FAILED tests/test_cli.py::test_compare_command - AssertionError: assert 'p99 ...
      1 failed, 65 passed in 12.04s
FAIL  kload compare: B is 2 ms slower in every run
      p99 B - A: -2.00 ms, 95% CI [-2.16, -1.83] ms: B is faster
      B is 2 ms slower in every run: want a difference near +2.00, an interval above 0, and the verdict 'B is slower'
~~~

What the other checks usually mean when they fail:

- **Arrivals more than 10 ms off schedule, at 200 a second:** something else is using the CPU, or `kload` starts all its tasks at once instead of when each is due.
- **A latency shorter than the server's time:** the clock started late (after the request was sent, or after the reply's first byte) or the units are wrong (seconds written as milliseconds).
- **Too few slow requests in the freeze, open loop:** `--max-in-flight` too low, or latency timed from sending.
- **Too many slow requests in the closed loop:** the "closed" mode doesn't wait for each reply.
