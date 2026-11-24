#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 01 captures, lesson 13: user "ada" in a fresh ubuntu:24.04 (blueprint-capture image),
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
put l13
bash -lc "cd $W && go get github.com/prometheus/client_golang@v1.24.1 && go mod tidy" > /dev/null 2>&1
cap 1301-1303 "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { WORKERS=1 QUEUE_CAPACITY=2 /tmp/switchyard > /tmp/switchyard.log & p=$!; sleep 0.5; for i in 1 2 3 4 5; do curl -s -o /dev/null -w "job $i: %{http_code} retry-after=%header{retry-after}\n" -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"slow\",\"duration_ms\":1000}"; done; curl -s http://127.0.0.1:8080/metrics | grep "^jobs_queue_depth"; echo "=====SPLIT"; for i in 1 2 3 4 5; do curl -s http://127.0.0.1:8080/jobs/$i; echo; done; echo "=====SPLIT"; sleep 3; kill $p; sleep 0.5; tail -1 /tmp/switchyard.log; }'
cap 1304-overload "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { WORKERS=2 QUEUE_CAPACITY=20 /tmp/switchyard > /dev/null & p=$!; sleep 0.5; go run ./cmd/loadjobs -rate 10 -for 10s -job 500ms; kill $p; }'
cap 1305-spare "$W" 'WORKERS=4 QUEUE_CAPACITY=20 /tmp/switchyard > /dev/null & p=$!; sleep 0.5; go run ./cmd/loadjobs -rate 6 -for 10s -job 500ms; kill $p'
vcap 1306-select l13-select "$W" 'go test -race -count=20 ./internal/queue'
vcap 1307-nobackpressure-test l13-nobackpressure "$W" 'go test -timeout 5s ./internal/queue 2>&1 | grep -E -A1 "^panic|running tests|chan send"'
vcap 1308-nobackpressure-api l13-nobackpressure "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { WORKERS=1 QUEUE_CAPACITY=2 /tmp/switchyard > /dev/null & p=$!; sleep 0.5; for i in 1 2 3 4 5; do curl -s -o /dev/null -w "job $i: %{http_code} after %{time_total} s\n" -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"slow\",\"duration_ms\":1000}"; done; kill $p; }'
echo "captures done"
