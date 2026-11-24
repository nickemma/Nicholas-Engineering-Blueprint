#!/usr/bin/env bash
# Gate for the Foundations test-out: tally (Go) and report.py (Python).
#
#   bash gate/run.sh /path/to/your/repo
#
# The repository holds tally/ (a Go module: `go build .` builds tally) and
# report/ (a uv project with report.py). Exits 0 when every check passes,
# 1 otherwise. Works on Linux and macOS (bash 3.2). Needs go, uv and /usr/bin/time.

set -u

dir=${1:-}
failed=0
pass() { echo "PASS  $1"; }
fail() {
  echo "FAIL  $1"
  while IFS= read -r l; do echo "      $l"; done <<< "$2"
  failed=1
}

if [ -z "$dir" ] || [ ! -f "$dir/tally/go.mod" ] || [ ! -f "$dir/report/report.py" ]; then
  echo "usage: bash gate/run.sh REPO   (REPO holds tally/go.mod and report/report.py)"
  exit 1
fi
dir=$(cd "$dir" && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
limit_kb=65536 # 64 MiB: far more than a streaming design needs, less than the big log itself

# The gate's own logs, expected answers and checks, in Python (standard library only).
cat > "$work/check.py" <<'PY'
import json, math, os, random, signal, subprocess, sys

TRAPS = [
    "not json at all",
    "",
    "[1, 2, 3]",
    '{"status": 42, "path": "/api/x", "ms": 1}',
    '{"status": 600, "path": "/api/x", "ms": 1}',
    '{"status": "200", "path": "/api/x", "ms": 1}',
    '{"status": true, "path": "/api/x", "ms": 1}',
    '{"status": 200, "path": "/api/x"}',
    '{"status": 200, "path": "/api/x", "ms": null}',
    '{"status": 200, "path": "/api/x", "ms": -1}',
    '{"status": 200, "path": "/api/x", "ms": 1.5}',
    '{"path": "/api/x", "ms": 1}',
    '{"status": 200, "path": "/api/x", "ms": 1} trailing',
    '{"status": 200, "path": 7, "ms": 1}',
]


def valid(rng, i):
    status = rng.choice([200, 200, 200, 201, 204, 301, 404, 404, 500, 503])
    path = rng.choice(["/api/jobs", "/api/jobs/7", "/health", "/web/index", "/api", "/apix", "/ünï"])
    return {"ts": "2026-11-18T09:00:00Z", "status": status, "path": path, "ms": rng.randrange(0, 2000)}


def traps_log():
    rng = random.Random(7)
    lines = []
    for i in range(300):
        lines.append(json.dumps(valid(rng, i), ensure_ascii=False))
        if i % 23 == 0:
            lines.append(TRAPS[(i // 23) % len(TRAPS)])
    lines += TRAPS
    lines.append(json.dumps({"status": 200, "path": "/api/" + "y" * 200_000, "ms": 7, "extra": [1, 2]}))
    lines.append('{"status": 404, "path": "/web/crlf", "ms": 33}\r')
    text = "\n".join(lines)  # no newline after the last line
    return text.encode()


def lines_of(data):
    """Split like a line reader: a final newline doesn't start another line."""
    if data == b"":
        return []
    parts = data.split(b"\n")
    return parts[:-1] if data.endswith(b"\n") else parts


def reference(data, prefix=""):
    """The expected answer, worked out independently of your code."""
    counts, ms, malformed = {}, [], 0
    for raw in lines_of(data):
        try:
            obj = json.loads(raw)
            ok = (isinstance(obj, dict)
                  and type(obj.get("status")) is int and 100 <= obj["status"] <= 599
                  and type(obj.get("ms")) is int and obj["ms"] >= 0
                  and isinstance(obj.get("path", ""), str))
        except ValueError:
            ok = False
        if not ok:
            malformed += 1
            continue
        if not obj.get("path", "").startswith(prefix):
            continue
        counts[str(obj["status"])] = counts.get(str(obj["status"]), 0) + 1
        ms.append(obj["ms"])
    ms.sort()
    pct = lambda p: ms[math.ceil(p / 100 * len(ms)) - 1] if ms else None
    return {"lines": len(ms), "status": counts, "p50_ms": pct(50), "p99_ms": pct(99), "malformed": malformed}


def big_log(path, n):
    rng = random.Random(11)
    with open(path, "w") as f:
        for i in range(1, n + 1):
            if i % 9973 == 0:
                f.write("oops, not json\n")
            else:
                f.write('{"ts":"2026-11-18T09:00:00Z","status":%d,"path":"/p%d","ms":%d}\n'
                        % (200 if i % 7 else 404, i % 13, rng.randrange(0, 1000)))


def run(seconds, out, err, stdin, cmd):
    """Run cmd with a time limit; on timeout kill it and everything it started."""
    with open(out, "w") as o, open(err, "w") as e, open(stdin, "rb") as i:
        proc = subprocess.Popen(cmd, stdin=i, stdout=o, stderr=e, start_new_session=True)
        try:
            return proc.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
    with open(err, "a") as e:
        e.write(f"timed out: still running after {seconds:g} s, so the gate stopped it\n")
    return 124


def compare(got_file, want):
    """Exit 0 if got_file holds one JSON object equal to want; else explain."""
    text = open(got_file).read()
    try:
        got = json.loads(text)
    except ValueError as err:
        sys.exit(f"output isn't one JSON object ({err}):\n{text[:300]}")
    if got != want:
        sys.exit(f"want {json.dumps(want, sort_keys=True)}\ngot  {json.dumps(got, sort_keys=True)}")


def report_rows(out_file, wants):
    """Check report.py's table: a header, then one row per .log file, by name."""
    rows = [l.split() for l in open(out_file).read().splitlines() if l.strip()]
    expect = [["file", "lines", "malformed", "p50_ms", "p99_ms"]]
    for name, s in wants:
        fmt = lambda v: "-" if v is None else str(v)
        expect.append([name, str(s["lines"]), str(s["malformed"]), fmt(s["p50_ms"]), fmt(s["p99_ms"])])
    if rows != expect:
        sys.exit("want:\n" + "\n".join(" ".join(r) for r in expect)
                 + "\ngot:\n" + "\n".join(" ".join(r) for r in rows))


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "make":  # make DIR: the small logs and their answers
        d = args[0]
        traps = traps_log()
        rng = random.Random(3)
        rand = ("\n".join(json.dumps(valid(rng, i)) for i in range(5000)) + "\n").encode()
        files = {"traps.log": traps, "empty.log": b"", "random.log": rand}
        for name, data in files.items():
            open(os.path.join(d, name), "wb").write(data)
        answers = {name: reference(data) for name, data in files.items()}
        answers["traps.log /api"] = reference(traps, "/api")
        answers["random.log /api/jobs"] = reference(rand, "/api/jobs")
        json.dump(answers, open(os.path.join(d, "answers.json"), "w"))
    elif cmd == "answer":  # answer DIR KEY
        print(json.dumps(json.load(open(os.path.join(args[0], "answers.json")))[args[1]]))
    elif cmd == "compare":  # compare GOT_FILE WANT_JSON
        compare(args[0], json.loads(args[1]))
    elif cmd == "big":  # big FILE N
        big_log(args[0], int(args[1]))
    elif cmd == "bigref":  # bigref FILE
        print(json.dumps(reference(open(args[0], "rb").read())))
    elif cmd == "run":  # run SECONDS OUT ERR STDIN CMD...
        sys.exit(run(float(args[0]), args[1], args[2], args[3], args[4:]))
    elif cmd == "rows":  # rows OUT_FILE DIR
        answers = json.load(open(os.path.join(args[1], "answers.json")))
        report_rows(args[0], [(n, answers[n]) for n in ("empty.log", "random.log", "traps.log")])
PY
if ! pybin=$(cd "$work" && uv run --quiet --no-project --python 3.14 python -c 'import sys; print(sys.executable)' 2>&1); then
  echo "can't run Python 3.14 with uv: $pybin"
  exit 1
fi
py() { "$pybin" -I "$work/check.py" "$@"; }
: > "$work/nothing"

# ---------------------------------------------------------------- tally
echo "== tally/"
t="$dir/tally"
if out=$(cd "$t" && gofmt -l . 2>&1) && [ -z "$out" ]; then pass "gofmt"; else fail "gofmt (these files need gofmt -w)" "$out"; fi
if out=$(cd "$t" && go vet ./... 2>&1); then pass "go vet"; else fail "go vet" "$out"; fi
if out=$(cd "$t" && go test -race -count=1 -timeout 120s ./... 2>&1); then
  if [ "$(cd "$t" && go test -list '.*' ./... 2>/dev/null | grep -c '^Test')" -gt 0 ]; then
    pass "go test -race"
  else
    fail "go test -race" "there are no tests"
  fi
else
  fail "go test -race" "$(echo "$out" | tail -20)"
fi

if ! out=$(cd "$t" && go build -o "$work/tally" . 2>&1); then
  fail "tally builds" "$out"
else
  mkdir -p "$work/logs"
  py make "$work/logs"
  # tally_case NAME LOG KEY [ARGS...]: run tally on LOG, compare with the answer KEY.
  tally_case() {
    local name=$1 log=$2 key=$3 code
    shift 3
    py run 30 "$work/t.out" "$work/t.err" "$work/logs/$log" "$work/tally" "$@"
    code=$?
    if [ "$code" != 0 ]; then
      fail "$name" "exit $code: $(head -5 "$work/t.err")"
    elif ! out=$(py compare "$work/t.out" "$(py answer "$work/logs" "$key")" 2>&1); then
      fail "$name" "$out"
    else
      pass "$name"
    fi
  }
  tally_case "a log with 14 kinds of malformed line, a 200 KB line, \\r\\n and no final newline" traps.log traps.log
  tally_case "an empty input" empty.log empty.log
  tally_case "5,000 lines" random.log random.log
  tally_case "-path /api on the log with traps" traps.log "traps.log /api" -path /api
  tally_case "-path /api/jobs on 5,000 lines" random.log "random.log /api/jobs" -path /api/jobs

  for args in "-nope" "-path" "extra-argument"; do
    # shellcheck disable=SC2086  # each case is split into words on purpose
    py run 10 "$work/t.out" "$work/t.err" "$work/nothing" "$work/tally" $args
    code=$?
    if [ "$code" = 2 ] && [ -s "$work/t.err" ]; then
      pass "tally $args: exit 2 with a message"
    else
      fail "tally $args: exit 2 with a message" "exit $code; stderr: $(head -3 "$work/t.err")"
    fi
  done

  # ------------------------------------------------------------ memory
  case "$(uname)" in
    Darwin) timer="/usr/bin/time -l" ;;
    *) timer="/usr/bin/time -f %M" ;;
  esac
  if ! /usr/bin/time true > /dev/null 2>&1; then
    fail "/usr/bin/time is installed" "install it: sudo apt install -y time (macOS has it already)"
  else
    py big "$work/big.log" 1000000
    want=$(py bigref "$work/big.log")
    # shellcheck disable=SC2086  # $timer is a command and its options
    py run 120 "$work/t.out" "$work/time.txt" "$work/big.log" $timer "$work/tally"
    case "$(uname)" in
      Darwin) kb=$(awk '/maximum resident set size/ {print int($1 / 1024)}' "$work/time.txt") ;;
      *) kb=$(tail -1 "$work/time.txt") ;;
    esac
    if ! out=$(py compare "$work/t.out" "$want" 2>&1); then
      fail "a million lines counted correctly" "$out"
    else
      pass "a million lines counted correctly"
    fi
    mib=$(($(wc -c < "$work/big.log") / 1048576))
    if [ -n "$kb" ] && [ "$kb" -eq "$kb" ] 2> /dev/null && [ "$kb" -le "$limit_kb" ]; then
      pass "at most $((limit_kb / 1024)) MiB of memory for a $mib MiB log (it used $((kb / 1024)) MiB)"
    else
      fail "at most $((limit_kb / 1024)) MiB of memory for a $mib MiB log" "it used ${kb:-?} KiB: read standard input line by line instead of all at once"
    fi
  fi
fi

# ---------------------------------------------------------------- report.py
echo "== report/"
r="$dir/report"
if out=$(cd "$r" && uv run --quiet ruff format --check . 2>&1); then pass "ruff format"; else fail "ruff format (run uv run ruff format .)" "$out"; fi
if out=$(cd "$r" && uv run --quiet ruff check . 2>&1); then pass "ruff check"; else fail "ruff check" "$out"; fi
if (cd "$r" && py run 120 "$work/p.out" "$work/p.err" "$work/nothing" uv run --quiet pytest -q); then
  pass "pytest, without tally built"
else
  fail "pytest, without tally built" "$(cat "$work/p.out" "$work/p.err" | tail -20)"
fi

if [ -x "$work/tally" ]; then
  : > "$work/logs/notes.txt" # not a .log file: report.py should skip it
  (cd "$r" && py run 120 "$work/r.out" "$work/r.err" "$work/nothing" uv run --quiet report.py "$work/logs" --tally "$work/tally" --png "$work/status.png")
  code=$?
  if [ "$code" != 0 ]; then
    fail "report.py on three logs" "exit $code: $(tail -5 "$work/r.err")"
  elif ! out=$(py rows "$work/r.out" "$work/logs" 2>&1); then
    fail "report.py on three logs: the table" "$out"
  else
    pass "report.py on three logs: the table"
  fi
  if [ "$(head -c 8 "$work/status.png" 2> /dev/null | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
    pass "report.py: the chart is a PNG image"
  else
    fail "report.py: the chart is a PNG image" "--png $work/status.png is missing or isn't a PNG"
  fi
fi

# A tally that fails: report.py must say so in one line and exit 1.
printf '#!/bin/sh\ncat > /dev/null\necho "tally: something went wrong" >&2\nexit 1\n' > "$work/broken-tally"
chmod +x "$work/broken-tally"
(cd "$r" && py run 120 "$work/r.out" "$work/r.err" "$work/nothing" uv run --quiet report.py "$work/logs" --tally "$work/broken-tally" --png "$work/b.png")
code=$?
if [ "$code" = 1 ] && [ -s "$work/r.err" ] && ! grep -q Traceback "$work/r.err"; then
  pass "report.py when tally fails: exit 1 with a message ($(head -1 "$work/r.err"))"
else
  fail "report.py when tally fails: exit 1 with a one-line message, not a traceback" "exit $code
$(tail -5 "$work/r.err")"
fi

echo
if [ "$failed" = 0 ]; then
  echo "Gate passed: start the core."
else
  echo "Gate failed: fix each FAIL above and run it again, or take the Foundations module that covers it."
fi
exit "$failed"
