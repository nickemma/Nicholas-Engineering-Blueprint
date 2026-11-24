#!/usr/bin/env bash
# Rotate a log that a program is still writing to, without losing a line.
#   ./rotate.sh LOGFILE KEEP
# Keeps KEEP old copies: LOGFILE.1 (the newest, not yet compressed),
# then LOGFILE.2.gz ... LOGFILE.KEEP.gz. The writer's process ID is in LOGFILE.pid.
set -euo pipefail

log=${1:?usage: rotate.sh LOGFILE KEEP}
keep=${2:?usage: rotate.sh LOGFILE KEEP}
pid=$(cat "$log.pid")

# 1. Make room: drop the oldest copy, and move each compressed copy up one.
rm -f $log.$keep.gz
for ((i = keep - 1; i >= 2; i--)); do
  if [[ -f "$log.$i.gz" ]]; then
    mv "$log.$i.gz" "$log.$((i + 1)).gz"
  fi
done

# 2. Compress last time's copy. The writer let go of it long ago.
if [[ -f "$log.1" ]]; then
  if ((keep >= 2)); then
    gzip -c "$log.1" > "$log.2.gz"
  fi
  rm "$log.1"
fi

# 3. Rename the live log. The writer keeps writing to it under its new name.
mv "$log" "$log.1"

# 4. Ask the writer to reopen the log by name, which creates a new, empty one.
kill -HUP "$pid"

# 5. Wait until it has, so the next rotation never compresses a file still in use.
for _ in $(seq 50); do
  [[ -e "$log" ]] && exit 0
  sleep 0.1
done
echo "rotate.sh: the writer (pid $pid) didn't reopen $log within 5 seconds" >&2
exit 1
