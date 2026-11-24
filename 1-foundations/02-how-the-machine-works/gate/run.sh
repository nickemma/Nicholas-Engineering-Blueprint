#!/usr/bin/env bash
# Gate for Foundations 02: your monitor and your log rotator.
#
#   bash gate/run.sh ~/blueprint/machine
#
# The folder must hold monitor.sh and rotate.sh, as built in lessons 05 and 07.
#   monitor.sh [PATH]      prints: load1=<n> mem_used_pct=<n> disk_used_pct=<n>
#   rotate.sh LOGFILE KEEP rotates LOGFILE while a writer (pid in LOGFILE.pid) appends to it
# Exits 0 when every check passes, 1 otherwise. Works on Linux and with macOS's bash 3.2.

set -u

dir=${1:-}
failed=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; echo "      $2"; failed=1; }

if [ -z "$dir" ] || [ ! -f "$dir/monitor.sh" ] || [ ! -f "$dir/rotate.sh" ]; then
  echo "usage: bash gate/run.sh FOLDER   (FOLDER must contain monitor.sh and rotate.sh)"
  exit 1
fi
dir=$(cd "$dir" && pwd -P)
work=$(mktemp -d)
trap 'kill "$writer" 2>/dev/null; rm -rf "$work"' EXIT
writer=""

# ---------------------------------------------------------------- the monitor
# What the system reports, computed the same way the lessons do.
truth() {
  case "$(uname -s)" in
    Linux)
      load=$(cut -d' ' -f1 /proc/loadavg)
      mem=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%d", (t-a)*100/t}' /proc/meminfo)
      ;;
    Darwin)
      load=$(sysctl -n vm.loadavg | awk '{print $2}')
      total=$(sysctl -n hw.memsize)
      mem=$(vm_stat | awk -v total="$total" '/page size of/ {ps=$8}
        /^Pages free:/ {f=$3} /^Pages inactive:/ {i=$3} /^Pages speculative:/ {s=$3}
        END {printf "%d", (total-(f+i+s)*ps)*100/total}')
      ;;
  esac
  disk=$(df -P / | awk 'NR==2 {sub(/%/, "", $5); print $5}')
}

out=$(bash "$dir/monitor.sh" 2>&1)
truth
if ! echo "$out" | grep -Eqx 'load1=[0-9]+(\.[0-9]+)? mem_used_pct=[0-9]+ disk_used_pct=[0-9]+'; then
  fail "monitor.sh prints one line in the agreed format" "expected 'load1=0.52 mem_used_pct=41 disk_used_pct=63', got: $out"
else
  got_load=${out#load1=}
  got_load=${got_load%% *}
  got_mem=${out#*mem_used_pct=}
  got_mem=${got_mem%% *}
  got_disk=${out#*disk_used_pct=}
  if awk -v a="$got_load" -v b="$load" 'BEGIN {d=a-b; if (d<0) d=-d; exit !(d<=0.5)}'; then
    pass "monitor.sh: load $got_load (system: $load)"
  else
    fail "monitor.sh: load" "you printed $got_load; the system reports $load"
  fi
  if awk -v a="$got_mem" -v b="$mem" 'BEGIN {d=a-b; if (d<0) d=-d; exit !(d<=3)}'; then
    pass "monitor.sh: memory $got_mem% (system: $mem%)"
  else
    fail "monitor.sh: memory" "you printed $got_mem%; the system reports $mem% in use (total minus available)"
  fi
  if awk -v a="$got_disk" -v b="$disk" 'BEGIN {d=a-b; if (d<0) d=-d; exit !(d<=1)}'; then
    pass "monitor.sh: disk $got_disk% (system: $disk%)"
  else
    fail "monitor.sh: disk" "you printed $got_disk%; df reports $disk% for /"
  fi
fi

# ---------------------------------------------------------------- the rotator
# The gate's own writer: appends "line N" as fast as it can, reopens on SIGHUP.
cat > "$work/writer.sh" <<'WRITER'
#!/usr/bin/env bash
log=$1
echo $$ > "$log.pid"
exec 3>>"$log"
trap 'exec 3>>"$log"' HUP
trap 'echo "$written" > "$log.last"; exit 0' TERM
n=0
written=0
while :; do
  n=$((n + 1))
  echo "line $n" >&3
  written=$n
done
WRITER

# run_rotations KEEP: start the writer, rotate 10 times, stop the writer.
run_rotations() {
  local keep=$1 i
  rm -rf "$work/logs" && mkdir "$work/logs"
  bash "$work/writer.sh" "$work/logs/app.log" &
  writer=$!
  sleep 0.3
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! (cd "$work/logs" && bash "$dir/rotate.sh" app.log "$keep") > "$work/rotate.out" 2>&1; then
      kill "$writer" 2>/dev/null
      wait "$writer" 2>/dev/null
      echo "rotation $i failed: $(cat "$work/rotate.out")"
      return 1
    fi
    sleep 0.2
  done
  kill -TERM "$writer"
  wait "$writer" 2>/dev/null
  writer=""
}

# count: lines written, lost and repeated across app.log and its copies.
# With some copies deleted (KEEP small), only gaps after the oldest kept line count as lost.
count() {
  local f
  for f in "$work/logs/app.log" "$work/logs/app.log".[0-9]*; do
    [ -e "$f" ] || continue
    case "$f" in
      *.gz) gzip -dc "$f" ;;
      *) cat "$f" ;;
    esac
  done | awk -v last="$(cat "$work/logs/app.log.last")" '
    { seen[$2]++; if (min == "" || $2 < min) min = $2 }
    END {
      for (i = min; i <= last; i++) {
        if (!(i in seen)) lost++
        else if (seen[i] > 1) rep += seen[i] - 1
      }
      printf "%d %d %d %d\n", last, min, lost, rep
    }'
}

if msg=$(run_rotations 20); then
  read -r last first lost rep <<< "$(count)"
  if [ "$first" = 1 ] && [ "$lost" = 0 ] && [ "$rep" = 0 ]; then
    pass "rotate.sh, 10 rotations, keep 20: all $last lines kept, none lost or repeated"
  else
    fail "rotate.sh, 10 rotations, keep 20: no line lost or repeated" "of $last lines written: $lost lost, $rep repeated, first kept line $first"
  fi
else
  fail "rotate.sh runs" "$msg"
fi

if msg=$(run_rotations 3); then
  copies=""
  for f in "$work"/logs/app.log.[0-9]*; do
    [ -e "$f" ] && copies="$copies${f##*/} "
  done
  read -r last first lost rep <<< "$(count)"
  if [ "$copies" = "app.log.1 app.log.2.gz app.log.3.gz " ] && [ "$lost" = 0 ] && [ "$rep" = 0 ]; then
    pass "rotate.sh, 10 rotations, keep 3: exactly app.log.1, app.log.2.gz, app.log.3.gz, with no gaps"
  else
    fail "rotate.sh, 10 rotations, keep 3" "copies kept: ${copies:-none}(want app.log.1 app.log.2.gz app.log.3.gz); lines from $first to $last: $lost lost, $rep repeated"
  fi
else
  fail "rotate.sh runs" "$msg"
fi

# ---------------------------------------------------------------- shellcheck
if command -v shellcheck >/dev/null 2>&1; then
  if sc=$(shellcheck "$dir/monitor.sh" "$dir/rotate.sh" 2>&1); then
    pass "shellcheck: no warnings"
  else
    fail "shellcheck: no warnings" "$(echo "$sc" | head -20)"
  fi
else
  fail "shellcheck is installed" "install it: sudo apt install -y shellcheck (Linux) or brew install shellcheck (macOS)"
fi

if [ "$failed" -eq 0 ]; then
  echo "Gate passed: on to Foundations 03."
else
  echo "Gate failed: fix the FAIL lines above and run it again."
fi
exit "$failed"
