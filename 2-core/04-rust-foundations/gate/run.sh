#!/usr/bin/env bash
set -euo pipefail

gate=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-.}"
cargo fmt --check
cargo clippy --quiet --all-targets -- -D warnings
cargo test --quiet
cargo build --quiet --bin klog
target=$(cargo metadata --no-deps --format-version 1 |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')
python3 "$gate/verify.py" "$target/debug/klog"
