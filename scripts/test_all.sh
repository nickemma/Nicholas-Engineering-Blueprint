#!/usr/bin/env bash
# Run every check CI runs: lesson code blocks match their step files, and every
# Go module under lessons/ and dsa/ is formatted, vetted, and passes its tests.
#
# Usage, from the repository root:  bash scripts/test_all.sh

set -euo pipefail

cd "$(dirname "$0")/.."

echo "== lesson code blocks"
python3 scripts/check_teaching.py

failed=0
while IFS= read -r modfile; do
  dir="$(dirname "$modfile")"
  echo "== $dir"
  unformatted="$(cd "$dir" && gofmt -l .)"
  if [[ -n "$unformatted" ]]; then
    echo "not gofmt-formatted: $unformatted"
    failed=1
    continue
  fi
  if ! (cd "$dir" && go vet ./... && go test -race -count=1 ./...); then
    failed=1
  fi
done < <(find lessons dsa -name go.mod -not -path '*/practice/*' 2>/dev/null | sort)

exit "$failed"
