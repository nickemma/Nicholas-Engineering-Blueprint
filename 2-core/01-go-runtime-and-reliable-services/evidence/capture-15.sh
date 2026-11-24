#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 01 captures, lesson 15: user "ada" in a fresh ubuntu:24.04 (blueprint-capture image),
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
sudo apt-get update -qq >/dev/null 2>&1 && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq protobuf-compiler >/dev/null 2>&1
put l15
GEN='PATH=$PWD/bin:$PATH protoc --go_out=. --go_opt=module=switchyard --go-grpc_out=. --go-grpc_opt=module=switchyard proto/switchyard/jobs/v1/jobs.proto'
bash -lc "cd $W && GOBIN=\$PWD/bin go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12 && GOBIN=\$PWD/bin go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.2 && $GEN && go get github.com/prometheus/client_golang@v1.24.1 google.golang.org/grpc@v1.84.0 google.golang.org/protobuf@v1.36.12 && go mod tidy" > /tmp/setup.log 2>&1 || { cat /tmp/setup.log; exit 1; }
cap 1501-1502 "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { /tmp/switchyard > /tmp/switchyard.log & p=$!; sleep 0.5; grep "grpc listening" /tmp/switchyard.log; echo "=====SPLIT"; go build -o /tmp/jobsctl ./cmd/jobsctl; /tmp/jobsctl create "resize images" 300; sleep 0.5; /tmp/jobsctl get 1; /tmp/jobsctl get 99; echo "exit $?"; /tmp/jobsctl create ""; echo "exit $?"; curl -s http://127.0.0.1:8080/jobs/1; kill $p; }'
cap 1503-size "$W" 'go test -run TestProtobufIsSmallerThanJSON -v ./internal/grpcapi | grep bytes'
vcap 1504-swap l15-swap "$W" "$GEN"' && go build -o /tmp/switchyard ./cmd/switchyard && { /tmp/switchyard > /dev/null & p=$!; sleep 0.5; /tmp/jobsctl create "resize images" 300; echo "exit $?"; curl -s http://127.0.0.1:8080/jobs/1; echo; kill $p; }'
bash -lc "cd $W && $GEN"
cap 1505-after "$W" 'go vet ./... && go test -count=1 ./internal/grpcapi'
echo "captures done"
