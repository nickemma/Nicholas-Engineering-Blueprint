#!/usr/bin/env bash
set -euo pipefail

gate=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-.}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mode=${2:-}
features=()
if [[ -z "$mode" ]]; then
    features=(--features fault-injection)
elif [[ "$mode" != smoke && "$mode" != leases ]]; then
    echo 'usage: run.sh [learner directory [smoke|leases]]' >&2
    exit 2
fi
cargo build --quiet --manifest-path klog/Cargo.toml --target-dir "$work/rust" --bins "${features[@]}"
writer="$work/rust/debug/metad-wal"
klog="$work/rust/debug/klog"
go build -buildvcs=false -race -o "$work/metad" ./cmd/metad
if [[ -n "$mode" ]]; then
    python3 "$gate/verify.py" "$work/metad" "$writer" "$klog" --only "$mode"
    exit 0
fi
python3 "$gate/verify.py" "$work/metad" "$writer" "$klog"

# Change just the acknowledgment boundary in an overlay. Keep the learner's
# source untouched and require the specific minority-ack failure.
python3 - "$PWD/internal/metad/runtime.go" "$work" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
work = Path(sys.argv[2])
overlay = work / "runtime.go"
text = source.read_text()
needle = "\t\trole, term := r.node.Role(), r.node.Term()"
assert text.count(needle) == 1
addition = """\t\tfor index, p := range pending {
\t\t\tp.reply <- outcome{code: 200, result: Result{Found: true, Value: p.command.Value}}
\t\t\tdelete(pending, index)
\t\t}
"""
overlay.write_text(text.replace(needle, addition + needle))
(work / "overlay.json").write_text(json.dumps({"Replace": {str(source): str(overlay)}}))
PY
go build -buildvcs=false -race -overlay "$work/overlay.json" -o "$work/broken" ./cmd/metad
status=0
python3 "$gate/verify.py" "$work/broken" "$writer" "$klog" --only companion || status=$?
if [[ "$status" != 42 ]]; then
    echo "expected the early-ack variant to fail the isolation check (exit 42), got $status" >&2
    exit 1
fi
echo "negative control: caught acknowledgment before quorum commit"
