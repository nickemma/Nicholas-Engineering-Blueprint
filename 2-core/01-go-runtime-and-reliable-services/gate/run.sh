#!/usr/bin/env bash
# Gate for core 01: Switchyard's control plane and workers, under load and
# under failure.
#
#   bash gate/run.sh ~/blueprint/switchyard
#
# The folder is your Go module, with ./cmd/switchyard and ./cmd/worker.
# It uses ports 18080 and 19090, and takes about a minute (up to three
# when jobs get stuck: it waits 90 seconds for them to settle).
# Exits 0 when every check passes, 1 otherwise.

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

if [ -z "$dir" ] || [ ! -f "$dir/go.mod" ]; then
  echo "usage: bash gate/run.sh FOLDER   (FOLDER is your Go module, with cmd/switchyard and cmd/worker)"
  exit 1
fi
dir=$(cd "$dir" && pwd -P)
work=$(mktemp -d)
http=127.0.0.1:18080
grpc=127.0.0.1:19090
url=http://$http
# shellcheck disable=SC2317  # called by the trap
cleanup() {
  for f in "$work"/pids/*; do [ -f "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null; done
  [ -n "${cp:-}" ] && kill -KILL "$cp" 2>/dev/null
  [ -n "${chaos:-}" ] && kill -KILL "$chaos" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/pids" "$work/logs"

# ---------------------------------------------------------------- 5. static checks and tests
out=$(cd "$dir" && gofmt -l . 2>&1 | grep -v '^bin/')
if [ -n "$out" ]; then fail "gofmt -l . lists nothing" "$out"; else pass "gofmt -l . lists nothing"; fi
if out=$(cd "$dir" && go vet ./... 2>&1); then pass "go vet ./..."; else fail "go vet ./..." "$out"; fi
if out=$(cd "$dir" && go test -race -count=1 ./... 2>&1); then pass "go test -race ./..."; else fail "go test -race ./..." "$(echo "$out" | grep -v '^ok\|no test files' | head -30)"; fi

# ---------------------------------------------------------------- build with the race detector
for cmd in switchyard worker; do
  if ! out=$(cd "$dir" && go build -race -o "$work/$cmd" ./cmd/$cmd 2>&1); then
    fail "cmd/$cmd builds with -race" "$out"
    exit 1
  fi
done
(cd "$gate/driver" && go build -o "$work/driver" .) || { echo "the gate's own driver didn't build"; exit 1; }
if curl -s -o /dev/null "$url/health" 2>/dev/null; then
  echo "Something is already listening on $http. Stop it, then run the gate again."
  exit 1
fi

# ---------------------------------------------------------------- start the control plane and 4 workers
LISTEN_ADDR=$http GRPC_ADDR=$grpc LEASE_TTL=1s SHUTDOWN_GRACE=5s QUEUE_CAPACITY=20000 \
  "$work/switchyard" > "$work/logs/control-plane.log" 2>&1 &
cp=$!
for _ in $(seq 50); do curl -s -o /dev/null "$url/health" && break; sleep 0.1; done

seq_no=0
start_worker() {
  seq_no=$((seq_no + 1))
  CONTROL_PLANE=$grpc WORKER_NAME=w$seq_no SHUTDOWN_GRACE=5s \
    "$work/worker" > "$work/logs/worker-$seq_no.log" 2>&1 &
  echo $! > "$work/pids/w$seq_no"
  disown $! # no "Killed" notice when the chaos loop kills it
}
for _ in 1 2 3 4; do start_worker; done
sleep 1.5

goroutines() { curl -s "$url/metrics" | awk '$1 == "go_goroutines" {print $2}'; }
baseline=$(goroutines)
if [ -z "$baseline" ]; then
  fail "GET /metrics reports go_goroutines" "register collectors.NewGoCollector() on the metrics registry"
  baseline=0
fi

# ---------------------------------------------------------------- 2. chaos: kill workers while the load runs
(
  set +e
  n=100
  first=1
  while :; do
    sleep 1.$((RANDOM % 9))
    victims=$(ls "$work/pids")
    [ -z "$victims" ] && continue
    count=$(echo "$victims" | wc -l)
    pick=$(echo "$victims" | sed -n "$((RANDOM % count + 1))p")
    pid=$(cat "$work/pids/$pick")
    if [ $first = 1 ]; then
      # Pause one worker for longer than the lease: it comes back to find
      # its job given away, and must not be allowed to finish it.
      first=0
      kill -STOP "$pid"; echo "paused $pick" >> "$work/logs/chaos.log"
      sleep 2.5
      kill -CONT "$pid"; echo "resumed $pick" >> "$work/logs/chaos.log"
      continue
    fi
    kill -KILL "$pid" 2>/dev/null; rm -f "$work/pids/$pick"
    echo "killed $pick" >> "$work/logs/chaos.log"
    n=$((n + 1))
    CONTROL_PLANE=$grpc WORKER_NAME=w$n SHUTDOWN_GRACE=5s "$work/worker" > "$work/logs/worker-$n.log" 2>&1 &
    echo $! > "$work/pids/w$n"
    disown $!
  done
) &
chaos=$!

# ---------------------------------------------------------------- 1 and 3. load, then convergence
echo "sending 10,000 state changes from 32 clients while workers are killed; this takes a minute or two"
"$work/driver" -url "$url" -changes 10000 -clients 32 -settle 90s > "$work/driver.out" 2>&1
driver_status=$?
kill -KILL "$chaos" 2>/dev/null
wait "$chaos" 2>/dev/null
chaos=
sed -n '1,2p' "$work/driver.out"
grep -E '^(PASS|FAIL|        )' "$work/driver.out"
[ $driver_status = 0 ] || failed=1
killed=$(grep -c '^killed' "$work/logs/chaos.log" 2>/dev/null)
echo "      workers killed with SIGKILL: ${killed:-0}; one paused past its lease"
handed=$(curl -s "$url/metrics" | awk '$1 == "jobs_handed_back_total" {print $2}')
[ -n "$handed" ] && echo "      jobs handed back by the reconcile loop: $handed"

# ---------------------------------------------------------------- 4. no leaked goroutines
now=$(goroutines)
for _ in $(seq 30); do
  [ -n "$now" ] && [ "$now" -le $((baseline + 3)) ] && break
  sleep 0.5
  now=$(goroutines)
done
if [ -n "$now" ] && [ "$now" -le $((baseline + 3)) ]; then
  pass "goroutines came back to the baseline ($baseline before, $now after)"
else
  fail "goroutines came back to the baseline" "before the load: $baseline; 15 s after it: ${now:-unknown}. Something starts goroutines that never end."
fi

# ---------------------------------------------------------------- 4. SIGTERM stops everything within the grace period
for f in "$work"/pids/*; do kill -TERM "$(cat "$f")" 2>/dev/null; done
kill -TERM "$cp"
start=$(date +%s)
wait "$cp"
cp_status=$?
cp=
slow=""
for f in "$work"/pids/*; do
  pid=$(cat "$f")
  while kill -0 "$pid" 2>/dev/null && [ $(($(date +%s) - start)) -le 7 ]; do sleep 0.1; done
  kill -0 "$pid" 2>/dev/null && slow="$slow $(basename "$f")"
done
took=$(($(date +%s) - start))
if [ $cp_status = 0 ] && [ $took -le 7 ] && [ -z "$slow" ]; then
  pass "SIGTERM stopped the control plane and every worker within the grace period (${took} s)"
else
  fail "SIGTERM stops everything within the grace period" "control plane exit status $cp_status after ${took} s (grace 5 s)${slow:+; still running:$slow}"
fi

# ---------------------------------------------------------------- 4. the race detector stayed silent
races=$(grep -l 'WARNING: DATA RACE' "$work"/logs/*.log 2>/dev/null)
if [ -z "$races" ]; then
  pass "the race detector reported nothing"
else
  fail "the race detector reported nothing" "$(for f in $races; do echo "in $(basename "$f"):"; grep -A12 -m1 'WARNING: DATA RACE' "$f"; done)"
fi

echo
if [ $failed = 0 ]; then echo "gate passed"; else echo "gate failed"; fi
exit $failed
