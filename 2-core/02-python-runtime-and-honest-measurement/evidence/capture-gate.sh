#!/usr/bin/env bash
# shellcheck disable=SC2016  # commands are quoted on purpose: they run inside the capture shell
# Core 02 gate runs: the finished kload and five broken versions, user "ada" (uid 1000) in a
# fresh ubuntu:24.04 (blueprint-capture image), Go 1.27.4, uv 0.12.7, Python 3.14.7. Each run
# uses a copy of the project in /tmp/gate-NAME. Mounts (read-only): /final, /gate, /broken,
# /pbs (Python builds for UV_PYTHON_INSTALL_MIRROR), /uv; (writable) /cap.
set -u
export LANG=C.UTF-8 HOME=/home/ada
cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
mkdir -p ~/.local/bin && cp /uv/uv ~/.local/bin/
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin' >> ~/.profile
bash -lc 'uv python install 3.14' > /tmp/setup.log 2>&1 || { cat /tmp/setup.log; exit 1; }
gaterun() { # NAME VARIANT
  local name=$1 v=$2 d=/tmp/gate-$1
  rm -rf "$d"; cp -r /final "$d"; rm -rf "$d/.venv" "$d/results"
  [ -n "$v" ] && cp -r "/broken/$v/." "$d/"
  { echo "\$ bash gate/run.sh ~/blueprint/kload   # $name"; timeout 600 bash -lc "bash /gate/run.sh $d" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"
}
gaterun pass ""
for v in fromsent nokey neverbehind sleepblocks compareflip; do gaterun "$v" "$v"; done
echo "gate captures done"
