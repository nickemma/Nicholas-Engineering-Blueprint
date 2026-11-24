#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Foundations 03 captures: user "ada" in a fresh ubuntu:24.04, Go 1.27.4, 16 CPUs.
set -u
export LANG=C.UTF-8
cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
W=~/blueprint/gofromzero
cap() { local name=$1 dir=$2; shift 2; { echo "\$ $*"; bash -lc "cd $dir; $*" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"; }
# a copy of the finished module with one deliberate mistake laid over it
# One deliberate mistake, applied in place in ~/blueprint/gofromzero, then undone.
vcap() {
  local name=$1 v=$2 f b
  shift 2
  while read -r f; do
    b="/tmp/bak-${f//\//_}"
    if [ -e "$W/$f" ]; then cp "$W/$f" "$b"; fi
  done < <(cd "/variants/$v" && find . -type f)
  cp -r "/variants/$v/." "$W/"
  cap "$name" "$W" "$@"
  while read -r f; do
    b="/tmp/bak-${f//\//_}"
    if [ -e "$b" ]; then mv "$b" "$W/$f"; else rm -f "$W/$f"; rmdir "$(dirname "$W/$f")" 2>/dev/null; fi
  done < <(cd "/variants/$v" && find . -type f)
}

cap 0101-mod-init '~' 'mkdir -p ~/blueprint/gofromzero && cd ~/blueprint/gofromzero && go mod init gofromzero && cat go.mod'
cp -r /final/drills /final/wordcount /final/tasks /final/logs /final/cmd "$W/"
cp /sample.log /gen.awk "$W/"
cap 0102-values "$W" 'go run ./drills/values'
vcap 0103-const-overflow l01-const-overflow 'go run ./drills/values'
vcap 0104-mismatch l01-mismatch 'go run ./drills/values'
vcap 0105-vet l01-vet 'go vet ./drills/values'
cap 0106-build "$W" 'go build -o values ./drills/values && ls -l values && ./values | head -2 && rm values'
cap 0201-flow "$W" 'go run ./drills/flow'
vcap 0202-unused l02-unused 'go run ./drills/flow'
vcap 0203-missing-return l02-missing-return 'go run ./drills/flow'
cap 0301-errs "$W" 'go run ./drills/errs'
vcap 0302-ignored l03-ignored 'go run ./drills/ignored'
cap 0401-slices "$W" 'go run ./drills/slices'
vcap 0402-nilmap l04-nilmap 'go run ./drills/nilmap'
cap 0501-structs "$W" 'go run ./drills/structs'
vcap 0502-nilptr l05-nilptr 'go run ./drills/nilptr'
cap 0601-shapes "$W" 'go run ./drills/shapes'
vcap 0602-missing-method l06-missing-method 'go run ./drills/shapes'
cap 0701-test "$W" 'go test ./wordcount'
cap 0702-test-v "$W" 'go test -v ./wordcount'
vcap 0703-test-fail l07-failing 'go test ./wordcount'
cap 0704-cover "$W" 'go test -cover ./wordcount'
cap 0705-run "$W" 'go test -v -run TestTop ./wordcount'
cap 0801-tasks-test "$W" 'go test -v ./tasks'
mkdir -p ~/try
cap 0802-tasks-build "$W" 'go build -o ~/try/tasks ./cmd/tasks && ls -l ~/try/tasks'
cap 0803-session '~/try' './tasks list && ./tasks add "write the gate" && ./tasks add "test it both ways" && ./tasks done 1 && ./tasks list && cat tasks.json'
cap 0804-errors '~/try' './tasks done 9; echo "exit status: $?"; ./tasks done abc; echo "exit status: $?"; ./tasks; echo "exit status: $?"'
cap 0805-file '~/try' './tasks -file other.json add "elsewhere" && ./tasks -file other.json list && ./tasks list'
cap 0806-corrupt '~/try' 'echo "{" > broken.json && ./tasks -file broken.json list; echo "exit status: $?"'
cap 0901-goroutines "$W" 'go run ./drills/goroutines'
vcap 0902-noexit l09-noexit 'go run ./drills/noexit'
vcap 0903-deadlock l09-deadlock 'go run ./drills/deadlock'
cap 1001-race-ok "$W" 'go run -race ./drills/race'
vcap 1002-race-wrong l10-race 'for i in 1 2 3; do go run ./drills/race | tail -1; done'
vcap 1003-race-detected l10-race 'go run -race ./drills/race'
cap 1101-logs-test "$W" 'go test -v ./logs'
cap 1102-sample "$W" 'go run ./cmd/loganalyse sample.log'
cap 1103-gen "$W" 'awk -v n=1000000 -f gen.awk > big.log && ls -l big.log && wc -l < big.log && head -2 big.log'
long=$(awk 'BEGIN { for (i = 0; i < 100000; i++) printf "x" }')
echo "{\"ts\":\"t\",\"status\":200,\"path\":\"/$long\",\"ms\":1}" > "$W/long.log"; cat "$W/sample.log" >> "$W/long.log"
vcap 1104-too-long l11-shortlines 'go run ./cmd/loganalyse long.log'
cap 1105-long-ok "$W" 'go run ./cmd/loganalyse long.log | head -4'
cap 1106-big "$W" 'go build -o loganalyse ./cmd/loganalyse && /usr/bin/time -f "%M KB max, %e s" ./loganalyse big.log'
vcap 1107-bytes l11-bytes 'go build -o lb ./cmd/loganalyse && ./lb big.log | head -6 && ./lb big.log | head -2 && go vet ./... && echo "go vet: no complaints"; rm -f lb'
vcap 1108-slurp l11-slurp 'go build -o slurp ./cmd/slurp && /usr/bin/time -f "%M KB max, %e s" ./slurp big.log; rm -f slurp'
cap 1109-workers "$W" 'for w in 1 2 4 8 16; do for k in 1 2 3; do /usr/bin/time -f "workers $w: %e s" ./loganalyse -workers $w big.log >/dev/null; done; done'
cap 1110-gate "$W" 'rm -f loganalyse big.log && bash /gate/run.sh ~/blueprint/gofromzero'
