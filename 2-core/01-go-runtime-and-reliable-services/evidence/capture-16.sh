#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 01 captures, lesson 16: user "ada" in a fresh ubuntu:24.04 (blueprint-capture image),
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
put l16
cp -r /snap/l16/proto "$W/"
bash -lc "cd $W && go get github.com/prometheus/client_golang@v1.24.1 google.golang.org/grpc@v1.84.0 google.golang.org/protobuf@v1.36.12 && go mod tidy" > /tmp/setup.log 2>&1 || { cat /tmp/setup.log; exit 1; }
DEMO1='go build -o /tmp/switchyard ./cmd/switchyard && go build -o /tmp/worker ./cmd/worker && { /tmp/switchyard > /tmp/switchyard.log & sleep 0.5; WORKER_NAME=a /tmp/worker > /tmp/a.log & a=$!; sleep 0.5; curl -s -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"resize\",\"duration_ms\":4000}" > /dev/null; sleep 1; kill -KILL $a; WORKER_NAME=b /tmp/worker > /tmp/b.log & b=$!; sleep 9; grep -h "\"job_id\":1" /tmp/a.log /tmp/switchyard.log /tmp/b.log | sed "s/\"time\":\"[^\"]*\",//"; curl -s http://127.0.0.1:8080/jobs/1; curl -s http://127.0.0.1:8080/effects/1;'
DEMO2=' echo "=====SPLIT"; kill -TERM $b; WORKER_NAME=c /tmp/worker > /tmp/c.log & c=$!; sleep 0.5; curl -s -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"thumbnail\",\"duration_ms\":2000}" > /dev/null; sleep 0.5; kill -STOP $c; WORKER_NAME=d /tmp/worker > /tmp/d.log & d=$!; sleep 5; kill -CONT $c; sleep 3; grep -h "\"job_id\":2" /tmp/c.log /tmp/switchyard.log /tmp/d.log | sed "s/\"time\":\"[^\"]*\",//"; curl -s http://127.0.0.1:8080/effects/2;'
DEMO3=' echo "=====SPLIT"; curl -s -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"render\",\"duration_ms\":5000}" > /dev/null; sleep 0.5; curl -s -X POST http://127.0.0.1:8080/jobs/3/cancel; echo; sleep 1.5; grep -h "\"job_id\":3" /tmp/c.log /tmp/d.log | sed "s/\"time\":\"[^\"]*\",//"; curl -s http://127.0.0.1:8080/effects/3; curl -s http://127.0.0.1:8080/metrics | grep -E "^(workers|leases|jobs_handed_back_total|effects_applied_total|go_goroutines) "; kill -TERM $c $d; pkill -TERM -x switchyard; sleep 1; }'
cap 1601-1603 "$W" "$DEMO1$DEMO2$DEMO3"
pkill -x worker
vcap 1604-notoken l16-notoken "$W" 'go test ./internal/coord'
vcap 1605-noloop l16-noloop "$W" "$DEMO1"' pkill -TERM -x worker; pkill -TERM -x switchyard; sleep 1; }'
pkill -x worker
cap 1606-gate "$W" 'bash /gate/run.sh .'
echo "captures done"
