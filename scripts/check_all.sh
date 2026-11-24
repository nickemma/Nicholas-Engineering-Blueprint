#!/usr/bin/env bash
# Run every check CI runs: every lesson guide is rebuilt from its own code
# blocks and its checks pass, and every Go module, Python project and Rust
# crate under dsa/ is formatted, linted, and passes its tests.
#
# Usage, from the repository root:  bash scripts/check_all.sh

set -euo pipefail

cd "$(dirname "$0")/.."

failed=0

echo "== lesson guides"
python3 scripts/replay_lessons.py || failed=1

echo "== links"
python3 scripts/check_links.py || failed=1

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
done < <(find dsa -name go.mod -not -path '*/practice/*' | sort)

while IFS= read -r pyproject; do
  dir="$(dirname "$pyproject")"
  echo "== $dir"
  if ! (cd "$dir" && uv run --locked ruff format --check -q . && uv run --locked ruff check -q . \
        && uv run --locked pytest -q); then
    failed=1
  fi
done < <(find dsa -name pyproject.toml -not -path '*/practice/*' -not -path '*/.venv/*' | sort)

while IFS= read -r cargo; do
  dir="$(dirname "$cargo")"
  echo "== $dir"
  if ! (cd "$dir" && cargo fmt --check && cargo clippy -q --all-targets -- -D warnings && cargo test -q); then
    failed=1
  fi
done < <(find dsa -name Cargo.toml -not -path '*/practice/*' -not -path '*/target/*' | sort)

exit "$failed"
