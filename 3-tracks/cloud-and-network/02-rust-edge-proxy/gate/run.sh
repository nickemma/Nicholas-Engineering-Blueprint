#!/usr/bin/env bash
set -euo pipefail

workspace="$(cd "${1:-.}" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

cd "$workspace"
cargo fmt --check
cargo clippy --locked --all-targets --target-dir target -- -D warnings
cargo test --locked --target-dir target
cargo build --locked --target-dir target
python3 lab/check.py "$workspace/target/debug/switchyard-edge" routing pool capacity breaker

verify_mutation() {
    local name="$1" expected="$2" example="$scratch/$1"
    mkdir -p "$example"
    cp Cargo.toml Cargo.lock "$example/"
    cp -r src lab "$example/"
    (
        cd "$example"
        python3 - "$name" <<'PY'
from pathlib import Path
import sys

name = sys.argv[1]
file = Path("src/http.rs")
source = file.read_text()
if name == "pool":
    edits = [(".pool_max_idle_per_host(32)", ".pool_max_idle_per_host(0)")]
else:
    edits = [(
        '''        let Some(attempt) = origin.breaker.admit(Instant::now()) else {
            return reply(StatusCode::SERVICE_UNAVAILABLE, "origin circuit open");
        };''',
        "        let attempt = origin.breaker.admit(Instant::now());",
    ), (
        "        attempt.finish(healthy, Instant::now());",
        "        if let Some(attempt) = attempt { attempt.finish(healthy, Instant::now()); }",
    )]
for before, after in edits:
    if source.count(before) != 1:
        raise SystemExit(f"expected one source match for {name}")
    source = source.replace(before, after, 1)
file.write_text(source)
PY
        cargo build --quiet --locked --target-dir "$scratch/target"
        if python3 lab/check.py "$scratch/target/debug/switchyard-edge" "$name" >failure.txt 2>&1; then
            echo "gate failed: $name mutation passed"
            exit 1
        fi
        if ! grep -E "^AssertionError: $expected$" failure.txt; then
            cat failure.txt
            echo "gate failed: $name mutation failed for the wrong reason"
            exit 1
        fi
    )
}

verify_mutation pool 'pool: 12 sockets for 12 requests'
verify_mutation breaker 'breaker: open request reached origin \(count=4\)'
echo "edge proxy gate passed"
