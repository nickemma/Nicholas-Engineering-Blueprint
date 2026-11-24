#!/usr/bin/env bash
set -euo pipefail

cd "${1:-.}"
source_dir=$PWD
mode=${2:-portable}
if [[ "$mode" != portable && "$mode" != live ]]; then
    echo 'usage: run.sh [learner directory [portable|live]]' >&2
    exit 2
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

test -z "$(gofmt -l cmd edge link page partition route)"
go vet ./...
go test -race -count=1 -v ./...
for script in experiments/*.sh; do bash -n "$script"; done

mkdir "$work/controls"
cp -R go.mod go.sum page edge partition "$work/controls/"
python3 - "$work/controls" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
p = root / "edge/edge.go"
source = p.read_text()
part = "if c.useCache && len(c.items) < 128 {"
assert source.count(part) == 1
p.write_text(source.replace(part, "if !c.useCache && len(c.items) < 128 {", 1))

p = root / "partition/model.go"
source = p.read_text()
part = "return links[Direction{from, to}]"
assert source.count(part) == 1
p.write_text(source.replace(part, part + " || links[Direction{to, from}]", 1))
PY
negative() {
    local package=$1 test=$2 expected=$3
    if (cd "$work/controls" && go test "$package" -run "^$test$" -count=1) >"$work/failure" 2>&1; then
        echo "negative control unexpectedly passed: $test" >&2
        return 1
    fi
    if ! grep -Fq "$expected" "$work/failure"; then
        cat "$work/failure" >&2
        return 1
    fi
    echo "negative control: $expected"
}
negative ./edge TestCachePreventsASecondOriginRequest 'warm request reached origin'
negative ./partition TestDirectedPartitionAndHeal 'asymmetric link was misclassified'

if [[ "$mode" == live ]]; then
    image=${NETWORK_IMAGE:-switchyard-netlab:lab}
    evidence=${NETWORK_EVIDENCE_DIR:-"$work/evidence"}
    mkdir -p "$evidence"
    evidence=$(cd "$evidence" && pwd)
    if [[ -e "$evidence/transport" || -e "$evidence/http" ]]; then
        echo "choose a fresh evidence directory" >&2
        exit 1
    fi
    CGO_ENABLED=0 go build -buildvcs=false -o "$work/netlab" ./cmd/netlab
    docker run --rm --network none --privileged \
        -v "$source_dir:/lab:ro" -v "$evidence:/out" "$image" bash /lab/experiments/transport.sh
    docker run --rm --network none --privileged \
        -v "$source_dir:/lab:ro" -v "$work/netlab:/engine:ro" -v "$evidence:/out" \
        "$image" bash /lab/experiments/http-live.sh
    python3 -B experiments/report.py "$evidence" | tee "$evidence/summary.json"
fi
