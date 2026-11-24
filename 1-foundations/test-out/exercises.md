# Exercises: Test-out

The test-out is one timed task, so it has no exercises of its own to finish. Use this page before your attempt, to warm up, or after one that went badly, to practise the part that cost you time. There's no solution code.

## If a part of the task was slow

| What slowed you down | Practise with |
|---|---|
| Streaming a large input, maps, sorting, exit codes in Go | [`uniqcount`](../03-go-from-zero/exercises.md#exercise-1-uniqcount-a-sort--uniq--c-in-go) |
| Go errors, deadlines and table-driven tests | [`urlcheck`](../03-go-from-zero/exercises.md#exercise-2-urlcheck-many-requests-at-once-with-a-deadline) |
| Standard input and output, exit codes and flags in a script | [`diskwatch`](../02-how-the-machine-works/exercises.md#exercise-1-diskwatch-a-disk-space-alarm) |
| Python files, exceptions, parsing and tests | [`httptime`](../04-python-and-the-internet-from-zero/exercises.md#exercise-2-httptime-an-http-client-from-bare-sockets-in-python) |
| Running another program from Python | Exercise 1, below |

## Exercise 1: `runall`, run a command over many files from Python

1. **What you're building:** a Python script that runs another program once per input file and reports what happened, without ever crashing on the program's failures. It's the part of `report.py` that Foundations doesn't teach: `subprocess`, exit codes, standard error and timeouts.
2. **The finished result:**
   - `uv run runall.py FOLDER -- COMMAND [ARG...]` runs `COMMAND ARG...` once for each file in `FOLDER` ending in `.txt`, in name order, with the file as standard input.
   - For each file it prints one line: the file name, the exit code, and the first line of standard output, or `-` if there was none.
   - A run that takes longer than `--timeout SECONDS` (default 5) is stopped, and its line says `timeout` instead of an exit code.
   - If any run exits with anything but 0 or times out, `runall.py` prints one line on standard error per failure, saying which file and why, and exits 1 at the end. A command that doesn't exist is one line on standard error and exit 2. Never a traceback.
   - It has `pytest` tests that need no real command: they run small Python one-liners through `sys.executable`.
3. **A sample session:**

   ~~~text
   $ mkdir -p in && printf 'b\na\n' > in/one.txt && printf '' > in/two.txt
   $ uv run runall.py in -- sort
   one.txt  0  a
   two.txt  0  -
   $ uv run runall.py in -- sh -c 'exit 3'; echo "exit: $?"
   one.txt  3  -
   two.txt  3  -
   runall: one.txt: exited with 3
   runall: two.txt: exited with 3
   exit: 1
   $ uv run runall.py in --timeout 1 -- sleep 10
   one.txt  timeout  -
   two.txt  timeout  -
   ~~~
4. **Done when:**
   1. The three sessions above print exactly those lines, apart from column widths.
   2. A command that writes a megabyte to standard error doesn't hang the script.
   3. `ruff format --check`, `ruff check` and `pytest` are clean.
5. **Stretch goal:** `--jobs N`, which runs up to N files at once and still prints the lines in name order.
