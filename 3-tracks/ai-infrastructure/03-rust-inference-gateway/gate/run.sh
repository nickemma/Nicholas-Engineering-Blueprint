#!/usr/bin/env bash
set -euo pipefail
gate=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-.}"

cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked -- --nocapture
target=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "${CARGO_TARGET_DIR:-target}")

if [[ "${SWITCHYARD_GATEWAY_LIVE:-0}" == 1 ]]; then
  cargo test --locked --test loopback -- --ignored --nocapture
  cargo build --locked --bin switchyard-inference
  python3 -E "$gate/fixture.py" "$target/debug/switchyard-inference"
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp -R Cargo.toml Cargo.lock src "$work/"
python3 -E - "$work/src/sse.rs" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
target = r"self.data.push('\n');"
assert text.count(target) == 1
path.write_text(text.replace(target, "self.data.push(' ');"))
PY
result=0
cargo test --locked --manifest-path "$work/Cargo.toml" --target-dir "$target" --lib \
  sse::tests::preserves_multiline_data_across_every_byte -- --exact > "$work/output" 2>&1 || result=$?
cat "$work/output"
test "$result" = 101
grep -Fq 'joined data must preserve LF' "$work/output"
echo 'negative control: replacing the data-line newline changed the event'
