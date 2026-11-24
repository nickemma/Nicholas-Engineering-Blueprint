#!/usr/bin/env bash
set -euo pipefail
cd "${1:-.}"
cargo fmt --all -- --check
cargo clippy --locked --features profiling --all-targets -- -D warnings
cargo test --locked
cargo test --locked --features eager-json
python3 -m unittest discover -s bench -v
if [[ "${SWITCHYARD_CAPSTONE_LIVE:-0}" == 1 ]]; then
  cargo test --locked --test loopback -- --ignored --nocapture
  cargo test --locked --features eager-json --test loopback -- --ignored --nocapture
fi
