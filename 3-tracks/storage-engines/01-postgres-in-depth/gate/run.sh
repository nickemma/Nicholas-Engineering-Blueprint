#!/usr/bin/env bash
set -euo pipefail
gate=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-.}"
test -z "$(gofmt -l .)"
go vet ./...
go test -race -count=1 ./...
if [[ "${SWITCHYARD_PG_DEPTH_LIVE:-0}" == 1 ]]; then
  PYTHONPATH="$PWD" python3 -s "$gate/live.py"
fi
