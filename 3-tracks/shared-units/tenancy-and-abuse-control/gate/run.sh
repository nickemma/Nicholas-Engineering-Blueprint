#!/usr/bin/env bash
set -euo pipefail
gate=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-.}"
test -z "$(gofmt -l .)"
go vet ./...
go test -race -count=1 -v ./...

if [[ "${SWITCHYARD_TENANCY_LIVE:-0}" == 1 ]]; then
  python3 -E "$gate/live.py" "$PWD/db/schema.sql"
fi
