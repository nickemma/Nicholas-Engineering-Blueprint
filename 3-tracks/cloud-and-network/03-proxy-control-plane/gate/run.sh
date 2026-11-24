#!/usr/bin/env bash
set -euo pipefail

cd "${1:-.}"
case "${2:-portable}" in
    openbao) exec bash lab/openbao.sh ;;
    portable|xdp) ;;
    *) echo 'usage: run.sh [learner directory [portable|openbao|xdp]]' >&2; exit 2 ;;
esac
workspace="$PWD"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

if [[ "${2:-portable}" == xdp ]]; then
    cargo build --locked --target-dir target
    CGO_ENABLED=0 go build -trimpath -o "$scratch/origin" bench/main.go
    docker run --rm --network none --privileged \
        --mount "type=bind,source=$workspace/target/debug/switchyard-edge,target=/work/proxy,readonly" \
        --mount "type=bind,source=$scratch/origin,target=/work/origin,readonly" \
        "${EDGE_XDP_IMAGE:-switchyard-cn03-xdp:lab}"
    exit
fi

cargo fmt --check
cargo clippy --locked --target-dir target --all-targets -- -D warnings
cargo test --locked --target-dir target
cargo build --locked --target-dir target
test -z "$(gofmt -l control cmd)"
go vet ./...
EDGE_BIN="$workspace/target/debug/switchyard-edge" go test -race -count=1 -v ./control
for script in lab/openbao.sh lab/xdp/run.sh; do bash -n "$script"; done

mkdir "$scratch/mutation"
cp -r Cargo.lock Cargo.toml src "$scratch/mutation/"
python3 - "$scratch/mutation/src/admin.rs" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
before = '                    "unchanged"'
if source.count(before) != 1:
    raise SystemExit("expected one idempotent acknowledgement")
path.write_text(source.replace(before, '                    "duplicate"'))
PY
(cd "$scratch/mutation" && cargo build --quiet --locked --target-dir "$scratch/target")
if EDGE_BIN="$scratch/target/debug/switchyard-edge" go test ./control -run '^TestRoutes$' -count=1 >"$scratch/failure" 2>&1; then
    echo 'gate failed: changed acknowledgement passed the retry check' >&2
    exit 1
fi
if ! grep -E 'expected unchanged generation 1, got \{Result:duplicate Snapshot:\{Generation:1' "$scratch/failure"; then
    cat "$scratch/failure" >&2
    exit 1
fi
echo "proxy control plane gate passed"
