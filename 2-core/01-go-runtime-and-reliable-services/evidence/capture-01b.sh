#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 01 lesson 01, step 5 addition: CPU, system time and resident memory per GOGC setting.
set -u
export LANG=C.UTF-8
W=~/blueprint/switchyard
cap() {
  local name=$1 dir=$2
  shift 2
  { echo "\$ $*"; timeout 120 bash -lc "cd $dir; $*" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"
}
cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
mkdir -p "$W" && cd "$W" && bash -lc 'go mod init switchyard' >/dev/null 2>&1
cp -r /final/drills "$W/"
cap 0107b-time "$W" 'go build -o gcdrill ./drills/gc && for g in 50 400 off; do GOGC=$g /usr/bin/time -f "GOGC=$g: %e s wall, %U s user, %S s sys, %M KB max resident" ./gcdrill > /dev/null; done; rm gcdrill'
echo "captures done"
