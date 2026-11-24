#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Core 02 captures: user "ada" (uid 1000) in a fresh ubuntu:24.04 (blueprint-capture image),
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

# ---- lesson 01
mkdir -p ~/blueprint && cd ~/blueprint && bash -lc 'uv init --package kload && cd kload && mkdir drills' > /cap/0099-init.txt 2>&1
cap 0100-version "$W" 'uv run python --version'
cp -r /final/drills/. "$W/drills/"
cap 0101-objects "$W" 'uv run python drills/objects.py'
cap 0102-traps "$W" 'uv run python drills/traps.py'
cap 0103-refcount "$W" 'uv run python drills/refcount.py'
cap 0104-bytecode "$W" 'uv run python drills/bytecode.py'
cap 0105-loop "$W" 'uv run python drills/loop.py && go run drills/loop/main.go'
vcap 0106-gc-on l01-gc-on "$W" 'uv run python drills/refcount.py'
vcap 0107-copy l01-copy "$W" 'uv run python drills/objects.py | head -3'

# ---- lesson 02
cap 0201-gil "$W" 'uv run python drills/gil.py'
cap 0202-install "$W" 'uv python install 3.14t'
cap 0202-gil-free "$W" 'uv run --no-project --python 3.14t drills/gil.py'
cap 0203-switch "$W" 'uv run python drills/switch.py && uv run --no-project --python 3.14t drills/switch.py'
vcap 0204-wait-computes l02-wait-computes "$W" 'uv run python drills/gil.py | tail -4'

# ---- lesson 03
cap 0301-byhand "$W" 'uv run python drills/byhand.py'
cap 0302-await "$W" 'uv run python drills/await.py'
cap 0303-withasyncio "$W" 'uv run python drills/withasyncio.py'
cap 0304-blocked "$W" 'uv run python drills/blocked.py'
cap 0305-debug "$W" 'uv run python drills/blocked.py --debug 2>&1 | grep -o "Executing <Task.*took [0-9.]* seconds" | sed "s/coro=.* took/... took/"'
vcap 0306-byhand-blocks l03-byhand-blocks "$W" 'uv run python drills/byhand.py | tail -2'

# ---- lesson 04
put l04s2
cap 0401-test-stats "$W" 'uv run pytest -q'
put l04
cap 0402-cli "$W" 'uv run pytest -q && uv run kload --help'
cap 0403-averages "$W" 'uv run python -c "print(\"\n\".join([\"10\"] * 99 + [\"5000\"]))" > /tmp/one-slow.txt && uv run kload summarize /tmp/one-slow.txt && uv run python -c "print(\"\n\".join([\"10\"] * 98 + [\"5000\"] * 2))" > /tmp/two-slow.txt && uv run kload summarize /tmp/two-slow.txt'
vcap 0404-sort-in-place l04-sort-in-place "$W" 'uv run pytest -q 2>&1 | tail -4'

# ---- lesson 05
put l05s2
cap 0501-test-client "$W" 'uv run pytest -q'
put l06
cap 0502-smoke "$W" "$(sy) uv run kload smoke"
cap 0503-smoke-down "$W" 'uv run kload smoke; echo "exit $?"'
vcap 0504-no-match l05-no-match "$W" 'uv run pytest -q tests/test_client.py 2>&1 | tail -4'

# ---- lesson 06
cap 0601-test-http1 "$W" 'uv run pytest -q tests/test_http1.py'
cap 0602-test-load "$W" 'uv run pytest -q tests/test_load.py'
cap 0603-test-all "$W" 'uv run ruff format --check . && uv run ruff check . && uv run pytest -q'
cap 0604-health "$W" "$(sy) uv run kload load --rate 200 --duration 5 --out results/health.csv"
cap 0605-limit "$W" "$(sy) for r in 1000 4000 20000; do uv run kload load --rate \$r --duration 2 --out results/rate\$r.csv; echo \"exit \$?\"; done"
vcap 0606-fromsent l06-fromsent "$W" 'uv run pytest -q tests/test_load.py 2>&1 | tail -4'
vcap 0607-gather-all l06-gather-all "$W" "$(sy) uv run kload load --rate 3000 --duration 5 --out results/gather.csv | grep itself"
cap 0607b-dispatcher "$W" "$(sy) uv run kload load --rate 3000 --duration 5 --out results/dispatch.csv | grep itself"

# ---- lesson 07, 08: the finished project
put final
cap 0701-base "$W" "$(sy) uv run kload load --rate 200 --duration 10 --out results/base.csv"
cap 0702-freeze "$W" "$(sy)"' for mode in open closed; do (sleep 3; kill -STOP $(pgrep -x switchyard); sleep 1; kill -CONT $(pgrep -x switchyard)) & freezer=$!; uv run kload load --rate 200 --duration 8 --mode $mode --out results/freeze-$mode.csv; wait $freezer; done'
cap 0703-analyze "$W" 'uv run kload analyze results/freeze-open.csv --plot results/freeze-open.png'
cp "$W/results/freeze-open.png" /images/ 2>/dev/null
cap 0704-saturation "$W" "QUEUE_CAPACITY=50 $S/bin/switchyard > /dev/null 2>&1 & sleep 0.5; WORKER_NAME=a $S/bin/worker > /dev/null 2>&1 & WORKER_NAME=b $S/bin/worker > /dev/null 2>&1 & sleep 1;"' for r in 20 100; do uv run kload load --method POST --path /jobs --body "{\"description\":\"kload\",\"duration_ms\":50}" --rate $r --duration 10 --out results/jobs$r.csv; done; uv run kload analyze results/jobs100.csv | tail -11'
cap 0705-bottleneck "$W" "$(sy)"' uv run kload load --rate 2000 --duration 5 --out results/h2000.csv; uv run kload load --rate 4000 --duration 5 --out results/h4000.csv; uv run kload load --rate 2000 --duration 5 --out results/split1.csv > /tmp/split1.txt & first=$!; uv run kload load --rate 2000 --duration 5 --out results/split2.csv > /tmp/split2.txt; wait $first; cat /tmp/split1.txt /tmp/split2.txt'
vcap 0706-mean l07-mean "$W" 'uv run kload analyze results/freeze-open.csv | head -10'
cap 0801-again "$W" "$(sy)"' for n in 1 2 3 4 5; do uv run kload load --rate 1000 --duration 3 --out results/again/run$n.csv | grep latency; done'
cap 0802-test-all "$W" 'uv run ruff format --check . && uv run ruff check . && uv run pytest -q'
cap 0803-settings "$W" "$(sy) uv run kload load --settings results/base.json --out results/base-again.csv | grep latency"
cap 0804-builds "$W" "bash experiments/builds.sh $S/bin results/builds && uv run kload compare results/builds/plain results/builds/plain-again && uv run kload compare results/builds/plain results/builds/race" 400
vcap 0805-fixed l08-fixed-order "$W" "bash experiments/builds.sh $S/bin results/fixed && uv run kload compare results/fixed/plain results/fixed/plain-again" 400
echo "captures done"
