#!/usr/bin/env bash
# Five runs each of Switchyard's plain build, the same build again, and its
# race-detector build, in a random order, one Switchyard at a time, after one
# warm-up run that isn't kept.
#
#   bash experiments/builds.sh ~/blueprint/switchyard/bin results/builds
set -eu
bin=$1
out=$2
rm -rf "$out"
mkdir -p "$out/plain" "$out/plain-again" "$out/race"
order=$(uv run python -c '
import random
runs = [f"{build} {n}" for n in range(1, 6) for build in ("plain", "race", "plain-again")]
print("\n".join(runs))')
echo "order: $(echo "$order" | tr '\n' ',' | sed 's/,$//')"
while read -r build n; do
  exe=$bin/switchyard
  [ "$build" = race ] && exe=$bin/switchyard-race
  "$exe" > /dev/null 2>&1 &
  server=$!
  sleep 0.5
  csv=$out/$build/run$n.csv
  [ "$build" = warm-up ] && csv=$out/warm-up.csv
  status=0
  uv run kload load --rate 1000 --duration 3 --out "$csv" > /dev/null < /dev/null || status=$?
  kill "$server"
  wait "$server" || true
  if [ $status != 0 ]; then
    echo "run '$build $n': kload exited with $status, so this experiment's numbers can't be trusted" >&2
    exit 1
  fi
done <<< "$order"
