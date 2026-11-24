# Evidence: the test-out

The gate's runs, captured on 2026-11-19 with Go 1.27.4, uv 0.12.7 and Python 3.14.7, from [capture-gate.sh](capture-gate.sh) in the image from [Dockerfile](Dockerfile): a fresh Ubuntu 24.04 with an ordinary user, `ada`, on a 16-CPU x86-64 machine running WSL2.

The gate was checked against a reference solution and against eight broken versions of it, each with one deliberate mistake. The reference solution isn't published: the test-out is a test, and a test with its answer next to it doesn't test anything.

| Run | Broken how | Fails |
|---|---|---|
| `gate-good.txt` | Not broken | Nothing: 19 of 19 pass. It used 27 MiB for the 62 MiB log |
| `gate-slurp.txt` | `tally` reads all of standard input, then splits it into lines | Memory: 258,248 KiB (about 252 MiB), over the 64 MiB limit. The answer was right |
| `gate-shortbuf.txt` | `bufio.Scanner` without a bigger buffer | `token too long` at the 200 KB line, in `tally` and so in `report.py` |
| `gate-rank.txt` | Percentile rank rounded down instead of up | The log with traps, `-path` on both logs, and `report.py`'s table: percentiles off by a few ms |
| `gate-floats.txt` | `status` and `ms` decoded as floats, so the `ms` of `1.5` counts as valid | Two lines too many (the trap appears twice) on the log with traps, with and without `-path`, and the table |
| `gate-extraarg.txt` | Extra arguments ignored | `tally extra-argument` exits 0 instead of 2 |
| `gate-traceback.txt` | No `try`/`except` around running `tally` | `report.py` prints a traceback when `tally` fails; its own test fails too |
| `gate-allfiles.txt` | Every file in the folder, not only `.log` files | The table has a row for `notes.txt`; its own test fails too |
| `gate-realtally.txt` | A test that runs the real `tally` | `pytest`: `FileNotFoundError`, because the gate runs the tests without `tally` built |

## Findings while building it

- Reading all of the input first used about 4 times the log's size (258 MB for 62 MB): the bytes, then the copy as a string, then every line split out of it. Streaming, and keeping only the `ms` numbers for the percentiles, used 27 MB.
- Go's `encoding/json` rejects `1.5`, `200.0` and `true` for an `int` field, and accepts `"STATUS"` for `status` (field names match without regard to case). The gate's traps avoid the second, which the task doesn't define.
