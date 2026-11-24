#!/usr/bin/env bash
set -euo pipefail

cd "${1:-.}"
root=$PWD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cargo fmt --manifest-path storage/Cargo.toml --check
cargo clippy --locked --quiet --manifest-path storage/Cargo.toml --all-targets -- -D warnings
cargo test --locked --quiet --manifest-path storage/Cargo.toml --lib -- --nocapture
cargo build --locked --quiet --manifest-path storage/Cargo.toml --bin audit-writer
target=$(cargo metadata --manifest-path storage/Cargo.toml --locked --no-deps --format-version 1 |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')
export AUDIT_WRITER="$target/debug/audit-writer"
export AUDIT_FEED="$work/auditfeed"
export INTEGRITY_KAFKA_BROKERS=${INTEGRITY_KAFKA_BROKERS:-${RUNWAY_KAFKA_BROKERS:-}}

(
    cd "$root/audit"
    test -z "$(gofmt -l cmd internal)"
    go vet ./...
    go build -buildvcs=false -tags integritygate -race -o "$AUDIT_FEED" ./cmd/auditfeed
    go test -race -count=1 -v ./internal/audit ./internal/auditfeed
)

mkdir -p "$work/variant/klog"
cp -R storage/Cargo.toml storage/Cargo.lock storage/src "$work/variant/"
cp -R storage/klog/Cargo.toml storage/klog/src "$work/variant/klog/"
python3 - "$work/variant/src/namespace.rs" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
code = source.read_text()
original = "None => self.tenant.upper(),"
assert code.count(original) == 1
source.write_text(code.replace(original, "None => vec![0xff],", 1))
PY
status=0
CARGO_TARGET_DIR="$work/variant-target" cargo test --offline --locked --quiet \
    --manifest-path "$work/variant/Cargo.toml" --lib tenant_scan_stays_inside_namespace \
    -- --nocapture >"$work/variant.txt" 2>&1 || status=$?
if [[ "$status" != 101 ]] || ! grep -q 'tenant scan crossed the namespace boundary' "$work/variant.txt"; then
    cat "$work/variant.txt" >&2
    echo "expected the weakened scan to fail the namespace assertion" >&2
    exit 1
fi
echo "negative control: removing the tenant upper bound exposed a second namespace"
