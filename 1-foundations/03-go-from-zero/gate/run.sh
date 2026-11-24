#!/usr/bin/env bash
# Gate for Foundations 03: your task engine and your log analyser.
#
#   bash gate/run.sh ~/blueprint/gofromzero
#
# The folder is your Go module, with ./cmd/tasks and ./cmd/loganalyse.
# Exits 0 when every check passes, 1 otherwise. Works on Linux and macOS (bash 3.2).

set -u

dir=${1:-}
failed=0
pass() { echo "PASS  $1"; }
fail() {
  echo "FAIL  $1"
  while IFS= read -r l; do echo "      $l"; done <<< "$2"
  failed=1
}

if [ -z "$dir" ] || [ ! -f "$dir/go.mod" ]; then
  echo "usage: bash gate/run.sh FOLDER   (FOLDER is your Go module, with cmd/tasks and cmd/loganalyse)"
  exit 1
fi
dir=$(cd "$dir" && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
limit_kb=65536 # 64 MiB: far more than a streaming design needs, less than the big log itself

# ---------------------------------------------------------------- build
if ! out=$(cd "$dir" && go build -o "$work/tasks" ./cmd/tasks 2>&1); then
  fail "cmd/tasks builds" "$out"
fi
if ! out=$(cd "$dir" && go build -o "$work/loganalyse" ./cmd/loganalyse 2>&1); then
  fail "cmd/loganalyse builds" "$out"
fi

# ---------------------------------------------------------------- tasks
# step EXPECTED_EXIT EXPECTED_STDOUT ARGS...: run tasks in a fresh folder, compare.
step() {
  local want_code=$1 want_out=$2 got code
  shift 2
  got=$(cd "$work/t" && "$work/tasks" "$@" 2>"$work/stderr")
  code=$?
  if [ "$code" != "$want_code" ] || [ "$got" != "$want_out" ]; then
    fail "tasks $*" "want exit $want_code and:
$want_out
got exit $code and:
$got
stderr: $(cat "$work/stderr")"
    return 1
  fi
  if [ "$want_code" != 0 ] && [ ! -s "$work/stderr" ]; then
    fail "tasks $*" "exited $code but printed no reason on standard error"
    return 1
  fi
}

if [ -x "$work/tasks" ]; then
  mkdir -p "$work/t"
  ok=1
  step 0 "no tasks" list || ok=0
  step 0 "added 1: write the gate" add "write the gate" || ok=0
  step 0 "added 2: test it both ways" add "test it both ways" || ok=0
  step 0 "done 1: write the gate" "done" 1 || ok=0
  step 0 "1 [x] write the gate
2 [ ] test it both ways" list || ok=0
  step 1 "" "done" 9 || ok=0
  step 2 "" "done" abc || ok=0
  step 2 "" || ok=0
  step 2 "" frobnicate || ok=0
  step 0 "added 1: elsewhere" -file other.json add "elsewhere" || ok=0
  step 0 "1 [ ] elsewhere" -file other.json list || ok=0
  step 0 "1 [x] write the gate
2 [ ] test it both ways" list || ok=0
  [ "$ok" = 1 ] && pass "tasks: add, list, done, -file, and exit codes 1 and 2, across separate runs"
fi

# ---------------------------------------------------------------- loganalyse, small log
long=$(awk 'BEGIN { for (i = 0; i < 100000; i++) printf "x" }')
{
  echo '{"ts":"t","status":200,"path":"/a","ms":5}'
  echo '{"ts":"t","status":404,"path":"/b","ms":40}'
  echo 'not json'
  echo '{"ts":"t","status":200,"path":"/c","ms":40}'
  echo '{"status":42,"ms":1}'
  echo ''
  echo "{\"ts\":\"t\",\"status\":500,\"path\":\"/$long\",\"ms\":20}"
  echo '{"status":200,"ms":-3}'
  echo '{"status":503,"path":"/d","ms":1}'
} > "$work/small.log"
want_small="lines: 9
malformed: 4
status 200: 2
status 404: 1
status 500: 1
status 503: 1
slowest: 40 ms /b (line 2)
malformed lines:"

# check_small FLAGS: run loganalyse with FLAGS on the small log and compare.
check_small() {
  local args=$1 got head bad
  # shellcheck disable=SC2086 # args is a list of flags, split on purpose
  got=$("$work/loganalyse" $args "$work/small.log" 2>&1)
  head=$(echo "$got" | sed -n '1,8p')
  bad=$(echo "$got" | sed -n '9,$p' | sed -n 's/^  line \([0-9]*\):.*/\1/p' | tr '\n' ' ')
  if [ "$head" = "$want_small" ] && [ "$bad" = "3 5 6 8 " ]; then
    return 0
  fi
  fail "loganalyse $args on a small log with traps" "want:
$want_small
  line 3: ..., line 5: ..., line 6: ..., line 8: ...
got:
$(echo "$got" | cut -c1-120)"
  return 1
}
if [ -x "$work/loganalyse" ]; then
  if check_small "-workers 1" && check_small "-workers 7" && check_small ""; then
    pass "loganalyse: bad lines reported, a 100 KB line read, ties broken by line, same answer with 1, 7 and the default number of workers"
  fi
fi

# ---------------------------------------------------------------- loganalyse, a million lines
# The same rules generate the log and work out the answer, independently of your code.
awk -v n=1000000 -v want="$work/want.txt" '
  BEGIN {
    for (i = 1; i <= n; i++) {
      if (i % 9973 == 0) { print "oops, not json"; bad[++nb] = i; continue }
      s = (i % 50 == 0) ? 500 : (i % 7 == 0) ? 404 : 200
      if (i % 10007 == 0) { printf "{\"ts\":\"2026-11-18T09:00:00Z\",\"status\":%d,\"path\":\"/p%d\"}\n", s, i % 13; bad[++nb] = i; continue }
      ms = (i * 37) % 997
      printf "{\"ts\":\"2026-11-18T09:00:00Z\",\"status\":%d,\"path\":\"/p%d\",\"ms\":%d}\n", s, i % 13, ms
      count[s]++
      if (slow == "" || ms > slow) { slow = ms; slowline = i; slowpath = "/p" (i % 13) }
    }
    printf "lines: %d\nmalformed: %d\n", n, nb > want
    printf "status 200: %d\nstatus 404: %d\nstatus 500: %d\n", count[200], count[404], count[500] > want
    printf "slowest: %d ms %s (line %d)\n", slow, slowpath, slowline > want
    for (k = 1; k <= 10; k++) printf "%d ", bad[k] > want
    printf "\n%d\n", nb - 10 > want
  }' > "$work/big.log"

if [ -x "$work/loganalyse" ]; then
  case "$(uname -s)" in
    Darwin) timer() { /usr/bin/time -l "$@" 2> "$work/time.txt"; } ;;
    *) timer() { /usr/bin/time -f "%M" "$@" 2> "$work/time.txt"; } ;;
  esac
  if ! /usr/bin/time true >/dev/null 2>&1; then
    fail "/usr/bin/time is installed" "install it: sudo apt install -y time (macOS has it already)"
  else
    got=$(timer "$work/loganalyse" "$work/big.log")
    case "$(uname -s)" in
      Darwin) kb=$(awk '/maximum resident set size/ {print int($1 / 1024)}' "$work/time.txt") ;;
      *) kb=$(tail -1 "$work/time.txt") ;;
    esac
    head=$(echo "$got" | sed -n '1,6p')
    bad=$(echo "$got" | sed -n 's/^  line \([0-9]*\):.*/\1/p' | tr '\n' ' ')
    more=$(echo "$got" | sed -n 's/^  \.\.\. and \([0-9]*\) more$/\1/p')
    want_head=$(sed -n '1,6p' "$work/want.txt")
    want_bad=$(sed -n '7p' "$work/want.txt")
    want_more=$(sed -n '8p' "$work/want.txt")
    if [ "$head" = "$want_head" ] && [ "$bad" = "$want_bad" ] && [ "$more" = "$want_more" ]; then
      pass "loganalyse: a million lines counted correctly"
    else
      fail "loganalyse: a million lines counted correctly" "want:
$want_head
  malformed lines: $want_bad... and $want_more more
got:
$(echo "$got" | head -20 | cut -c1-120)"
    fi
    if [ -n "$kb" ] && [ "$kb" -le "$limit_kb" ]; then
      pass "loganalyse: at most $((limit_kb / 1024)) MiB of memory for a $(($(wc -c < "$work/big.log") / 1048576)) MiB log (it used $((kb / 1024)) MiB)"
    else
      fail "loganalyse: at most $((limit_kb / 1024)) MiB of memory" "it used ${kb:-?} KiB. Read the file line by line with bufio.Scanner instead of loading it whole."
    fi
  fi
fi

# ---------------------------------------------------------------- code checks
if unformatted=$(cd "$dir" && gofmt -l .) && [ -z "$unformatted" ]; then
  pass "gofmt: every file formatted"
else
  fail "gofmt: every file formatted" "run gofmt -w on: $unformatted"
fi
if out=$(cd "$dir" && go vet ./... 2>&1); then
  pass "go vet: no problems"
else
  fail "go vet: no problems" "$out"
fi
if out=$(cd "$dir" && go test -race -count=1 ./... 2>&1); then
  pass "go test -race: all tests pass, no data races"
else
  fail "go test -race: all tests pass, no data races" "$(echo "$out" | tail -30)"
fi

if [ "$failed" -eq 0 ]; then
  echo "Gate passed: on to Foundations 04."
else
  echo "Gate failed: fix the FAIL lines above and run it again."
fi
exit "$failed"
