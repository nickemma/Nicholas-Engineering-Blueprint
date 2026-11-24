#!/usr/bin/env bash
set -euo pipefail

cd "${1:-.}"
workspace="$PWD"
case "${2:-portable}" in
    profile) exec bash bench/profile.sh "${3:?profile output directory required}" ;;
    portable) ;;
    *) echo 'usage: run.sh [learner directory [portable|profile [output]]]' >&2; exit 2 ;;
esac
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

cargo fmt --check
cargo clippy --locked --all-targets --all-features --target-dir target -- -D warnings
cargo test --locked --target-dir target
cargo build --locked --target-dir target
test -z "$(gofmt -l bench cmd control)"
go vet ./...
python3 -m py_compile bench/run.py
bash -n bench/profile.sh
env -u EDGE_RELOAD_REPORT EDGE_BIN="$workspace/target/debug/switchyard-edge" go test -race -count=1 -v ./control
python3 lab/check.py "$workspace/target/debug/switchyard-edge" routing pool capacity breaker

mkdir "$scratch/mutation"
cp -r Cargo.lock Cargo.toml src "$scratch/mutation/"
python3 - "$scratch/mutation/src/http.rs" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = '''        let origin = match parts.uri.path().split('/').nth(1) {
            Some("a") => &self.origins[self.routes.origin_for(0)],
            Some("b") => &self.origins[self.routes.origin_for(1)],
            _ => return reply(StatusCode::NOT_FOUND, "no route"),
        };'''
new = '''        let route = match parts.uri.path().split('/').nth(1) {
            Some("a") => 0,
            Some("b") => 1,
            _ => return reply(StatusCode::NOT_FOUND, "no route"),
        };
        let selected = self.routes.origin_for(route);
        let origin = &self.origins[selected];'''
before = '        match outcome {'
after = '''        if self.routes.origin_for(route) != selected {
            return reply(StatusCode::SERVICE_UNAVAILABLE, "route changed in flight");
        }
        match outcome {'''
for left, right in [(old, new), (before, after)]:
    if source.count(left) != 1:
        raise SystemExit("continuity control expects one matching source region")
    source = source.replace(left, right, 1)
path.write_text(source)
PY
(cd "$scratch/mutation" && cargo build --quiet --locked --target-dir "$scratch/target")
if EDGE_BIN="$scratch/target/debug/switchyard-edge" go test ./control -run '^TestCapstoneHandoff$' -count=1 >"$scratch/failure" 2>&1; then
    echo "gate failed: interrupted held request passed continuity assertion" >&2
    exit 1
fi
if ! grep -F 'held request interrupted at publication: unexpected HTTP result: HTTP/1.1 status 503' "$scratch/failure"; then
    cat "$scratch/failure" >&2
    exit 1
fi
echo "edge proxy capstone gate passed"
