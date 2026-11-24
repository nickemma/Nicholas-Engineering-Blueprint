#!/usr/bin/env bash
set -euo pipefail

gate=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$gate/../../../.." && pwd)
learner=$(cd "${1:?provide a replayed learner workspace}" && pwd)
output=${2:?provide a new archive path}
test ! -e "$output"
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
project="$temp/switchyard-kv-capstone"
mkdir -p "$project"/{lab,gate,storage/klog,klog}

for item in go.mod go.sum cmd internal bench README.md ADR.md .gitignore; do
    cp -R "$learner/$item" "$project/"
done
for item in Cargo.toml Cargo.lock src; do
    cp -R "$learner/klog/$item" "$project/klog/"
    cp -R "$learner/storage/$item" "$project/storage/"
    cp -R "$learner/storage/klog/$item" "$project/storage/klog/"
done
cp "$learner"/lab/{capstone.py,benchmark.py,serve.py,launch.sh} "$project/lab/"
cp "$repo/2-core/07-distributed-systems-fundamentals/gate/verify.py" "$project/lab/"
cp "$gate/run.sh" "$project/gate/"
cp -R "$gate/../evidence" "$project/evidence"
find "$project/evidence" -maxdepth 1 -name 'switchyard-kv-capstone*.tar.gz' -delete
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
    -C "$temp" -czf "$output" switchyard-kv-capstone
