#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 01 captures, lesson 10 step 5 (rerun: both blocks on one server, as the lesson runs them): user "ada" in a fresh ubuntu:24.04 (blueprint-capture image),
# Go 1.27.4. Mounts: /snap /variants /final (read-only), /cap (output).
set -u
export LANG=C.UTF-8
W=~/blueprint/switchyard
cap() {
  local name=$1 dir=$2
  shift 2
  { echo "\$ $*"; timeout 120 bash -lc "cd $dir; $*" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"
  pkill -x switchyard; sleep 0.2
}
# put SNAP: lay a snapshot over the module, keeping the learner's own go.mod and go.sum.
put() {
  cp "$W/go.mod" /tmp/go.mod; [ -f "$W/go.sum" ] && cp "$W/go.sum" /tmp/go.sum
  rm -rf "$W/internal" "$W/cmd"; cp -r "/snap/$1/." "$W/"
  cp /tmp/go.mod "$W/go.mod"; if [ -f /tmp/go.sum ]; then cp /tmp/go.sum "$W/go.sum"; else rm -f "$W/go.sum"; fi
}
# vcap NAME VARIANT DIR CMD: one deliberate mistake laid over the module, run, then undone.
vcap() {
  local name=$1 v=$2 dir=$3 f b
  shift 3
  while read -r f; do b="/tmp/bak-${f//\//_}"; cp "$W/$f" "$b"; done < <(cd "/variants/$v" && find . -type f)
  cp -r "/variants/$v/." "$W/"
  cap "$name" "$dir" "$@"
  while read -r f; do b="/tmp/bak-${f//\//_}"; mv "$b" "$W/$f"; done < <(cd "/variants/$v" && find . -type f)
}

cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
mkdir -p "$W" && cd "$W" && bash -lc 'go mod init switchyard' >/dev/null 2>&1
cp -r /final/drills "$W/"
put l10
cap 1002-1003 "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { REQUEST_TIMEOUT=1s /tmp/switchyard 2>/dev/null & sleep 0.5; curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"slow\",\"duration_ms\":3000}"; time curl -si -X POST http://127.0.0.1:8080/jobs/1/run; echo "=====SPLIT"; curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"slow\",\"duration_ms\":1500}"; curl -s --max-time 0.5 -X POST http://127.0.0.1:8080/jobs/2/run; echo "curl exit $?"; sleep 0.2; curl -s http://127.0.0.1:8080/jobs/2; }'
echo "captures done"
