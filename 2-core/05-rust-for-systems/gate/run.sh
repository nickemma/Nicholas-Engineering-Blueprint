#!/usr/bin/env bash
set -euo pipefail
cd "${1:-.}"

cargo fmt --check
cargo clippy --quiet --all-targets -- -D warnings
cargo test --quiet
cargo test --quiet --test transport -- --nocapture
printf '%s\n' 'native parser, FFI, executor, and ring checks passed'

extended=${SWITCHYARD_C05_EXTENDED:-0}
if [[ "${2:-}" == --extended ]]; then
  extended=1
fi
if [[ "$extended" == 1 || "${SWITCHYARD_C05_INTEGRATIONS:-0}" == 1 ]]; then
  bash scripts/check-integrations.sh
fi
if [[ "$extended" == 1 ]]; then
  for check in miri tsan asan fuzz; do
    printf '\n--- %s ---\n' "$check"
    bash scripts/check-nightly.sh "$check"
  done
fi
