#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 02 captures, second run (after the waits, the 3,000/s break-it and the warm-up were fixed): user "ada" (uid 1000) in a fresh ubuntu:24.04 (blueprint-capture image),
# Go 1.27.4, uv 0.12.7, Python 3.14.7. Mounts (read-only): /final (the finished kload),
# /snaps (the project after lessons 04 step 2, 04, 05 step 2, 06), /variants (one deliberate
# mistake each), /switchyard (core 01's finished code), /gomod (its Go modules), /pbs (Python
# builds for UV_PYTHON_INSTALL_MIRROR), /uv (the uv binary); (writable) /cap, /images.
set -u
export LANG=C.UTF-8 HOME=/home/ada
W=~/blueprint/kload
S=~/blueprint/switchyard
cap() { # NAME DIR CMD [TIMEOUT]: run CMD in DIR; save "$ CMD", its output and "[exit N]"
  local name=$1 dir=$2 cmd=$3 limit=${4:-120}
  { echo "\$ $cmd"; timeout "$limit" bash -lc "cd $dir; $cmd" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"
  pkill -x switchyard; pkill -x switchyard-race; pkill -x worker; sleep 0.3
}
put() { # SNAP: lay a snapshot of the project over the learner's folder
  rm -rf "$W/src" "$W/tests" "$W/experiments"
  cp -r "/snaps/$1/." "$W/"
}
vcap() { # NAME VARIANT DIR CMD [TIMEOUT]: one deliberate mistake laid over the code, run, undone
  local name=$1 v=$2 f
  shift 2
  while read -r f; do cp "$W/$f" "/tmp/bak-${f//\//_}"; done < <(cd "/variants/$v" && find . -type f)
  cp -r "/variants/$v/." "$W/"
  find "$W" -name __pycache__ -prune -exec rm -rf {} +
  cap "$name" "$@"
  while read -r f; do mv "/tmp/bak-${f//\//_}" "$W/$f"; done < <(cd "/variants/$v" && find . -type f)
  find "$W" -name __pycache__ -prune -exec rm -rf {} +
}
sy() { echo "$S/bin/switchyard > /dev/null 2>&1 & sleep 0.5;"; }  # start Switchyard, then the command

# ---- tools, as Foundations 01 and 04 install them
cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
mkdir -p ~/.local/bin && cp /uv/uv ~/.local/bin/
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin' >> ~/.profile
printf '[user]\n\tname = Ada Lovelace\n\temail = ada@example.com\n' > ~/.gitconfig
bash -lc 'uv python install 3.14' > /tmp/setup.log 2>&1 || { cat /tmp/setup.log; exit 1; }

# ---- Switchyard from core 01, built offline from its module cache
mkdir -p "$S" && cp -r /switchyard/. "$S/" && cp -r /gomod /tmp/gomod
bash -lc "cd $S && export GOMODCACHE=/tmp/gomod GOPROXY=off GOFLAGS=-mod=mod && go build -o bin/switchyard ./cmd/switchyard && go build -o bin/worker ./cmd/worker && go build -race -o bin/switchyard-race ./cmd/switchyard" >> /tmp/setup.log 2>&1 || { cat /tmp/setup.log; exit 1; }

mkdir -p ~/blueprint && cd ~/blueprint && bash -lc 'uv init --package kload && cd kload && mkdir drills' > /dev/null 2>&1
put final
vcap 0607-gather-all l06-gather-all "$W" "$(sy) uv run kload load --rate 3000 --duration 5 --out results/gather.csv | grep itself"
cap 0607b-dispatcher "$W" "$(sy) uv run kload load --rate 3000 --duration 5 --out results/dispatch.csv | grep itself"
cap 0702-freeze "$W" "$(sy)"' for mode in open closed; do (sleep 3; kill -STOP $(pgrep -x switchyard); sleep 1; kill -CONT $(pgrep -x switchyard)) & freezer=$!; uv run kload load --rate 200 --duration 8 --mode $mode --out results/freeze-$mode.csv; wait $freezer; done'
cap 0703-analyze "$W" 'uv run kload analyze results/freeze-open.csv --plot results/freeze-open.png'
cp "$W/results/freeze-open.png" /images/ 2>/dev/null
cap 0705-bottleneck "$W" "$(sy)"' uv run kload load --rate 2000 --duration 5 --out results/h2000.csv; uv run kload load --rate 4000 --duration 5 --out results/h4000.csv; uv run kload load --rate 2000 --duration 5 --out results/split1.csv > /tmp/split1.txt & first=$!; uv run kload load --rate 2000 --duration 5 --out results/split2.csv > /tmp/split2.txt; wait $first; cat /tmp/split1.txt /tmp/split2.txt'
vcap 0706-mean l07-mean "$W" 'uv run kload analyze results/freeze-open.csv | head -10'
cap 0804-builds "$W" "bash experiments/builds.sh $S/bin results/builds && uv run kload compare results/builds/plain results/builds/plain-again && uv run kload compare results/builds/plain results/builds/race" 400
vcap 0805-fixed l08-fixed-order "$W" "bash experiments/builds.sh $S/bin results/fixed && uv run kload compare results/fixed/plain results/fixed/plain-again" 400
echo "captures done"
