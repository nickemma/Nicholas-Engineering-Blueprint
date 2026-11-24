#!/usr/bin/env bash
set -euo pipefail

gate=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export BLUEPRINT_ROOT
BLUEPRINT_ROOT=$(cd "$gate/../../../.." && pwd)

cd "${1:-.}"
mode=${2:-all}
case "$mode" in
    all|replay|recovery|tla|range|transfer) ;;
    *) echo 'usage: run.sh [learner directory [all|replay|recovery|tla|range|transfer]]' >&2; exit 2 ;;
esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
evidence=${CONSENSUS_EVIDENCE_DIR:-$scratch}
mkdir -p "$evidence"
evidence=$(cd "$evidence" && pwd)

check_go() {
    cargo build --quiet --locked --manifest-path klog/Cargo.toml --target-dir "$scratch/rust" --bin metad-wal
    writer="$scratch/rust/debug/metad-wal"
    test -z "$(gofmt -l cmd internal)"
    go vet ./...
    METAD_WAL_WRITER="$writer" go test -race -count=1 ./...
    go build -buildvcs=false -race -o "$scratch/metad" ./cmd/metad
    go build -buildvcs=false -o "$scratch/check-history" ./cmd/check-history
}

run_live() {
    python3 -B lab/consensus.py "$1" "$scratch/metad" "$writer" "$scratch/check-history" "$evidence"
}

run_tlc() {
    local jar=${TLA2TOOLS_JAR:-"$scratch/tla2tools.jar"}
    if [[ -z "${TLA2TOOLS_JAR:-}" ]]; then
        curl -fsSL --max-time 90 -o "$jar" https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar
    fi
    local digest
    digest=$(sha256sum "$jar")
    if [[ ${digest%% *} != fdffef247f563ef6edbfd44958d2a82db79e7564e07cb673262d896353fa6713 ]]; then
        echo "TLC jar does not match the pinned 1.8.0 release" >&2
        return 1
    fi
    local -a tlc=(java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1
                  -noGenerateSpecTE -metadir "$scratch/states")
    if ! "${tlc[@]}" -config tla/RaftElection.cfg tla/RaftElection.tla >"$evidence/tlc.txt" 2>&1; then
        cat "$evidence/tlc.txt" >&2
        return 1
    fi
    grep -E 'No error has been found|distinct states found, 0 states left on queue' "$evidence/tlc.txt"
    if "${tlc[@]}" -config tla/DoubleVote.cfg tla/RaftElection.tla >"$evidence/tlc-double-vote.txt" 2>&1; then
        echo "double-vote control unexpectedly passed" >&2
        return 1
    fi
    grep -F 'Invariant ElectionSafety is violated' "$evidence/tlc-double-vote.txt"
}

case "$mode" in
    all|replay|recovery|range) check_go ;;
esac
case "$mode" in
    all|replay)
        run_live recovery
        run_tlc
        run_live range
        if [[ "$mode" == all || "${SWITCHYARD_CONSENSUS_PG_LIVE:-0}" == 1 ]]; then
            python3 -B lab/transfer.py
        else
            echo "PostgreSQL transfer check requires the full gate"
        fi
        ;;
    recovery|range) run_live "$mode" ;;
    tla) run_tlc ;;
    transfer) python3 -B lab/transfer.py ;;
esac
