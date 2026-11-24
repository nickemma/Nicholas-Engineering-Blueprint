# Evidence: How the machine works

Real outputs behind the lessons and the gate, captured on 2026-11-18 and 2026-11-19.

## Lessons

- **`lessons/01*` to `06*`** come from [capture-lessons-01-06.sh](capture-lessons-01-06.sh), run as user `ada` (ID 1000) in a fresh `ubuntu:24.04` container on a 16-CPU x86-64 machine running WSL2, after the Foundations 01 setup, with `LANG=C.UTF-8`. The container ran privileged only so lesson 03 could empty the page cache. `0404-fds` ran inside a pseudo-terminal (`script`), as an interactive shell has one.
- **`lessons/07*`** come from [capture-lesson-07.sh](capture-lesson-07.sh), in a second fresh container, with the exact commands lesson 07 uses (`experiment.sh`).
- Each file holds the command, its output and its exit status. PIDs, times, inode numbers and line counts differ on every run.

Findings while building the module:

- With a writer that pauses between lines (a `sleep`, which starts a separate process each time), copy-then-truncate rarely lost anything: 0–1 lines per 10 rotations. At full speed it lost 152–240 lines in every run (eight runs). The lesson's writer runs at full speed, as a busy server does.
- The first writer recorded its line counter on `SIGTERM`. A signal arriving between counting a line and writing it recorded a line that was never written, so a correct rotator sometimes showed "1 lost". The writer now records only lines it has written (`written`), in the lessons and in the gate.

## Gate

[gate/](gate/) holds four gate runs in a fresh `ubuntu:24.04` with `shellcheck` installed, against:

| File | Scripts | Result |
|---|---|---|
| `gate-good.txt` | The lessons' `monitor.sh` and `rotate.sh` | Pass |
| `gate-naive.txt` | A copy-then-truncate rotator ([broken/rotate-copytruncate.sh](gate/broken/rotate-copytruncate.sh)) | Fails both rotation checks: lines lost, copies uncompressed |
| `gate-memfree.txt` | A monitor counting `MemFree` instead of `MemAvailable` ([broken/monitor-memfree.sh](gate/broken/monitor-memfree.sh)) | Fails the memory check |
| `gate-unquoted.txt` | A rotator with one unquoted variable ([broken/rotate-unquoted.sh](gate/broken/rotate-unquoted.sh)) | Fails `shellcheck` |

The gate also passed 10 runs in a row on the reference scripts, after the writer fix above.
