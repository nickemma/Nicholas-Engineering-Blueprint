# Exercises: Go from zero

Each exercise is a different project that uses this module's ideas, so you can't just retrace the lessons. There's no solution code.

## Exercise 1: `uniqcount`, a `sort | uniq -c` in Go

1. **What you're building:** a Go version of the pipeline from Foundations 02, `sort | uniq -c | sort -rn`, that streams its input. It exercises maps, sorting, `bufio.Scanner` and exit codes, and you can check it against the shell tools you already trust.
2. **The finished result:**
   - `uniqcount [-n N] [FILE]` reads FILE, or standard input if there's no FILE, and prints each distinct line with how often it appears, most frequent first; equal counts in alphabetical order.
   - Each output line is the count, right-aligned in 7 characters, a space, then the line: the same layout as `uniq -c`.
   - `-n N` prints only the first N lines. A missing file prints an error on standard error and exits 1; a bad flag exits 2.
   - It has table-driven tests for the counting and ordering, and `go test -race` passes.
3. **A sample session:**

   ~~~text
   $ printf 'b\na\nb\nc\nb\na\n' | uniqcount
         3 b
         2 a
         1 c
   $ cut -d: -f7 /etc/passwd | uniqcount -n 1
        16 /usr/sbin/nologin
   $ uniqcount /nope; echo "exit: $?"
   uniqcount: open /nope: no such file or directory
   exit: 1
   ~~~
4. **Done when:**
   1. For any input, `uniqcount` prints exactly what `sort | uniq -c | sort -k1,1nr -k2` prints. Check it on `/etc/passwd`'s shells and on `/usr/share/dict/words` if you have it.
   2. It works on a 1 GB file without its memory growing with the file (it may grow with the number of *distinct* lines).
   3. `gofmt -l`, `go vet` and `go test -race ./...` are clean.
5. **Stretch goal:** `-i`, which ignores case when comparing lines.
6. **Hints:** lessons 04 (maps, sorting keys), 06 (`io.Reader`, so the same function reads a file or standard input), 07 (table-driven tests) and 11 (`bufio.Scanner`).

## Exercise 2: `urlcheck`, many requests at once, with a deadline

1. **What you're building:** a tool that checks a list of URLs concurrently and reports which answered in time. It exercises goroutines, channels, `select`, timeouts and the race detector, on a real network.
2. **The finished result:**
   - `urlcheck [-timeout DURATION] [-parallel N] FILE` reads one URL per line from FILE and fetches each with `net/http`, at most N at once (default 4), each with the timeout (default `2s`).
   - It prints one line per URL, **in the order of the file**: `OK 200 123ms URL`, `FAIL 404 87ms URL`, or `TIMEOUT URL`, then a summary line, `checked 5: 3 ok, 1 failed, 1 timed out`.
   - It exits 0 if every URL was OK, 1 otherwise.
3. **A sample session:**

   ~~~text
   $ cat urls.txt
   https://go.dev/
   https://go.dev/no-such-page
   https://example.com/
   $ urlcheck urls.txt
   OK 200 143ms https://go.dev/
   FAIL 404 98ms https://go.dev/no-such-page
   OK 200 211ms https://example.com/
   checked 3: 2 ok, 1 failed, 0 timed out
   ~~~

   Your times will differ.
4. **Done when:**
   1. Output order always matches the file, however the requests finish.
   2. With `-parallel 1`, it takes about the sum of the times; with `-parallel 10`, about the slowest one. Measure both with `time`.
   3. A URL that never answers (test with `http://10.255.255.1/`) is reported as `TIMEOUT` after the timeout, not after minutes.
   4. `go test -race ./...` passes, including a test that runs the checker against a local `net/http/httptest` server, with no network.
5. **Stretch goal:** stop early on Ctrl+C, printing what was checked so far.
6. **Hints:** lessons 09 (a pool of workers), 10 (`select` with `time.After`, the race detector), and 04 (a slice indexed by line number keeps the order). `http.Client` has a `Timeout` field.
