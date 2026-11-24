#!/usr/bin/env bash
# copy, then truncate: loses lines
set -euo pipefail
log=$1
keep=$2
n=1
while [[ -e "$log.$n" && $n -lt $keep ]]; do n=$((n + 1)); done
cp "$log" "$log.$n"
: > "$log"
