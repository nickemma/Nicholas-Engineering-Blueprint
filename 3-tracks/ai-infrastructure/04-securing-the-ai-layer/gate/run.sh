#!/usr/bin/env bash
# Gate for AI 04 Securing the AI layer.
# Usage: bash gate/run.sh LAB_DIR   (the AI 02 lab directory, now holding serve/ and tools/)
set -euo pipefail
cd "${1:-.}"
lab=$PWD
if [[ ! -d serve || ! -d tools ]]; then echo "expected serve/ and tools/ in $lab" >&2; exit 2; fi

echo "== serve: format, lint, every test (the adversarial suite runs against the scripted model)"
(cd serve && uv sync --locked -q && uv run --locked ruff format --check . && uv run --locked ruff check . && uv run --locked pytest -q tests/)

echo "== tools: format, vet, race tests"
(cd tools && unformatted=$(gofmt -l .) && if [[ -n $unformatted ]]; then echo "not gofmt-formatted: $unformatted" >&2; exit 1; fi && go vet ./... && go test -race -count=1 ./...)

# Negative controls: remove one defence at a time in a disposable copy. Each
# removal must be caught by the named test; a defence no test notices is a
# defence the next refactor can delete.
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
    echo "removing '$name' was not caught by $test_name" >&2
    exit 1
  fi
  echo "negative control: without $name -> caught by $test_name"
}
python_copy() {
  rm -rf "$work/serve"
  mkdir -p "$work/serve"
  cp -R serve/pyproject.toml serve/uv.lock serve/src serve/tests "$work/serve/"
  return 0
}
# The copy reuses the lab's environment, where serve is installed in editable
# mode; PYTHONPATH puts the copy's source first so the change is imported.
pytest_copy() { (cd "$work/serve" && PYTHONPATH="$work/serve/src" UV_PROJECT_ENVIRONMENT="$lab/serve/.venv" uv run --locked --no-sync pytest -q -p no:cacheprovider "$@"); }

python_copy
plant "$work/serve/src/serve/agent.py" 'if name in CHANGES:' 'if name in CHANGES and False:'
expect_fail "approval before a change" test_changes_wait_for_approval pytest_copy tests/test_agent.py

python_copy
plant "$work/serve/src/serve/web.py" 'html.escape(answer)' 'answer'
expect_fail "escaping the model's answer" test_answer_is_shown_as_text pytest_copy tests/test_web.py

python_copy
plant "$work/serve/src/serve/agent.py" 'parts = [user.tenant, MODEL, question.strip().lower()]' 'parts = [MODEL, question.strip().lower()]'
expect_fail "the tenant in the cache key" test_cache_keys_belong_to_one_tenant pytest_copy tests/test_leaks.py

python_copy
plant "$work/serve/src/serve/agent.py" 'if leaks_canary(text):' 'if False:'
expect_fail "the canary check" test_canary_in_a_reply_stops_it pytest_copy tests/test_secrets.py

python_copy
plant "$work/serve/src/serve/release.py" 'raise Refused("bad signature") from exc' 'pass'
expect_fail "the release signature check" test_another_key_or_an_unapproved_release_is_refused pytest_copy tests/test_release.py

rm -rf "$work/tools"
cp -R tools "$work/tools"
plant "$work/tools/internal/toolsrv/server.go" 'err != nil || job.Tenant != who.Tenant {' 'err != nil || job.Tenant == "" {'
expect_fail "the tenant check on every tool call" TestNoConfusedDeputy \
  bash -c "cd '$work/tools' && go test -count=1 -run 'TestNoConfusedDeputy' ./internal/toolsrv/"

echo "gate passed"
