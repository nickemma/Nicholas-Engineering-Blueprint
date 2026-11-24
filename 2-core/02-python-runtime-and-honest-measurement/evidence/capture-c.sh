#!/usr/bin/env bash
# shellcheck disable=SC2016  # commands are quoted on purpose: they run inside the capture shell
# Core 02 captures, third run: lesson 01's refcount drill after its label was corrected for
# Python 3.14. Same image and mounts as capture.sh; no Go needed.
set -u
export LANG=C.UTF-8 HOME=/home/ada
W=~/blueprint/kload
cap() { local name=$1 dir=$2 cmd=$3; { echo "\$ $cmd"; timeout 120 bash -lc "cd $dir; $cmd" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"; }
mkdir -p ~/.local/bin && cp /uv/uv ~/.local/bin/
echo 'export PATH=$PATH:$HOME/.local/bin' >> ~/.profile
printf '[user]\n\tname = Ada Lovelace\n\temail = ada@example.com\n' > ~/.gitconfig
bash -lc 'uv python install 3.14' > /dev/null 2>&1
mkdir -p ~/blueprint && cd ~/blueprint && bash -lc 'uv init --package kload && cd kload && mkdir drills && uv run python --version' > /dev/null 2>&1
cp -r /final/drills/. "$W/drills/"
cap 0103-refcount "$W" 'uv run python drills/refcount.py'
cp /variants/l01-gc-on/drills/refcount.py "$W/drills/refcount.py"
cap 0106-gc-on "$W" 'uv run python drills/refcount.py'
