#!/usr/bin/env bash
set -euo pipefail
cd "${1:-.}"
root=$PWD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

(cd wire/klog && cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings &&
  cargo test --quiet --lib data_plane::tests && cargo build --release --quiet --bin data-plane)
rust_target=$(cargo metadata --manifest-path wire/klog/Cargo.toml --no-deps --format-version 1 |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')
(cd wire/control && go vet ./internal/wire ./cmd/switchyard &&
  go test -race ./internal/wire ./cmd/switchyard &&
  go test -tags slowwire ./internal/wire &&
  go build -buildvcs=false -o "$work/fast" ./cmd/switchyard &&
  go build -buildvcs=false -tags slowwire -o "$work/slow" ./cmd/switchyard)

python3 wire/smoke.py "$rust_target/release/data-plane" "$work/fast"
python3 wire/smoke.py "$rust_target/release/data-plane" "$work/slow"

if [[ "${2:-}" == --extended || "${SWITCHYARD_C06_EXTENDED:-0}" == 1 ]]; then
  : "${WIRE_PROFILE_OUT:?set WIRE_PROFILE_OUT to a new output directory}"
  python3 "$root/wire/profile_gate.py" "$rust_target/release/data-plane" "$work/slow" "$work/fast" "$WIRE_PROFILE_OUT"
fi
