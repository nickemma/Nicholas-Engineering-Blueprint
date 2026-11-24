# 11 Streaming a large log

> Module: Go from zero · Time: ~5 h · Builds on: 04, 06, 08, 09, 10

## The problem

A web server writes one line per request. A busy one writes millions a day, and when something breaks, someone has to answer "how many requests failed, and which was slowest?" from that file. Read the whole file into memory first, and a large enough log runs the machine out of memory. Parse it on one CPU, and you wait while the other CPUs do nothing. And some lines will be broken: cut off mid-write, or written by a buggy version. The tool must report those, not crash on them.

This lesson builds `loganalyse`, which reads a log as a stream, line by line, parses lines on several goroutines at once, and counts. You'll measure what streaming saves, find out how much the extra goroutines really help, and meet a concurrency bug that `go vet` can't see.

## The mental model

~~~text
 big.log ──▶ one reader goroutine ──lines──▶ ┌ worker 1: its own Stats ┐
             (bufio.Scanner,         channel  │ worker 2: its own Stats │──▶ merge ──▶ report
              one line at a time)             └ worker N: its own Stats ┘
~~~

- The **reader** holds one line at a time, so memory stays small however big the file is.
- Each **worker** counts into its own `Stats`. Nothing is shared, so there's nothing to lock (lesson 10).
- At the end, the workers' `Stats` are **merged**. The merge must give the same answer whatever order the lines were counted in.

## The pattern

**Stream, fan out, merge.** Read input as a stream; hand pieces to a fixed pool of workers; give each worker private state; combine at the end. It's the shape of most data-processing systems, from `grep` to big-data frameworks.

## Build it

### Step 1: Parsing one line

Each line is a JSON object:

~~~json
{"ts":"2026-11-18T09:00:01Z","status":200,"path":"/health","ms":3}
~~~

A line is **malformed** if it isn't JSON, if `status` or `ms` is missing, if `status` isn't an HTTP status (100–599), or if `ms` is negative. Telling "missing" apart from 0 needs pointers: in a struct with `Status *int`, a missing field stays `nil`, while `"status": 0` gives a pointer to 0. Create `logs/logs.go`:

<!-- file: logs/logs.go -->
~~~go
// Package logs parses JSON log lines and counts what they say.
package logs

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Entry is one request, as one log line records it:
//
//	{"ts":"2026-11-18T09:00:01Z","status":200,"path":"/health","ms":3}
type Entry struct {
	TS     string
	Status int
	Path   string
	MS     int
}

// line is how a log line looks on the wire. Pointers tell "missing" (nil)
// apart from zero.
type line struct {
	TS     string `json:"ts"`
	Status *int   `json:"status"`
	Path   string `json:"path"`
	MS     *int   `json:"ms"`
}

// Parse turns one log line into an Entry, or says why it can't.
func Parse(text string) (Entry, error) {
	var l line
	if err := json.Unmarshal([]byte(text), &l); err != nil {
		return Entry{}, fmt.Errorf("not JSON: %w", err)
	}
	switch {
	case l.Status == nil:
		return Entry{}, errors.New("no status")
	case *l.Status < 100 || *l.Status > 599:
		return Entry{}, fmt.Errorf("status %d is not an HTTP status", *l.Status)
	case l.MS == nil:
		return Entry{}, errors.New("no ms")
	case *l.MS < 0:
		return Entry{}, fmt.Errorf("negative ms %d", *l.MS)
	}
	return Entry{TS: l.TS, Status: *l.Status, Path: l.Path, MS: *l.MS}, nil
}
~~~

- `line` is unexported (lower case): it's a detail of how the file looks, and callers only ever see `Entry`.
- `switch { case ...: }` with nothing after `switch` checks each case's condition in turn, a tidy chain of `if`s.
- `*l.Status` follows the pointer to the number (lesson 05). It's only reached once the case before has ruled out `nil`.

Test every way a line can be bad. Create `logs/logs_test.go`:

<!-- file: logs/logs_test.go -->
~~~go
package logs

import "testing"

func TestParse(t *testing.T) {
	tests := []struct {
		name    string
		text    string
		want    Entry
		wantErr string
	}{
		{"a good line", `{"ts":"t","status":200,"path":"/health","ms":3}`, Entry{TS: "t", Status: 200, Path: "/health", MS: 3}, ""},
		{"zero ms is fine", `{"status":204,"ms":0}`, Entry{Status: 204}, ""},
		{"not JSON", `hello`, Entry{}, "not JSON: invalid character 'h' looking for beginning of value"},
		{"no status", `{"ms":3}`, Entry{}, "no status"},
		{"status out of range", `{"status":42,"ms":3}`, Entry{}, "status 42 is not an HTTP status"},
		{"no ms", `{"status":200}`, Entry{}, "no ms"},
		{"negative ms", `{"status":200,"ms":-1}`, Entry{}, "negative ms -1"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Parse(tt.text)
			if tt.wantErr != "" {
				if err == nil || err.Error() != tt.wantErr {
					t.Fatalf("err = %v, want %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Errorf("Parse = %+v, want %+v", got, tt.want)
			}
		})
	}
}
~~~

<!-- run: gofmt -l logs | (! grep .) && go vet ./logs && go test -count=1 ./logs -->

The backquoted strings, `` `{"ts":...}` ``, are **raw strings**: everything between the backquotes is taken literally, so the JSON's double quotes need no escaping. `err.Error()` is an error's message, as a string.

### Step 2: Counting, so that order doesn't matter

`Stats` adds up what the lines say: how many lines, how many per status, the slowest request, and the malformed lines with their reasons. Several workers will each fill their own `Stats`, then they're merged.

**Starter.** Append to `logs/logs.go`: a `Bad` type (line number and reason), a `Stats` type, `NewStats()`, `Add(n int, text string)` and `Merge(other *Stats)`. The slowest request is the one with the most `ms`; **on a tie, the earliest line wins**. That rule matters: with several workers, lines arrive in an unpredictable order, and "the first one I happened to see" would change from run to run.

<details>
<summary>Hint</summary>

Keep the slowest `Entry` and its line number, with line number 0 meaning "none yet". A helper, `consider(e Entry, n int)`, replaces the slowest if `e` is slower, or equally slow and on an earlier line. Use it in both `Add` and `Merge`. A `map[int]int` counts statuses; `Merge` adds the other's counts into this one's.

</details>

<details>
<summary>The answer</summary>

<!-- append: logs/logs.go -->
~~~go
// Bad is a line that couldn't be parsed.
type Bad struct {
	Line   int
	Reason string
}

// Stats is what a set of log lines adds up to.
type Stats struct {
	Lines       int
	ByStatus    map[int]int
	Slowest     Entry
	SlowestLine int // 0 until a line has been counted
	Malformed   []Bad
}

// NewStats returns empty Stats, ready to count.
func NewStats() *Stats {
	return &Stats{ByStatus: make(map[int]int)}
}

// Add counts line number n, whose text is text.
func (s *Stats) Add(n int, text string) {
	s.Lines++
	e, err := Parse(text)
	if err != nil {
		s.Malformed = append(s.Malformed, Bad{Line: n, Reason: err.Error()})
		return
	}
	s.ByStatus[e.Status]++
	s.consider(e, n)
}

// consider keeps the slowest entry; on a tie, the earliest line wins, so the
// answer doesn't depend on the order lines were counted in.
func (s *Stats) consider(e Entry, n int) {
	if s.SlowestLine == 0 || e.MS > s.Slowest.MS || (e.MS == s.Slowest.MS && n < s.SlowestLine) {
		s.Slowest, s.SlowestLine = e, n
	}
}

// Merge adds other's counts into s.
func (s *Stats) Merge(other *Stats) {
	s.Lines += other.Lines
	for status, count := range other.ByStatus {
		s.ByStatus[status] += count
	}
	if other.SlowestLine != 0 {
		s.consider(other.Slowest, other.SlowestLine)
	}
	s.Malformed = append(s.Malformed, other.Malformed...)
}
~~~

`append(s.Malformed, other.Malformed...)` appends every element of the other slice; the `...` spreads it out.

</details>

The test that matters: counting lines in one pass, and counting them split between two `Stats` in a scrambled order then merging, must agree, including which line is slowest when two lines tie:

<!-- append: logs/logs_test.go -->
~~~go
func TestMergeGivesTheSameAnswerInAnyOrder(t *testing.T) {
	lines := []string{
		`{"status":200,"ms":5}`,
		`{"status":500,"ms":9}`,
		`oops`,
		`{"status":200,"ms":9}`,
	}
	one := NewStats()
	for i, l := range lines {
		one.Add(i+1, l)
	}
	a, b := NewStats(), NewStats()
	b.Add(4, lines[3])
	b.Add(3, lines[2])
	a.Add(2, lines[1])
	a.Add(1, lines[0])
	b.Merge(a)
	if b.Lines != one.Lines || b.ByStatus[200] != 2 || b.ByStatus[500] != 1 || len(b.Malformed) != 1 {
		t.Errorf("merged = %+v, want %+v", b, one)
	}
	if b.SlowestLine != 2 || one.SlowestLine != 2 {
		t.Errorf("slowest line: merged %d, one pass %d, want 2 (the earliest of the 9 ms lines)", b.SlowestLine, one.SlowestLine)
	}
}
~~~

<!-- run: gofmt -l logs | (! grep .) && go vet ./logs && go test -race -count=1 ./logs -->

~~~bash
go test -v ./logs
~~~

~~~text
=== RUN   TestParse
=== RUN   TestParse/a_good_line
=== RUN   TestParse/zero_ms_is_fine
=== RUN   TestParse/not_JSON
=== RUN   TestParse/no_status
=== RUN   TestParse/status_out_of_range
=== RUN   TestParse/no_ms
=== RUN   TestParse/negative_ms
--- PASS: TestParse (0.00s)
    --- PASS: TestParse/a_good_line (0.00s)
    --- PASS: TestParse/zero_ms_is_fine (0.00s)
    --- PASS: TestParse/not_JSON (0.00s)
    --- PASS: TestParse/no_status (0.00s)
    --- PASS: TestParse/status_out_of_range (0.00s)
    --- PASS: TestParse/no_ms (0.00s)
    --- PASS: TestParse/negative_ms (0.00s)
=== RUN   TestMergeGivesTheSameAnswerInAnyOrder
--- PASS: TestMergeGivesTheSameAnswerInAnyOrder (0.00s)
PASS
ok  	gofromzero/logs	0.004s
~~~

### Step 3: The command: stream, fan out, merge

Create `cmd/loganalyse/main.go`. Read it top to bottom; every piece is something you've built before.

<!-- file: cmd/loganalyse/main.go -->
~~~go
// Command loganalyse reads a log of JSON lines and reports what it holds.
//
//	loganalyse [-workers N] FILE
package main

import (
	"bufio"
	"flag"
	"fmt"
	"maps"
	"os"
	"runtime"
	"slices"
	"sync"

	"gofromzero/logs"
)

// numbered is one line of the file, with its line number.
type numbered struct {
	n    int
	text string
}

func main() {
	workers := flag.Int("workers", runtime.NumCPU(), "how many goroutines parse lines")
	flag.Parse()
	if flag.NArg() != 1 || *workers < 1 {
		fmt.Fprintln(os.Stderr, "usage: loganalyse [-workers N] FILE")
		os.Exit(2)
	}
	stats, err := analyse(flag.Arg(0), *workers)
	if err != nil {
		fmt.Fprintln(os.Stderr, "loganalyse:", err)
		os.Exit(1)
	}
	report(stats)
}

// analyse streams the file through a pool of workers. Each worker keeps its own
// Stats, so they never share memory; the results are merged at the end.
func analyse(path string, workers int) (*logs.Stats, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	lines := make(chan numbered, 1024)
	results := make([]*logs.Stats, workers)
	var wg sync.WaitGroup
	for w := range workers {
		results[w] = logs.NewStats()
		wg.Add(1)
		go func(s *logs.Stats) {
			defer wg.Done()
			for l := range lines {
				s.Add(l.n, l.text)
			}
		}(results[w])
	}

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024) // allow lines up to 1 MiB
	n := 0
	for scanner.Scan() {
		n++
		lines <- numbered{n, scanner.Text()} // Text copies the line; the scanner reuses its buffer
	}
	close(lines)
	wg.Wait()
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("line %d: %w", n+1, err)
	}

	total := logs.NewStats()
	for _, s := range results {
		total.Merge(s)
	}
	return total, nil
}

func report(s *logs.Stats) {
	fmt.Printf("lines: %d\n", s.Lines)
	fmt.Printf("malformed: %d\n", len(s.Malformed))
	for _, status := range slices.Sorted(maps.Keys(s.ByStatus)) {
		fmt.Printf("status %d: %d\n", status, s.ByStatus[status])
	}
	if s.SlowestLine != 0 {
		fmt.Printf("slowest: %d ms %s (line %d)\n", s.Slowest.MS, s.Slowest.Path, s.SlowestLine)
	}
	if len(s.Malformed) > 0 {
		slices.SortFunc(s.Malformed, func(a, b logs.Bad) int { return a.Line - b.Line })
		fmt.Println("malformed lines:")
		for _, b := range s.Malformed[:min(10, len(s.Malformed))] {
			fmt.Printf("  line %d: %s\n", b.Line, b.Reason)
		}
		if extra := len(s.Malformed) - 10; extra > 0 {
			fmt.Printf("  ... and %d more\n", extra)
		}
	}
}
~~~

- **Flags.** `flag.Int` defines `-workers`, defaulting to one worker per CPU (`runtime.NumCPU()`, as on Day 1). Step 5 tests whether that default is right.
- **The pool.** `analyse` starts the workers first. Each gets its own `*logs.Stats`, passed in as the goroutine's argument, and loops over the `lines` channel until it's closed (lesson 09).
- **The reader.** `bufio.Scanner` reads the file line by line, from any `io.Reader` (lesson 06). Its default limit is 64 KiB per line; `scanner.Buffer` raises it to 1 MiB. The channel has a buffer of 1,024 lines, so the reader can run a little ahead of the workers.
- **The end.** `close(lines)` ends the workers' loops; `wg.Wait()` waits for them; only then are the results merged, by one goroutine, so `Merge` needs no lock. `defer f.Close()` closes the file however `analyse` returns.
- **The report.** Statuses come from a map, so their keys are sorted (lesson 04); malformed lines arrive in whatever order the workers finished, so they're sorted by line number too.

Try it on a small log with two broken lines. Create `sample.log`:

<!-- file: sample.log -->
~~~text
{"ts":"2026-11-18T09:00:01Z","status":200,"path":"/health","ms":3}
{"ts":"2026-11-18T09:00:02Z","status":200,"path":"/jobs","ms":41}
{"ts":"2026-11-18T09:00:02Z","status":404,"path":"/jobz","ms":2}
this line was cut off
{"ts":"2026-11-18T09:00:03Z","status":500,"path":"/jobs","ms":1207}
{"ts":"2026-11-18T09:00:04Z","status":200,"path":"/health"}
{"ts":"2026-11-18T09:00:05Z","status":200,"path":"/jobs","ms":38}
~~~

~~~bash
go run ./cmd/loganalyse sample.log
~~~

<!-- run: gofmt -l . | (! grep .) && go vet ./... && [ "$(go run ./cmd/loganalyse sample.log | sed -n 6p)" = "slowest: 1207 ms /jobs (line 5)" ] && [ "$(go run ./cmd/loganalyse -workers 1 sample.log)" = "$(go run ./cmd/loganalyse -workers 7 sample.log)" ] -->

~~~text
lines: 7
malformed: 2
status 200: 3
status 404: 1
status 500: 1
slowest: 1207 ms /jobs (line 5)
malformed lines:
  line 4: not JSON: invalid character 'h' in literal true (expecting 'r')
  line 6: no ms
~~~

Look at the reason for line 4. The JSON parser saw a `t` and expected the word `true`, the only JSON value starting with `t`; then it found `h`. Error messages describe what the parser expected, not what you meant, so read them that way.

### Step 4: A million lines, and what streaming saves

To see what streaming buys, you need a big log. This `awk` program writes one with known contents: every 9,973rd line isn't JSON, every 10,007th has no `ms`, and statuses and times follow simple rules. Create `gen.awk`:

<!-- file: gen.awk -->
~~~text
# Writes N log lines with known contents. Every 9973rd line is not JSON, every
# 10007th has no ms; status is 500 every 50th line, else 404 every 7th, else 200;
# ms = (i * 37) % 997.
BEGIN {
  for (i = 1; i <= n; i++) {
    if (i % 9973 == 0) { print "oops, not json"; continue }
    s = (i % 50 == 0) ? 500 : (i % 7 == 0) ? 404 : 200
    if (i % 10007 == 0) { printf "{\"ts\":\"2026-11-18T09:00:00Z\",\"status\":%d,\"path\":\"/p%d\"}\n", s, i % 13; continue }
    printf "{\"ts\":\"2026-11-18T09:00:00Z\",\"status\":%d,\"path\":\"/p%d\",\"ms\":%d}\n", s, i % 13, (i * 37) % 997
  }
}
~~~

~~~bash
awk -v n=1000000 -f gen.awk > big.log && ls -l big.log && wc -l < big.log && head -2 big.log
~~~

<!-- run: awk -v n=1000000 -f gen.awk > big.log && [ "$(wc -l < big.log)" -eq 1000000 ] -->

~~~text
-rw-rw-r-- 1 ada ada 65114546 Nov 19 07:28 big.log
1000000
{"ts":"2026-11-18T09:00:00Z","status":200,"path":"/p1","ms":37}
{"ts":"2026-11-18T09:00:00Z","status":200,"path":"/p2","ms":74}
~~~

A 65 MB log. Build the analyser and run it under GNU `time`, which reports the most memory a program used at once, its **maximum resident set size**. On Ubuntu, install it first with `sudo apt install -y time`; macOS has it already, but use `/usr/bin/time -l` and read "maximum resident set size", in bytes.

~~~bash
go build -o loganalyse ./cmd/loganalyse && /usr/bin/time -f "%M KB max, %e s" ./loganalyse big.log
~~~

<!-- run: go build -o loganalyse ./cmd/loganalyse && ./loganalyse big.log | sed -n 2p | grep -qx 'malformed: 199' -->

~~~text
lines: 1000000
malformed: 199
status 200: 839832
status 404: 139972
status 500: 19997
slowest: 996 ms /p4 (line 485)
malformed lines:
  line 9973: not JSON: invalid character 'o' looking for beginning of value
  line 10007: no ms
  line 19946: not JSON: invalid character 'o' looking for beginning of value
  line 20014: no ms
  line 29919: not JSON: invalid character 'o' looking for beginning of value
  line 30021: no ms
  line 39892: not JSON: invalid character 'o' looking for beginning of value
  line 40028: no ms
  line 49865: not JSON: invalid character 'o' looking for beginning of value
  line 50035: no ms
  ... and 189 more
11820 KB max, 0.67 s
~~~

The counts are exactly what the rules predict: 100 non-JSON lines plus 99 without `ms` is 199. And the memory: **about 12 MB to read a 65 MB file**, because only a little of it is ever held at once.

For comparison, here's the obvious way, which reads the whole file into memory and splits it. You don't need to keep it, but if you'd like to measure it yourself, put it in `cmd/slurp/main.go`, build it the same way, then delete it:

~~~go
package main

import (
	"fmt"
	"os"
	"strings"

	"gofromzero/logs"
)

// The wrong way: read the whole file into memory, then split it.
func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	s := logs.NewStats()
	for i, l := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		s.Add(i+1, l)
	}
	fmt.Printf("lines: %d\nmalformed: %d\n", s.Lines, len(s.Malformed))
}
~~~

~~~text
lines: 1000000
malformed: 199
258492 KB max, 1.12 s
~~~

The same answer, using **20 times the memory**: the file's bytes, a second copy made by `string(data)`, and a million-entry slice of lines. It also grows with the file: a 10 GB log would need tens of gigabytes. (The exact figure varies between runs; it was 164 MB in another run, never anywhere near 12.) The gate checks that your analyser stays under 64 MB on this log, a limit that only a streaming design can meet.

### Step 5: Do more workers help?

The default is one worker per CPU: 16 on the machine these outputs come from. Measure instead of assuming. Run each setting three times:

~~~bash
for w in 1 2 4 8 16; do for k in 1 2 3; do /usr/bin/time -f "workers $w: %e s" ./loganalyse -workers $w big.log >/dev/null; done; done
~~~

~~~text
workers 1: 0.93 s
workers 1: 0.95 s
workers 1: 0.94 s
workers 2: 0.63 s
workers 2: 0.63 s
workers 2: 0.64 s
workers 4: 0.54 s
workers 4: 0.56 s
workers 4: 0.56 s
workers 8: 0.63 s
workers 8: 0.66 s
workers 8: 0.66 s
workers 16: 0.71 s
workers 16: 0.77 s
workers 16: 0.73 s
~~~

Two workers helped a lot, four a little more, and then it got *slower*. There's only one reader, and once it's the slowest part, extra workers just wait on the channel, and the goroutines competing for it cost time. The default, 16, was slower than 4 on this machine. Yours will differ, which is the point: the right number depends on the work and the machine, and you find it by measuring. Core 06 shows how to see where the time goes with a profiler.

Delete the big file and the binary: `rm big.log loganalyse`.

<!-- run: rm -f big.log loganalyse -->

## Break it

**A line longer than the scanner allows.** Real logs sometimes have a huge line: a request with an enormous URL. Make a log whose first line is 100,000 characters, then remove the `scanner.Buffer(...)` line from `analyse`:

~~~bash
long=$(awk 'BEGIN { for (i = 0; i < 100000; i++) printf "x" }')
echo "{\"ts\":\"t\",\"status\":200,\"path\":\"/$long\",\"ms\":1}" > long.log && cat sample.log >> long.log
go run ./cmd/loganalyse long.log
~~~

~~~text
loganalyse: line 1: bufio.Scanner: token too long
exit status 1
~~~

The scanner refuses lines over 64 KiB by default, rather than letting one line use unlimited memory, and stops. Without the check of `scanner.Err()` after the loop, the program would have reported zero lines and called it a success. Put the line back, and the long line is read:

~~~bash
go run ./cmd/loganalyse long.log | cut -c1-60
~~~

~~~text
lines: 8
malformed: 2
status 200: 4
status 404: 1
status 500: 1
slowest: 1207 ms /jobs (line 6)
malformed lines:
  line 5: not JSON: invalid character 'h' in literal true (e
~~~

(`cut -c1-60` shortens each line to 60 characters, to keep the huge path off your screen.)

**Sharing the scanner's buffer.** `scanner.Text()` copies the line into a new string. `scanner.Bytes()` gives you the line *without* copying it, which sounds faster. Make that change: give `numbered` a field `bytes []byte` instead of `text string`, send `numbered{n, scanner.Bytes()}`, and have the worker call `s.Add(l.n, string(l.bytes))`. Then run it twice:

~~~bash
go build -o lb ./cmd/loganalyse && ./lb big.log | head -6 && ./lb big.log | head -2 && go vet ./... && echo "go vet: no complaints"
~~~

~~~text
lines: 1000000
malformed: 341511
status 200: 553165
status 404: 92169
status 500: 13155
slowest: 996 ms /p0 (line 1482)
lines: 1000000
malformed: 342453
go vet: no complaints
~~~

**341,511 malformed lines instead of 199**, and a different wrong number on the second run. The slowest line is wrong too. `Bytes()` returns a view of the scanner's own buffer, and the scanner overwrites that buffer as it reads the next lines. By the time a worker gets round to parsing its line, the bytes underneath have changed to parts of other lines. It compiles, `go vet` is happy, and nothing crashes: the numbers are simply wrong. This is the slice sharing from lesson 04, across goroutines. The comment on the `scanner.Text()` line in your code says why it's there; now you know what it prevents. Put it back.

## Check it

Run the [gate](../gate/README.md) against your module:

~~~bash
bash ~/Nicholas-Engineering-Blueprint/1-foundations/03-go-from-zero/gate/run.sh ~/blueprint/gofromzero
~~~

<!-- run: if [ -x /usr/bin/time ]; then bash "$BLUEPRINT_ROOT/1-foundations/03-go-from-zero/gate/run.sh" .; fi -->

~~~text
PASS  tasks: add, list, done, -file, and exit codes 1 and 2, across separate runs
PASS  loganalyse: bad lines reported, a 100 KB line read, ties broken by line, same answer with 1, 7 and the default number of workers
PASS  loganalyse: a million lines counted correctly
PASS  loganalyse: at most 64 MiB of memory for a 62 MiB log (it used 11 MiB)
PASS  gofmt: every file formatted
PASS  go vet: no problems
PASS  go test -race: all tests pass, no data races
Gate passed: on to Foundations 04.
~~~

This proves your two tools give the right answers on inputs you haven't seen, stream large files in little memory, give the same answer however many workers run, and have no races the detector can find. It doesn't prove they're as fast as they could be: why the reader became the bottleneck, and how to fix it, is a question for a profiler, in Core 06.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `bufio.Scanner: token too long` | A line over the scanner's limit | `scanner.Buffer(make([]byte, 64*1024), 1024*1024)` before the first `Scan` |
| Counts change between runs | A worker reads memory something else is changing: `scanner.Bytes()`, or a shared `Stats` | Send `scanner.Text()`; give each worker its own `Stats`; run with `-race` |
| The slowest line differs with `-workers 1` and `-workers 7` | Ties broken by arrival order | On equal `ms`, keep the earlier line number |
| The program hangs at the end | `lines` was never closed, so the workers wait forever | `close(lines)` after the reading loop, before `wg.Wait()` |
| Memory grows with the file | The file is read whole (`os.ReadFile`, `io.ReadAll`) | Stream it with `bufio.Scanner` |
| `/usr/bin/time: No such file or directory` | GNU `time` isn't installed | `sudo apt install -y time` |
