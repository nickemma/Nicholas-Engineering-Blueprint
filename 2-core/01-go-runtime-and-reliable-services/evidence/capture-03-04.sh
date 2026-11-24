#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 01 captures, lessons 03-04: user "ada" in a fresh ubuntu:24.04 (blueprint-capture image),
# Go 1.27.4. Mounts: /snap /final (read-only), /cap (output). Git identity: Ada Lovelace, as in Foundations.
set -u
export LANG=C.UTF-8
W=~/blueprint/switchyard
cap() {
  local name=$1 dir=$2
  shift 2
  { echo "\$ $*"; timeout 120 bash -lc "cd $dir; $*" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"
  pkill -x switchyard; sleep 0.2
}
# put SNAP: lay a snapshot over the module, keeping the go.mod that `go mod init` wrote.
put() { cp "$W/go.mod" /tmp/go.mod; rm -rf "$W/internal" "$W/cmd"; cp -r "/snap/$1/." "$W/"; cp /tmp/go.mod "$W/go.mod"; }

cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
printf '[user]\n\tname = Ada Lovelace\n\temail = ada@example.com\n[init]\n\tdefaultBranch = main\n' > ~/.gitconfig
mkdir -p "$W" && cd "$W" && bash -lc 'go mod init switchyard' >/dev/null 2>&1
cp -r /final/drills "$W/"

put l03
cap 0301-contract "$W" 'go build -o /tmp/switchyard ./cmd/switchyard && { /tmp/switchyard & sleep 0.5; for u in /health "/greet?name=Ada" "/greet?name=%20" "/greet?name=$(printf "a%.0s" {1..41})" /nope; do curl -s -w "  [%{http_code}]\n" "http://127.0.0.1:8080$u"; done; curl -si -X POST http://127.0.0.1:8080/health | head -4; kill %1; }'
put l04a
cap 0401-tests "$W" 'go test -v ./internal/httpapi 2>&1 | grep -E "^(=== RUN|--- |ok|FAIL)"'
cap 0402-cover "$W" 'gofmt -l . && go vet ./... && go test -race -cover ./...'
cp /snap/l04/internal/httpapi/handler_test.go "$W/internal/httpapi/"
cap 0403-red "$W" 'go test ./internal/httpapi'
put l04
cap 0404-green "$W" 'go test ./internal/httpapi'
cap 0405-commit "$W" 'git init -q && git add . && git commit -q -m "Switchyard: an HTTP service with a contract, tests and CI" && git log --stat --oneline'
echo "captures done"
