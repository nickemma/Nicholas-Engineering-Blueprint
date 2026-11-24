#!/usr/bin/env bash
set -euo pipefail
gate=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=$1
destination=$2
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
root=$stage/switchyard-inference-capstone
mkdir "$root"
for item in Cargo.toml Cargo.lock README.md ADR.md .gitignore src tests bench; do
  cp -R -- "$work/$item" "$root/"
done
find "$root" -type d -name __pycache__ -prune -exec rm -rf -- {} +
cp -R -- "$gate/../evidence" "$root/evidence"
test ! -e "$destination"
tar -C "$stage" -czf "$destination" switchyard-inference-capstone
