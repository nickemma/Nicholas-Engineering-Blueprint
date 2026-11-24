#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 01 captures, lessons 11-12 (rerun: the first run lacked go mod tidy): user "ada" in a fresh ubuntu:24.04 (blueprint-capture image),
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
# lesson 11
put l11
cap 1100-get "$W" 'go get github.com/prometheus/client_golang@v1.24.1 && go mod tidy'
cap 1101-test "$W" 'go test -race ./...'
cap 1102-metrics "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { REQUEST_TIMEOUT=1s /tmp/switchyard > /tmp/switchyard.log & sleep 0.5; U=http://127.0.0.1:8080; J="Content-Type: application/json"; curl -s -o /dev/null -X POST $U/jobs -H "$J" -d "{\"description\":\"quick\",\"duration_ms\":300}"; curl -s -o /dev/null -X POST $U/jobs -H "$J" -d "{\"description\":\"slow\",\"duration_ms\":3000}"; curl -s -o /dev/null $U/jobs/1; curl -s -o /dev/null $U/jobs/abc; curl -s -o /dev/null $U/jobs/99; curl -s -o /dev/null -X POST $U/jobs/1/run; curl -s -o /dev/null -X POST $U/jobs/1/run; curl -s -o /dev/null -X POST $U/jobs/2/run; curl -s $U/metrics | grep "^http_requests_total"; }'
cap 1103-log "$W" 'grep "\"msg\":\"request\"" /tmp/switchyard.log | tail -3'
vcap 1104-order l11-order "$W" 'go test ./internal/httpapi'
# lesson 12
put l12
cap 1201-test "$W" 'go test -race ./...'
cap 1202-sigterm "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { /tmp/switchyard > /tmp/switchyard.log & p=$!; sleep 0.5; curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"slow\",\"duration_ms\":1500}"; curl -s -X POST http://127.0.0.1:8080/jobs/1/run & sleep 0.3; kill -TERM $p; wait; echo; cat /tmp/switchyard.log; }'
cap 1203-proc "$W" '/tmp/switchyard > /tmp/switchyard.log & p=$!; sleep 0.5; ps -o pid,stat,nlwp,comm -p $p; ls -l /proc/$p/fd | awk "NR > 1 {print \$9, \$10, \$11}"; grep "open files" /proc/$p/limits'
cap 1204-burst "$W" '/tmp/switchyard > /tmp/switchyard.log & sleep 0.5; seq 1 200 | xargs -P 20 -I{} curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"burst\"}" | sort | uniq -c; curl -s -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"one more\"}"; echo'
vcap 1205-close l12-close "$W" 'go test ./cmd/switchyard'
echo "captures done"
