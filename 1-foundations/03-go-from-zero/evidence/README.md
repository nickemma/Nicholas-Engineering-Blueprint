# Evidence: Go from zero

Real outputs behind the lessons and the gate, captured on 2026-11-19 with Go 1.27.4.

## How they were captured

All runs used [Dockerfile](Dockerfile): a fresh Ubuntu 24.04 with the Foundations tools and an ordinary user, `ada`, on a 16-CPU x86-64 machine running WSL2. Each script installs Go 1.27.4 from go.dev, as Foundations 01 does.

- **`lessons/`** comes from [capture-lessons.sh](capture-lessons.sh). It sets up `~/blueprint/gofromzero` with the module's finished code, runs every command the lessons show, and applies each deliberate mistake from [mistakes/](mistakes/) in place, then undoes it. That way, error messages and panics show the learner's own paths and the line numbers of the finished files. `1105-long-ok.txt` was recaptured with [capture-1105.sh](capture-1105.sh), to show the whole output instead of one cut short by `head`.
- Each file holds the command, its output and its exit status. Times, dates, memory addresses, map order and the counts from the racy versions differ on every run.

## Findings while building the module

- **Streaming vs reading the whole file**, on a 65 MB, one-million-line log: about 12 MB of memory against 164–258 MB, on the same answer. The gate's limit, 64 MB, sits between.
- **More workers isn't always faster.** One reader feeds the workers. In the capture image: 1 worker 0.94 s, 2: 0.63 s, 4: 0.55 s, 8: 0.65 s, 16: 0.74 s. An earlier run outside the container, on Go 1.26, showed 3.9 s for 1 worker against 1.5 s for 16: the curve depends on the machine and the Go version, which is why lesson 11 asks the learner to measure.
- **`scanner.Bytes()` handed to workers** gave 341,511–392,529 malformed lines instead of 199, a different number every run, with `go vet` silent. Even with one worker it went wrong (836,209 in one run), because the reader overwrites the buffer while the worker parses it.
- The sample log's line `this line was cut off` is rejected as `invalid character 'h' in literal true`: the parser read the `t` as the start of `true`.

## Gate

[gate/](gate/) holds the gate run against the finished module and five broken versions; [gate/broken/](gate/broken/) has each one as a diff against the finished code.

| Run | Broken how | Fails |
|---|---|---|
| `gate-good.txt` | Not broken | Nothing: 7 of 7 pass |
| `gate-slurp.txt` | Reads the whole log with `io.ReadAll` | Memory: 229,412 KiB (about 224 MiB), over the 64 MiB limit |
| `gate-shortlines.txt` | No `scanner.Buffer`: lines over 64 KiB fail | The small log, at its 100 KB line |
| `gate-tie.txt` | Ties for "slowest" go to whichever line arrives last | The small log, the million-line log, and `go test -race` (the module's own merge test) |
| `gate-exitcode.txt` | `tasks done 9` exits 0 | The `tasks` session |
| `gate-race.txt` | A test that updates a shared variable from four goroutines | `go test -race` |
