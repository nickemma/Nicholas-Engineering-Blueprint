#!/usr/bin/env bash
# Gate for core 02: is kload honest?
#
#   bash gate/run.sh ~/blueprint/kload
#
# The folder is your uv project, with the kload command. The gate runs it
# against its own server, whose answers take a known time and which logs
# when each request really arrived, so it can check kload's numbers against
# the truth. Exits 0 when every check passes, 1 otherwise.
# Works on Linux and macOS (bash 3.2). Needs go and uv; takes about a minute.

set -u

dir=${1:-}
gate=$(cd "$(dirname "$0")" && pwd -P)
failed=0
pass() { echo "PASS  $1"; }
fail() {
  echo "FAIL  $1"
  while IFS= read -r l; do echo "      $l"; done <<< "$2"
  failed=1
}

if [ -z "$dir" ] || [ ! -f "$dir/pyproject.toml" ]; then
  echo "usage: bash gate/run.sh FOLDER   (FOLDER is your kload uv project)"
  exit 1
fi
dir=$(cd "$dir" && pwd -P)
work=$(mktemp -d)
target_pid=""
# shellcheck disable=SC2317  # called by the trap
cleanup() {
  [ -n "$target_pid" ] && kill -CONT "$target_pid" 2>/dev/null && kill -KILL "$target_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

cat > "$work/check.py" <<'PY'
import csv, math, os, random, re, signal, subprocess, sys

HEADER = ["request", "scheduled_s", "sent_s", "latency_s", "status", "error"]


def pct(values, p):
    values = sorted(values)
    return values[math.ceil(p / 100 * len(values)) - 1]


def run(seconds, out, err, cmd):
    """Run cmd with a time limit; on timeout kill it and everything it started."""
    with open(out, "w") as o, open(err, "w") as e:
        proc = subprocess.Popen(cmd, stdout=o, stderr=e, start_new_session=True)
        try:
            return proc.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
    with open(err, "a") as e:
        e.write(f"timed out: still running after {seconds:g} s, so the gate stopped it\n")
    return 124


def rows(path, n):
    """kload's CSV: the header, then requests 0 to n-1, each once."""
    try:
        with open(path, newline="") as f:
            data = list(csv.reader(f))
    except OSError as err:
        sys.exit(f"no results file: {err}")
    if not data or data[0] != HEADER:
        sys.exit(f"the first line is {','.join(data[0]) if data else '(empty)'}, want {','.join(HEADER)}")
    out = {}
    for line, row in enumerate(data[1:], start=2):
        try:
            out[int(row[0])] = (float(row[1]), float(row[2]), float(row[3]), int(row[4]))
        except (ValueError, IndexError):
            sys.exit(f"line {line} can't be read: {','.join(row)}")
    if sorted(out) != list(range(n)) or len(data) - 1 != n:
        sys.exit(f"want requests 0 to {n - 1}, each once; got {len(data) - 1} rows")
    return out


def arrivals(path):
    """The server's log: request number -> (arrived ns, answered ns)."""
    out = {}
    with open(path) as f:
        for line in f:
            start, end, _method, number = line.split()
            out[int(number)] = (int(start), int(end))
    return out


def accuracy(csv_path, log_path, rate, n):
    got = rows(csv_path, n)
    seen = arrivals(log_path)
    if sorted(k for k in seen if k >= 0) != list(range(n)):
        sys.exit(f"the server saw {len([k for k in seen if k >= 0])} numbered requests, want {n}: "
                 "does a POST carry an Idempotency-Key ending in -N, N being the request number?")
    t0 = seen[0][0]
    late = [abs((seen[i][0] - t0) / 1e9 - i / rate) * 1000 for i in range(n)]
    server = [(seen[i][1] - seen[i][0]) / 1e6 for i in range(n)]
    reported = [got[i][2] * 1000 for i in range(n) if 200 <= got[i][3] < 300]
    faster = [i for i in range(n) if got[i][2] * 1000 < server[i]]
    print(f"arrived on schedule: p99 {pct(late, 99):.2f} ms off, worst {max(late):.2f} ms")
    print(f"p50: kload says {pct(reported, 50):.2f} ms; the server took {pct(server, 50):.2f} ms")
    problems = []
    if len(reported) != n:
        problems.append(f"{n - len(reported)} requests weren't answered with 2xx")
    if pct(late, 99) > 10:
        problems.append(f"requests arrived up to {pct(late, 99):.1f} ms (p99) away from their schedule; "
                        "want within 10 ms")
    if faster:
        i = faster[0]
        problems.append(f"{len(faster)} latencies are shorter than the server's own time, which can't be: "
                        f"request {i}: kload says {got[i][2] * 1000:.3f} ms, the server took {server[i]:.3f} ms")
    elif pct(reported, 50) - pct(server, 50) > 3:
        problems.append(f"kload's p50 is {pct(reported, 50) - pct(server, 50):.2f} ms above the server's; "
                        "want within 3 ms")
    if problems:
        sys.exit("\n".join(problems))


def frozen(csv_path, n, mode):
    got = rows(csv_path, n)
    slow = sum(got[i][2] >= 0.5 for i in range(n))
    print(f"{slow} of {n} requests took 500 ms or more")
    if mode == "open" and not 40 <= slow <= 60:
        sys.exit(f"want 40 to 60: about 50 requests were due in the first half of the 1-second freeze, "
                 "and each waited at least 500 ms from when it was due")
    if mode == "closed" and slow > 2:
        sys.exit("a closed loop sends nothing while it waits, so it should record the freeze once")


def behind(csv_path, log_path, rate, seconds):
    n = round(rate * seconds)
    got = rows(csv_path, n)
    short = [i for i in range(n) if got[i][2] < got[i][1] - got[i][0] - 1e-6]
    if short:
        i = short[0]
        sys.exit(f"{len(short)} latencies are shorter than the time the request waited inside kload: "
                 f"request {i} was sent {(got[i][1] - got[i][0]) * 1000:.1f} ms late but has a latency "
                 f"of {got[i][2] * 1000:.1f} ms. Time latency from when a request was due, not sent")
    with open(log_path) as f:
        times = [int(line.split()[0]) for line in f]
    took = (max(times) - min(times)) / 1e9
    print(f"the server saw {len(times)} requests spread over {took:.2f} s, not {seconds:g} s")
    if took < seconds * 1.2:
        sys.exit("the server's log shows kload kept up: try a higher rate")


def synthetic(folder):
    """Five runs each. a2 is a's runs in the opposite order, each 0.01 ms slower:
    the same server, measured again. b is a, 2 ms slower."""
    for name, shift, order in (("a", 0.0, 1), ("a2", 0.01, -1), ("b", 2.0, 1)):
        os.makedirs(os.path.join(folder, name))
        for run_number in range(5):
            seed = run_number if order == 1 else 4 - run_number
            rng = random.Random(seed)
            run_shift = random.Random(100 + seed).gauss(0, 0.05)
            with open(os.path.join(folder, name, f"run{run_number}.csv"), "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(HEADER)
                for i in range(400):
                    latency = 5 + shift + run_shift + rng.expovariate(1 / 0.3)
                    status = 503 if i % 50 == 7 else 201  # errors that a p99 must ignore
                    if status == 503:
                        latency = 0.2
                    w.writerow([i, f"{i / 200:.6f}", f"{i / 200 + 0.0005:.6f}",
                                f"{latency / 1000:.6f}", status, ""])


def compared(out_path, expect):
    text = open(out_path).read()
    m = re.search(r"^p99 B - A: ([+-]\d+\.\d+) ms, 95% CI \[([+-]\d+\.\d+), ([+-]\d+\.\d+)\] ms: (.+)$",
                  text, re.M)
    if not m:
        sys.exit("no line like 'p99 B - A: +2.03 ms, 95% CI [+1.90, +2.15] ms: B is slower'\n" + text)
    diff, low, high, verdict = float(m[1]), float(m[2]), float(m[3]), m[4]
    print(m[0])
    if not low <= diff <= high:
        sys.exit("the difference should lie inside its own interval")
    if expect == "same":
        if not (low <= 0 <= high and verdict.startswith("no difference shown")):
            sys.exit("A and A2 come from the same server: the interval should include 0, "
                     "and the verdict start 'no difference shown'")
    else:
        if not (1.5 <= diff <= 2.5 and low > 0 and verdict == "B is slower"):
            sys.exit("B is 2 ms slower in every run: want a difference near +2.00, "
                     "an interval above 0, and the verdict 'B is slower'")


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "run":
        sys.exit(run(float(args[0]), args[1], args[2], args[3:]))
    elif cmd == "accuracy":
        accuracy(args[0], args[1], float(args[2]), int(args[3]))
    elif cmd == "frozen":
        frozen(args[0], int(args[1]), args[2])
    elif cmd == "behind":
        behind(args[0], args[1], float(args[2]), float(args[3]))
    elif cmd == "synthetic":
        synthetic(args[0])
    elif cmd == "compared":
        compared(args[0], args[1])
PY
if ! pybin=$(cd "$work" && uv run --quiet --no-project --python 3.14 python -c 'import sys; print(sys.executable)' 2>&1); then
  echo "can't run Python 3.14 with uv: $pybin"
  exit 1
fi
py() { "$pybin" -I "$work/check.py" "$@"; }
indent() { sed 's/^/      /'; }

# ---------------------------------------------------------------- 5. static checks and tests
if out=$(cd "$dir" && uv run --quiet ruff format --check . 2>&1); then pass "ruff format"; else fail "ruff format (run uv run ruff format .)" "$out"; fi
if out=$(cd "$dir" && uv run --quiet ruff check . 2>&1); then pass "ruff check"; else fail "ruff check" "$out"; fi
if (cd "$dir" && py run 180 "$work/t.out" "$work/t.err" uv run --quiet pytest -q); then
  pass "pytest"
else
  summary=$(sed -n '/short test summary info/,$p' "$work/t.out")
  fail "pytest" "${summary:-$(tail -25 "$work/t.out")}$(tail -5 "$work/t.err")"
fi

# ---------------------------------------------------------------- the gate's server
if ! out=$(cd "$gate/delay-fixture" && go build -o "$work/target" . 2>&1); then
  echo "the gate's own server didn't build: $out"
  exit 1
fi
start_target() { # DELAY LOG: start the server, set $url
  "$work/target" -addr 127.0.0.1:0 -delay "$1" -log "$2" > "$work/target.out" 2>&1 &
  target_pid=$!
  for _ in $(seq 50); do grep -q listening "$work/target.out" && break; sleep 0.1; done
  url="http://$(sed -n 's/^listening on //p' "$work/target.out")"
}
stop_target() {
  kill -CONT "$target_pid" 2>/dev/null
  kill -TERM "$target_pid" 2>/dev/null
  wait "$target_pid" 2>/dev/null
  target_pid=""
}
kload() { # SECONDS NAME ARGS...: run kload load, with its output in $work/NAME.out and .err
  local seconds=$1 name=$2
  shift 2
  (cd "$dir" && py run "$seconds" "$work/$name.out" "$work/$name.err" \
    uv run --quiet kload load --url "$url" --out "$work/$name.csv" "$@")
}
show() { cat "$work/$1.out" "$work/$1.err" | indent; }

# ---------------------------------------------------------------- 1. accurate
start_target 5ms "$work/accuracy.log"
kload 60 accuracy --method POST --path /work --rate 200 --duration 5
status=$?
stop_target
if [ $status != 0 ]; then
  fail "200 requests a second for 5 s against a 5 ms server" "kload exited with $status, want 0:
$(show accuracy)"
elif out=$(py accuracy "$work/accuracy.csv" "$work/accuracy.log" 200 1000 2>&1); then
  pass "200 requests a second for 5 s against a 5 ms server: on schedule, and accurate"
  echo "$out" | indent
else
  fail "200 requests a second for 5 s against a 5 ms server: on schedule, and accurate" "$out"
fi

# ---------------------------------------------------------------- 2. open, not closed
for mode in open closed; do
  start_target 5ms "$work/freeze-$mode.log"
  (sleep 2; kill -STOP "$target_pid"; sleep 1; kill -CONT "$target_pid") &
  freezer=$!
  kload 60 "freeze-$mode" --method POST --path /work --rate 100 --duration 5 --mode "$mode"
  status=$?
  wait "$freezer"
  stop_target
  name="the server freezes for 1 s: $mode loop"
  if [ $status != 0 ]; then
    fail "$name" "kload exited with $status, want 0:
$(show "freeze-$mode")"
  elif ! out=$(py frozen "$work/freeze-$mode.csv" 500 "$mode" 2>&1); then
    fail "$name" "$out"
  elif [ "$mode" = closed ] && ! grep -qi closed "$work/freeze-closed.out"; then
    fail "$name" "kload should say it ran a closed loop; it printed:
$(show freeze-closed)"
  else
    pass "$name"
    echo "$out" | indent
  fi
done

# ---------------------------------------------------------------- 3. honest about itself
start_target 0s "$work/behind.log"
kload 120 behind --method POST --path /work --rate 20000 --duration 2
status=$?
stop_target
name="at 20,000 requests a second, kload says it fell behind and exits 3"
if [ $status != 3 ]; then
  fail "$name" "kload exited with $status, want 3:
$(show behind)"
elif [ ! -s "$work/behind.err" ]; then
  fail "$name" "exit 3, but nothing on standard error to say why"
elif ! out=$(py behind "$work/behind.csv" "$work/behind.log" 20000 2 2>&1); then
  fail "$name" "$out"
else
  pass "$name"
  { grep -i behind "$work/behind.err" | head -1; echo "$out"; } | indent
fi

# ---------------------------------------------------------------- 4. compares properly
py synthetic "$work/runs"
for pair in a:a2:same a:b:slower; do
  IFS=: read -r a b expect <<< "$pair"
  name="kload compare: two sets of runs from the same server"
  [ "$expect" = slower ] && name="kload compare: B is 2 ms slower in every run"
  if ! (cd "$dir" && py run 60 "$work/cmp.out" "$work/cmp.err" uv run --quiet kload compare "$work/runs/$a" "$work/runs/$b"); then
    fail "$name" "$(cat "$work/cmp.out" "$work/cmp.err")"
  elif out=$(py compared "$work/cmp.out" "$expect" 2>&1); then
    pass "$name"
    echo "$out" | indent
  else
    fail "$name" "$out"
  fi
done

echo
if [ $failed = 0 ]; then echo "gate passed"; else echo "gate failed"; fi
exit $failed
