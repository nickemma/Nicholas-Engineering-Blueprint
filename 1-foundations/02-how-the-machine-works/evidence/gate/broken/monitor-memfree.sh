#!/usr/bin/env bash
# Print one line: the 1-minute load average, the percentage of memory in use,
# and the percentage of the disk in use under PATH (default /).
#   ./monitor.sh [PATH]
#   load1=0.52 mem_used_pct=41 disk_used_pct=63
set -euo pipefail

path=${1:-/}

load1() {
  case "$(uname -s)" in
    Linux) cut -d' ' -f1 /proc/loadavg ;;
    Darwin) sysctl -n vm.loadavg | awk '{print $2}' ;;  # "{ 0.52 0.61 0.70 }"
  esac
}

mem_used_pct() {
  case "$(uname -s)" in
    Linux)
      # MemAvailable: what programs could still use without swapping.
      awk '/^MemTotal:/ {t=$2} /^MemFree:/ {a=$2} END {printf "%d\n", (t-a)*100/t}' /proc/meminfo
      ;;
    Darwin)
      # Free, inactive and speculative pages can be handed to programs.
      total=$(sysctl -n hw.memsize)
      vm_stat | awk -v total="$total" '
        /page size of/ {ps=$8}
        /^Pages free:/ {f=$3} /^Pages inactive:/ {i=$3} /^Pages speculative:/ {s=$3}
        END {avail=(f+i+s)*ps; printf "%d\n", (total-avail)*100/total}'
      ;;
  esac
}

disk_used_pct() {
  # -P: one line per file system, the same columns on Linux and macOS.
  df -P "$path" | awk 'NR==2 {sub(/%/, "", $5); print $5}'
}

echo "load1=$(load1) mem_used_pct=$(mem_used_pct) disk_used_pct=$(disk_used_pct)"
