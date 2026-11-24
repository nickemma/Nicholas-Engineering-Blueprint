#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 01 captures, lessons 01-02: user "ada" in a fresh ubuntu:24.04 (blueprint-capture image),
# Go 1.27.4. Mounts: /final /variants (read-only), /cap (output).
set -u
export LANG=C.UTF-8
W=~/blueprint/switchyard

cap() {
  local name=$1 dir=$2
  shift 2
  { echo "\$ $*"; timeout 120 bash -lc "cd $dir; $*" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"
  pkill -x byhand; pkill -x stdhttp; pkill -x gcdrill; sleep 0.2
}
vcap() {
  local name=$1 v=$2 dir=$3 f b
  shift 3
  while read -r f; do b="/tmp/bak-${f//\//_}"; if [ -e "$W/$f" ]; then cp "$W/$f" "$b"; fi; done < <(cd "/variants/$v" && find . -type f)
  cp -r "/variants/$v/." "$W/"
  cap "$name" "$dir" "$@"
  while read -r f; do b="/tmp/bak-${f//\//_}"; if [ -e "$b" ]; then mv "$b" "$W/$f"; else rm -f "$W/$f"; fi; done < <(cd "/variants/$v" && find . -type f)
}

cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
sudo apt-get update -qq >/dev/null 2>&1 && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq netcat-openbsd >/dev/null 2>&1
mkdir -p "$W" && cd "$W" && bash -lc 'go mod init switchyard' >/dev/null 2>&1
cp -r /final/drills "$W/"

# lesson 01
cap 0101-schedtrace "$W" 'go build -o sched ./drills/sched && GODEBUG=schedtrace=1000 ./sched; rm sched'
cap 0102-spin "$W" 'go run ./drills/spin'
cap 0103-spin-nopreempt "$W" 'go build -o spin ./drills/spin && timeout 3 env GODEBUG=asyncpreemptoff=1 ./spin; echo "exit $?"; rm spin'
cap 0104-stacks "$W" 'go run ./drills/stacks'
cap 0105-escape "$W" 'go build -gcflags=-m ./drills/escape 2>&1 | grep -v "can inline"'
cap 0106-bench "$W" 'go test -bench . -benchmem ./drills/escape | grep Benchmark'
cap 0107-gogc "$W" 'go build -o gcdrill ./drills/gc; for g in 50 100 400 off; do echo "GOGC=$g"; GOGC=$g ./gcdrill; done'
cap 0108-memlimit "$W" 'GOGC=off GOMEMLIMIT=200MiB ./gcdrill'
cap 0109-gctrace "$W" 'GODEBUG=gctrace=1 ./gcdrill 2>&1 | head -3; rm gcdrill'
cap 0110-trace "$W" 'go test -bench NewPoint -benchtime 100000x -trace trace.out ./drills/escape > /dev/null && ls -l trace.out && { go tool trace -http 127.0.0.1:0 trace.out > /tmp/trace.log 2>&1 & p=$!; for i in $(seq 120); do grep -q listening /tmp/trace.log && break; sleep 0.5; done; kill $p; cat /tmp/trace.log; }; rm -f trace.out'
vcap 0111-oom l01-gcforever "$W" 'go build -o gcdrill ./drills/gc && (ulimit -v 1000000; GOGC=off ./gcdrill 2>&1 | head -4); rm -f gcdrill'

# lesson 02
cap 0201-test "$W" 'go test -v ./drills/byhand 2>&1 | grep -E "^(--- |ok|FAIL)"'
cap 0202-keepalive "$W" 'go build -o /tmp/byhand ./drills/byhand && { /tmp/byhand > /dev/null 2> /tmp/byhand.log & sleep 0.5; curl -sv http://127.0.0.1:8080/jobs http://127.0.0.1:8080/health 2>&1 | grep -E "^[<>*]|^request" | grep -v "^> \(User\|Accept\)"; }'
cap 0203-bad-input "$W" '/tmp/byhand > /dev/null 2>&1 & sleep 0.5; curl -s -d hello http://127.0.0.1:8080/jobs; printf "GARBAGE\r\n\r\n" | nc -N 127.0.0.1 8080; curl -si -H "Transfer-Encoding: chunked" -d x http://127.0.0.1:8080/ | head -1'
cap 0204-too-large "$W" '/tmp/byhand > /dev/null 2>&1 & sleep 0.5; head -c 2000000 /dev/zero | curl -si --data-binary @- http://127.0.0.1:8080/upload'
cap 0205-std "$W" 'go build -o /tmp/stdhttp ./drills/stdhttp && { /tmp/stdhttp -safe 2> /dev/null & sleep 0.5; curl -s -d hello http://127.0.0.1:8081/jobs; head -c 2000000 /dev/zero | curl -si --data-binary @- http://127.0.0.1:8081/upload; }'
cap 0206-slow "$W" 'for mode in "" "-safe"; do /tmp/stdhttp $mode 2> /dev/null & p=$!; sleep 0.5; s=$(date +%s%N); printf "GET / HTTP/1.1\r\nHost: x\r\n" | timeout 6 nc 127.0.0.1 8081; echo "stdhttp $mode: the connection lasted $(( ($(date +%s%N) - s) / 1000000 )) ms"; kill $p; wait $p 2> /dev/null; done'
echo "captures done"
