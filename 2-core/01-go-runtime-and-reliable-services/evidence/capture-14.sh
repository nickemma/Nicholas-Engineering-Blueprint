#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 01 captures, lesson 14: user "ada" in a fresh ubuntu:24.04 (blueprint-capture image),
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
put l14
bash -lc "cd $W && go get github.com/prometheus/client_golang@v1.24.1 && go mod tidy" > /dev/null 2>&1
cap 1401-replay "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { /tmp/switchyard > /dev/null & p=$!; sleep 0.5; for i in 1 2; do curl -s -i -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -H "Idempotency-Key: order-42" -d "{\"description\":\"resize\",\"duration_ms\":100}" | grep -v "^Date"; echo; done; curl -s -w "  [%{http_code}]\n" http://127.0.0.1:8080/jobs/2; echo "=====SPLIT"; curl -s -i -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -H "Idempotency-Key: order-42" -d "{\"description\":\"thumbnail\"}" | grep -v "^Date"; echo; curl -s http://127.0.0.1:8080/metrics | grep "^idempotency_keys"; kill $p; }'
LOSSY='go build -o /tmp/switchyard ./cmd/switchyard && { FAIL_RATE=0.5 /tmp/switchyard > /dev/null & p=$!; sleep 0.5; for i in $(seq 20); do curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"charge\",\"duration_ms\":50}"; done; sleep 3; curl -s http://127.0.0.1:8080/metrics | grep -E "^(job_attempts_total|effects_)"; for i in $(seq 20); do curl -s http://127.0.0.1:8080/jobs/$i; done | grep -o "\"state\":\"[a-z]*\"" | sort | uniq -c; kill $p; }'
cap 1403-lossy "$W" "$LOSSY"
vcap 1404-fingerprint l14-fingerprint "$W" 'go test ./internal/idempotency'
vcap 1405-attemptkey l14-attemptkey "$W" "$LOSSY"
echo "captures done"
