#!/usr/bin/env bash
set -euo pipefail
gate=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-.}"
test -z "$(gofmt -l .)"
go vet ./...
go test -race -count=1 -v ./...
if [[ "${SWITCHYARD_MESSAGING_LIVE:-0}" != 1 ]]; then
  exit 0
fi
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
go build -buildvcs=false -race -o "$work/reference" ./cmd/messages
python3 "$gate/live.py" "$work/reference"
mkdir "$work/negative"
cp -R cmd internal go.mod go.sum "$work/negative/"
python3 - "$work/negative/cmd/messages/main.go" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
needle = "result, reason := w.Handle(child, d.Body)"
assert s.count(needle) == 1
p.write_text(s.replace(needle, "if *crash { if err := d.Ack(false); err != nil { return err } }\n\t\t\t\t" + needle))
PY
(cd "$work/negative" && go build -buildvcs=false -race -o "$work/early" ./cmd/messages)
result=0
python3 "$gate/live.py" "$work/early" --crash-only || result=$?
test "$result" = 42
echo 'negative control: caught premature acknowledgment'
