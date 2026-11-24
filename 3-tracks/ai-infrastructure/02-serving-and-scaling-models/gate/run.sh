#!/usr/bin/env bash
# Gate for AI 02 Serving and scaling models.
# Usage: bash gate/run.sh LAB_DIR   (the directory holding serve/ and gateway/)
set -euo pipefail
cd "${1:-.}"
lab=$PWD
if [[ ! -d serve || ! -d gateway ]]; then echo "expected serve/ and gateway/ in $lab" >&2; exit 2; fi

echo "== serve: format, lint, tests"
(cd serve && uv sync --locked -q && uv run --locked ruff format --check . && uv run --locked ruff check . && uv run --locked pytest -q)

echo "== gateway: format, vet, race tests"
(cd gateway && unformatted=$(gofmt -l .) && if [[ -n $unformatted ]]; then echo "not gofmt-formatted: $unformatted" >&2; exit 1; fi && go vet ./... && go test -race -timeout=60s -count=1 ./...)

echo "== data parallelism: two processes match the serial reference"
out=$(cd serve && uv run --locked python -m torch.distributed.run --standalone --nproc-per-node=2 -m serve.ddp 2>&1)
echo "$out" | grep -F '"serial_parity": true' || { echo "$out"; echo "two-process training did not report serial parity" >&2; exit 1; }

# Negative controls: plant one bug at a time in a disposable copy. Each must be
# caught by the named test, or the tests aren't checking what they claim.
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
plant() { # plant FILE OLD NEW: replace OLD (which must appear exactly once)
  python3 -E - "$@" <<'PY'
import sys
from pathlib import Path
path, old, new = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
if text.count(old) != 1:
    sys.exit(f"negative control: expected the guide's line once in {path}: {old!r}")
path.write_text(text.replace(old, new))
PY
}
expect_fail() { # expect_fail NAME TEST_NAME COMMAND...
  local name=$1 test_name=$2; shift 2
  local result=0
  "$@" > "$work/output" 2>&1 || result=$?
  if [[ $result == 0 ]] || ! grep -Fq "$test_name" "$work/output"; then
    cat "$work/output"
    echo "negative control '$name' was not caught by $test_name" >&2
    exit 1
  fi
  echo "negative control: $name -> caught by $test_name"
}
python_copy() {
  rm -rf "$work/serve"
  mkdir -p "$work/serve"
  cp -R serve/pyproject.toml serve/uv.lock serve/src serve/tests "$work/serve/"
  [[ -f serve/.python-version ]] && cp serve/.python-version "$work/serve/"
  return 0
}
# The copy reuses the lab's environment, where serve is installed in editable
# mode; PYTHONPATH puts the copy's source first so the planted bug is imported.
pytest_copy() { (cd "$work/serve" && PYTHONPATH="$work/serve/src" UV_PROJECT_ENVIRONMENT="$lab/serve/.venv" uv run --locked --no-sync pytest -q -p no:cacheprovider "$@"); }

python_copy
plant "$work/serve/src/serve/tiny.py" 'scores = scores.masked_fill(~allowed, float("-inf"))' 'scores = scores'
expect_fail "attention sees the future" test_a_token_cannot_see_the_future pytest_copy tests/test_tiny.py

python_copy
plant "$work/serve/src/serve/stream.py" 'if not done or result.ttft is None:' 'if result.ttft is None:'
expect_fail "a truncated stream counts as success" test_usage_is_not_chunk_count_and_truncated_stream_is_failure pytest_copy tests/test_stream.py

python_copy
plant "$work/serve/src/serve/score.py" 'n, p, z = len(rows), len(good) / len(rows), 1.645' 'n, p, z = len(valid), len(good) / len(valid), 1.645'
expect_fail "failed requests leave the denominator" test_failures_stay_in_denominator_and_unknown_tokens_cannot_pass pytest_copy tests/test_score.py

rm -rf "$work/gateway"
cp -R gateway "$work/gateway"
plant "$work/gateway/internal/inference/gateway.go" 'defer func() { <-g.active }()' '// the slot is never released'
expect_fail "a finished request keeps its slot" TestDisconnectCancelsUpstreamAndReleasesSlot \
  bash -c "cd '$work/gateway' && go test -timeout=60s -count=1 -run 'TestDisconnectCancelsUpstreamAndReleasesSlot' ./internal/inference/"

echo "gate passed"
