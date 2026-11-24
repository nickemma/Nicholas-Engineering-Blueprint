#!/usr/bin/env bash
set -euo pipefail
gate=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${1:-.}"
test -z "$(gofmt -l .)"
go vet ./...
go test -race -count=1 -v ./...

if [[ "${SWITCHYARD_CACHING_LIVE:-0}" != 1 ]]; then
  exit 0
fi

python3 -E "$gate/live.py"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp -R internal go.mod go.sum "$work/"
python3 -E - "$work/internal/cache/read.go" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
target = "r.loads.DoChan(id, func()"
assert source.count(target) == 1
path.write_text(source.replace(target, "withoutSharing(func()"))
PY
cat > "$work/internal/cache/no_sharing.go" <<'GO'
package cache

import "golang.org/x/sync/singleflight"

func withoutSharing(fn func() (any, error)) <-chan singleflight.Result {
	result := make(chan singleflight.Result, 1)
	go func() {
		value, err := fn()
		result <- singleflight.Result{Val: value, Err: err}
	}()
	return result
}
GO
result=0
(cd "$work" && go test -race -count=1 -run '^TestColdBurst$' -v ./internal/cache) > "$work/output" 2>&1 || result=$?
cat "$work/output"
test "$result" = 1
grep -Fq 'stampede: origin reads = 32, want 1' "$work/output"
echo 'negative control: removing singleflight restored the stampede'
