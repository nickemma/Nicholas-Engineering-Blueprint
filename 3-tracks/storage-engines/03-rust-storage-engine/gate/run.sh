#!/usr/bin/env bash
set -euo pipefail

cd "${1:-.}"
cargo fmt --check
cargo clippy --quiet --offline --locked --all-targets --all-features -- -D warnings
cargo test --offline --locked --quiet -- --nocapture
cargo build --offline --locked --quiet --features fault-injection
target=$(cargo metadata --offline --locked --no-deps --format-version 1 |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')
python3 -B lab/crash.py "$target/debug/lsm"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/klog"
cp -r Cargo.toml Cargo.lock src tests "$scratch/"
cp -r klog/Cargo.toml klog/src "$scratch/klog/"
python3 - "$scratch/src/compact.rs" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
code = source.read_text()
original = "let horizon = self.pins.oldest().unwrap_or(self.seq);"
assert code.count(original) == 1
source.write_text(code.replace(original, "let horizon = self.seq;", 1))
PY
status=0
(
    cd "$scratch"
    CARGO_TARGET_DIR="$scratch/target" cargo test --quiet --offline --locked --test mvcc \
        compaction_keeps_every_pinned_view -- --nocapture
) >"$scratch/variant.txt" 2>&1 || status=$?
if [[ "$status" != 101 ]] || ! grep -q 'pinned snapshot changed during compaction' "$scratch/variant.txt"; then
    cat "$scratch/variant.txt" >&2
    echo "expected newest-only compaction to fail the pinned-read check" >&2
    exit 1
fi
echo "negative control: newest-only compaction changed a pinned read"
