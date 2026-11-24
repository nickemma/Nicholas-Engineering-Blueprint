#!/usr/bin/env bash
set -euo pipefail
gate=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-.}"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cargo build --quiet --manifest-path klog/Cargo.toml --target-dir "$work/rust" --bin metad-wal
ln -s "$work/rust/debug/metad-wal" "$work/metad-wal"
go build -buildvcs=false -race -o "$work/metad" ./cmd/metad
go build -buildvcs=false -race -o "$work/gateway" ./cmd/ship-gateway
go build -buildvcs=false -race -o "$work/probe" ./cmd/ship-probe
python3 "$gate/verify.py" "$PWD" "$work"

# Drop failed observations in a disposable build and require the exact gate failure.
python3 - "$PWD/internal/sli/window.go" "$work" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
work = Path(sys.argv[2])
needle = "func (w *Window) Observe(good bool) State {"
text = source.read_text()
assert text.count(needle) == 1
overlay = work / "window.go"
overlay.write_text(text.replace(needle, needle + "\n\tif !good { return State{Total: w.total, Good: w.good} }"))
(work / "overlay.json").write_text(json.dumps({"Replace": {str(source): str(overlay)}}))
PY
go build -buildvcs=false -race -overlay "$work/overlay.json" -o "$work/broken-probe" ./cmd/ship-probe
result=0
python3 "$gate/verify.py" "$PWD" "$work" --broken || result=$?
if [[ "$result" != 42 ]]; then
  echo "expected the dropped-failure variant to exit 42, got $result" >&2
  exit 1
fi
echo "negative control: caught the probe that dropped failed attempts"
