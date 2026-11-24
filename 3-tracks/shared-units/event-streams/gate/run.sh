#!/usr/bin/env bash
set -euo pipefail
gate=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-.}"
test -z "$(gofmt -l .)"
go vet ./...
go test -race -count=1 -v ./...
if [[ "${SWITCHYARD_STREAMS_LIVE:-0}" != 1 ]]; then
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
go build -buildvcs=false -race -o "$work/reference" ./cmd/streams
mkdir "$work/negative"
cp -R cmd internal go.mod go.sum "$work/negative/"
# The variant still claims the inbox row but treats every duplicate as a
# newly claimed row. The record is counted twice at its separate offsets.
python3 - "$work/negative/internal/store/project.go" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
target = "ON CONFLICT (projection, event_id) DO NOTHING"
assert text.count(target) == 1
path.write_text(text.replace(target, "ON CONFLICT (projection, event_id) DO UPDATE SET job_id = EXCLUDED.job_id"))
PY
(cd "$work/negative" && go build -buildvcs=false -race -o "$work/without-dedup" ./cmd/streams)
python3 -E "$gate/live.py" "$work/reference" "$work/without-dedup"
