#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Foundations 04 recapture of single items after a wording change, same image and user as capture04.sh.
set -u
sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq iproute2 netcat-openbsd tcpdump >/dev/null 2>&1
cap() { local name=$1 dir=$2; shift 2; { echo "\$ $*"; timeout 120 bash -lc "cd $dir; $*" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"; }
cap 0304-refused '~' 'sudo tcpdump -i lo -n -l "port 9001" 2>/dev/null > /tmp/td.txt & sleep 1; nc -v 127.0.0.1 9001; echo "exit $?"; sleep 0.3; sudo pkill tcpdump; sleep 0.3; cat /tmp/td.txt'
