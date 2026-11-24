#!/usr/bin/env bash
set -euo pipefail
gate=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-.}"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
bash ops/check-c.sh

cargo fmt --check
cargo clippy --offline --quiet --target-dir "$work/rust" --all-targets -- -D warnings
cargo test --offline --quiet --target-dir "$work/rust"
make --no-print-directory -s BUILD="$work/ordinary" RUST_BUILD="$work/rust" link-rust
python3 "$gate/verify.py" "$work/rust/debug/rust_reads_c" "$work/ordinary/c_reads_rust"

# Isolate the arithmetic-only regression to Rust's copy of the C archive.
variant="$work/variant"
mkdir -- "$variant"
cp -R -- Cargo.toml build.rs include c src "$variant"
python3 - "$variant/c/byte_view.c" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()
needle = "        sum ^= in.data[i];"
assert s.count(needle) == 1
p.write_text(s.replace(needle, "        if (in.data[i] == 0) { continue; }\n" + needle))
PY
cargo build --offline --quiet --manifest-path "$variant/Cargo.toml" --target-dir "$work/broken"
result=0
python3 "$gate/verify.py" "$work/broken/debug/rust_reads_c" "$work/ordinary/c_reads_rust" || result=$?
if [[ "$result" != 42 ]]; then
  echo "expected the changed checksum to fail with exit 42, got $result" >&2
  exit 1
fi
echo "negative control: caught a checksum that dropped an embedded zero"
