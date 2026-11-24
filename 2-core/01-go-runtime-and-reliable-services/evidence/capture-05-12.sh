#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 01 captures, lessons 05-12: user "ada" in a fresh ubuntu:24.04 (blueprint-capture image),
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

# lesson 05
put l04; mkdir -p "$W/internal/jobs"; cp /snap/l05/internal/jobs/job_test.go "$W/internal/jobs/"
cap 0501-red "$W" 'go test ./internal/jobs'
put l05
cap 0502-green "$W" 'go test -v ./internal/jobs 2>&1 | grep -E "^(--- |ok|FAIL)|->"'
vcap 0503-rule l05-rule "$W" 'go test ./internal/jobs'
vcap 0504-bytes l05-bytes "$W" 'go test ./internal/jobs'
# lesson 06
put l06
cap 0601-store "$W" 'go test -race ./internal/memstore'
vcap 0602-race l06-race "$W" 'go test -race ./internal/memstore'
# lesson 07
put l07
cap 0701-cas "$W" 'go test -race -v -run Concurrent ./internal/jobs 2>&1 | grep -E "^(--- |ok|FAIL)"'
vcap 0702-nocas l07-nocas "$W" 'go test -race ./internal/jobs'
vcap 0703-withoutcancel l07-withoutcancel "$W" 'go test ./internal/jobs'
# lesson 08
put l08
cap 0801-test "$W" 'go test -race ./...'
cap 0802-create-run "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { /tmp/switchyard & sleep 0.5; curl -si -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"resize images\",\"duration_ms\":300}"; echo; time curl -s -X POST http://127.0.0.1:8080/jobs/1/run; curl -s -w "  [%{http_code}]\n" -X POST http://127.0.0.1:8080/jobs/1/run; }'
cap 0803-errors "$W" '/tmp/switchyard 2>/dev/null & sleep 0.5; J="Content-Type: application/json"; U=http://127.0.0.1:8080; curl -s -o /dev/null -X POST $U/jobs -H "$J" -d "{\"description\":\"one\"}"; curl -s -w "  [%{http_code}]\n" -X POST $U/jobs -H "$J" -d "{}"; curl -s -w "  [%{http_code}]\n" -X POST $U/jobs -H "$J" -d "{\"description\":\"x\",\"priority\":1}"; curl -s -w "  [%{http_code}]\n" -X POST $U/jobs -d "{\"description\":\"x\"}"; curl -s -w "  [%{http_code}]\n" -X POST $U/jobs -H "$J" -d "{\"description\":\"$(printf "a%.0s" {1..2000})\"}"; curl -s -w "  [%{http_code}]\n" $U/jobs/99; curl -s -w "  [%{http_code}]\n" $U/jobs/abc; curl -si -X DELETE $U/jobs/1 | head -2'
cap 0804-restart "$W" '/tmp/switchyard 2>/dev/null & sleep 0.5; curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"one\"}"; kill %1; sleep 0.3; /tmp/switchyard 2>/dev/null & sleep 0.5; curl -s -w "  [%{http_code}]\n" http://127.0.0.1:8080/jobs/1'
vcap 0805-unknown l08-unknown "$W" 'go test ./internal/httpapi'
# lesson 09
put l09
cap 0901-test "$W" 'go test -race ./...'
cap 0902-env "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { LISTEN_ADDR=127.0.0.1:9090 /tmp/switchyard & sleep 0.5; curl -s http://127.0.0.1:9090/health; }'
cap 0903-failfast "$W" 'LISTEN_ADDR=8080 /tmp/switchyard; echo "exit $?"'
# lesson 10
put l10
cap 1001-test "$W" 'go test -race ./...'
cap 1002-deadline "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { REQUEST_TIMEOUT=1s /tmp/switchyard 2>/dev/null & sleep 0.5; curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"slow\",\"duration_ms\":3000}"; time curl -si -X POST http://127.0.0.1:8080/jobs/1/run; }'
cap 1003-client-gives-up "$W" 'REQUEST_TIMEOUT=1s /tmp/switchyard 2>/dev/null & sleep 0.5; curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"slow\",\"duration_ms\":1500}"; curl -s --max-time 0.5 -X POST http://127.0.0.1:8080/jobs/1/run; echo "curl exit $?"; sleep 0.2; curl -s http://127.0.0.1:8080/jobs/1'
vcap 1004-sleep l10-sleep "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { REQUEST_TIMEOUT=1s /tmp/switchyard 2>/dev/null & sleep 0.5; curl -s -o /dev/null -X POST http://127.0.0.1:8080/jobs -H "Content-Type: application/json" -d "{\"description\":\"slow\",\"duration_ms\":3000}"; time curl -si -X POST http://127.0.0.1:8080/jobs/1/run; }'
# lesson 11
put l11
cap 1100-get "$W" 'go get github.com/prometheus/client_golang@v1.24.1'
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
