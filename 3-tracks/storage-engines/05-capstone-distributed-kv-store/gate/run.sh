#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ ! -f "$here/../lab/verify.py" ]]; then
    export BLUEPRINT_ROOT
    BLUEPRINT_ROOT=$(cd "$here/../../../.." && pwd)
fi
cd "${1:-.}"
mode=${2:-all}
case "$mode" in
    all|replay|recovery|benchmark|profile) ;;
    *) echo 'usage: run.sh [learner directory [all|replay|recovery|benchmark|profile]]' >&2; exit 2 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
output=${KV_EVIDENCE_DIR:-"$work/evidence"}
mkdir -p "$output"
output=$(cd "$output" && pwd)
writer_target=$(cargo metadata --manifest-path klog/Cargo.toml --locked --no-deps --format-version 1 |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')
engine_target=$(cargo metadata --manifest-path storage/Cargo.toml --locked --no-deps --format-version 1 |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')
engine="$engine_target/release/kv-project"
writer="$writer_target/release/metad-wal"
evidence="$output"

do_profile() {
    cargo build --locked --quiet --release --manifest-path storage/Cargo.toml --bin kv-project --features cpu-profile
    mkdir -p "$evidence/profile"
    for variant in range point; do
        "$engine" profile "$work/profile-$variant" "$variant" 75000 "$evidence/profile/flame-$variant.svg"
    done | tee "$evidence/profile/sample.jsonl"
    pair=0
    for variant in range point point range; do
        pair=$((pair + 1))
        "$engine" profile "$work/timing-$pair" "$variant" 75000 -
    done | tee "$evidence/profile/timing.jsonl"
    python3 - "$evidence/profile" <<'PY'
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1])
sample = [json.loads(line) for line in (directory / "sample.jsonl").read_text().splitlines()]
timing = [json.loads(line) for line in (directory / "timing.jsonl").read_text().splitlines()]
assert [row["path"] for row in sample] == ["range", "point"]
assert all(row["samples"] > 0 for row in sample)
assert all(row["operations"] == 75000 and row["hits"] == 37500 for row in sample + timing)
assert all(row["elapsed_ns"] > 0 and row["samples"] == 0 for row in timing)
PY
}
if [[ "$mode" == profile ]]; then
    do_profile
    exit
fi

cargo build --locked --quiet --release --manifest-path klog/Cargo.toml --bin metad-wal
cargo build --locked --quiet --release --manifest-path storage/Cargo.toml --bin kv-project
if [[ "$mode" != benchmark ]]; then
    test -z "$(gofmt -l cmd internal)"
    cargo fmt --manifest-path storage/Cargo.toml --check
    cargo clippy --locked --quiet --manifest-path storage/Cargo.toml --bin kv-project -- -D warnings
    go vet ./...
    METAD_WAL_WRITER="$writer" KV_ENGINE="$engine" go test -race -count=1 ./...
    go build -race -buildvcs=false -tags capstonegate -o "$work/peer" ./cmd/metad
    go build -buildvcs=false -o "$work/check-history" ./cmd/check-history
    python3 -B lab/capstone.py point "$work/peer" "$writer" "$engine" "$work/check-history" "$evidence"
    python3 -B lab/capstone.py minority "$work/peer" "$writer" "$engine" "$work/check-history" "$evidence"

    python3 - "$PWD/internal/metad/runtime.go" "$work" <<'PY'
import json
from pathlib import Path
import sys

source, work = map(Path, sys.argv[1:])
code = source.read_text()
needle = "if ok {\n\t\t\t\t\tpending"
assert code.count(needle) == 1
unsafe = (
    'if ok && p.command.Op == "kv_put" {\n'
    '\t\t\t\t\tp.reply <- outcome{code: 200, result: Result{Found: true}}\n'
    '\t\t\t\t} else ' + needle
)
replacement = work / "early.go"
replacement.write_text(code.replace(needle, unsafe, 1))
(work / "overlay.json").write_text(json.dumps({"Replace": {str(source): str(replacement)}}))
PY
    go build -race -buildvcs=false -overlay "$work/overlay.json" -o "$work/early" ./cmd/metad
    status=0
    python3 -B lab/capstone.py minority "$work/early" "$writer" "$engine" "$work/check-history" "$evidence" || status=$?
    if [[ "$status" != 42 ]]; then
        echo "expected the early-ack control to acknowledge a minority write" >&2
        exit 1
    fi
    echo "negative control: caught acknowledgment before quorum commit"
fi
if [[ "$mode" == recovery ]]; then
    exit
fi

go build -buildvcs=false -o "$work/release" ./cmd/metad
classpath=$(bash bench/prepare.sh "${YCSB_CACHE_DIR:-$work/jars}" "$work/classes")
profile_mode=full
if [[ "$mode" == replay ]]; then
    profile_mode=smoke
fi
python3 -B lab/benchmark.py "$work/release" "$writer" "$engine" "$classpath" "$evidence/ycsb" "$profile_mode"
if [[ "$mode" == all ]]; then
    do_profile
fi
