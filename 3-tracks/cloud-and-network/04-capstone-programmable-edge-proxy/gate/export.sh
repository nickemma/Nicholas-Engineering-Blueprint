#!/usr/bin/env bash
set -euo pipefail

module="$(cd "$(dirname "$0")/.." && pwd)"
workspace="$(cd "${1:?provide learner workspace}" && pwd)"
output="$(realpath -m "${2:?provide output archive}")"
if [[ -e "$output" ]]; then
    echo 'choose a fresh output archive' >&2
    exit 1
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
name=switchyard-edge-capstone
release="$scratch/$name"
mkdir -p "$release"/{bench,gate,evidence,lab}
cp -r "$workspace"/{Cargo.toml,Cargo.lock,go.mod,src,control,cmd} "$release/"
cp "$workspace"/bench/{main.go,run.py,profile.sh} "$release/bench/"
cp "$workspace"/lab/{check.py,openbao.sh} "$release/lab/"
cp -r "$workspace/lab/xdp" "$release/lab/"
cp "$module/gate/run.sh" "$release/gate/"
cp "$module/gate/standalone.md" "$release/README.md"
cp "$module/evidence/ADR.md" "$release/"
cp -r "$module/evidence/reference" "$release/evidence/"
cat > "$release/.gitignore" <<'IGNORE'
/target/
/edge-control
/bench/edge-bench
__pycache__/
IGNORE
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -czf "$output" -C "$scratch" "$name"
