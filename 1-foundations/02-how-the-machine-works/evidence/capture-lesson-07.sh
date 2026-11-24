#!/usr/bin/env bash
# Lesson 07 captures, as "ada" in a fresh ubuntu:24.04 (shellcheck installed).
set -u
export LANG=C.UTF-8
mkdir -p ~/blueprint/machine && cd ~/blueprint/machine
cp /final/writer.sh /final/check_lines.sh /final/rotate_copytruncate.sh /final/experiment.sh /snap/monitor-usage.sh .
mv monitor-usage.sh monitor.sh; chmod +x ./*.sh
cap() { local name=$1; shift; { echo "\$ $*"; bash -c "cd ~/blueprint/machine; $*" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"; }
cap 0701-writer 'mkdir -p logs && cd logs && { ../writer.sh app.log & sleep 0.5; kill -TERM "$(cat app.log.pid)"; wait; } && wc -l app.log && head -3 app.log && cat app.log.last && rm app.log*'
cap 0702-naive './experiment.sh rotate_copytruncate.sh 10 0'
cap 0703-inode 'cd logs && { ../writer.sh app.log & sleep 0.3; }; p=$(cat app.log.pid); ls -i app.log; ls -l /proc/$p/fd/3; mv app.log app.log.1; ls -i app.log.1; ls -l /proc/$p/fd/3; kill -HUP $p; sleep 0.2; ls -i app.log app.log.1; ls -l /proc/$p/fd/3; kill -TERM $p; wait; rm -f app.log*'
cp /snap/rotate-1.sh rotate.sh; chmod +x rotate.sh
cap 0704-rotate-1-once './experiment.sh rotate.sh 1 3'
cap 0705-rotate-1-twice './experiment.sh rotate.sh 2 3'
cp /snap/rotate-2.sh rotate.sh
cap 0706-rotate-2 './experiment.sh rotate.sh 10 20'
cp /snap/rotate-3.sh rotate.sh
cap 0707-rotate-3-keep3 './experiment.sh rotate.sh 10 3'
cap 0708-rotate-3-keep20 './experiment.sh rotate.sh 10 20'
rm -rf logs
cap 0709-gate 'bash /gate/run.sh ~/blueprint/machine'
