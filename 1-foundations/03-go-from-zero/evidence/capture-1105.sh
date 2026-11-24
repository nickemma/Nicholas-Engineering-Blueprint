#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
set -u
cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
W=~/blueprint/gofromzero; mkdir -p $W && cd $W && bash -lc 'go mod init gofromzero' >/dev/null 2>&1
cp -r /final/logs /final/cmd "$W/" && cp /sample.log "$W/"
long=$(awk 'BEGIN { for (i = 0; i < 100000; i++) printf "x" }')
echo "{\"ts\":\"t\",\"status\":200,\"path\":\"/$long\",\"ms\":1}" > long.log; cat sample.log >> long.log
{ echo '$ go run ./cmd/loganalyse long.log | cut -c1-60'; bash -lc "cd $W; go run ./cmd/loganalyse long.log | cut -c1-60" 2>&1; echo "[exit $?]"; } > /cap/1105-long-ok.txt
