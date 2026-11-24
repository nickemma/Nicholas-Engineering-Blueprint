#!/usr/bin/env bash
# Foundations 02 captures. Runs as "ada" (uid 1000) in a fresh ubuntu:24.04 container,
# after the Foundations 01 setup. Each command's output goes to /cap/NN-name.txt.
set -u
export LANG=C.UTF-8
cap() { local name=$1; shift; { echo "\$ $*"; bash -lc "cd ~/blueprint/machine 2>/dev/null; $*" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"; }
F=/final

# ---- the state after Foundations 01 (not captured)
sudo apt-get update -qq && sudo apt-get install -y -qq build-essential curl git unzip >/dev/null 2>&1
cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
git config --global user.name "Ada Lovelace"; git config --global user.email "ada@example.com"; git config --global init.defaultBranch main
mkdir -p ~/blueprint/day1 && cd ~/blueprint/day1 && bash -lc 'go mod init blueprint/day1' >/dev/null 2>&1
cp /snap/day1-main.go ~/blueprint/day1/main.go
cd ~

# ---- L01 the terminal
cap 0101-pwd 'cd ~ && pwd && whoami'
cap 0102-ls 'cd ~ && ls && ls -la'
cap 0103-mkdir 'mkdir -p ~/blueprint/machine/notes && cd ~/blueprint/machine && pwd && ls'
cap 0104-paths 'cd notes && pwd && cd .. && pwd && cd /tmp && pwd && cd ~/blueprint/machine && pwd'
cap 0105-files 'echo "hello" > notes/first.txt && echo "second line" >> notes/first.txt && cat notes/first.txt && echo "replaced" > notes/second.txt && cat notes/second.txt'
cap 0106-pipe-count 'ls /usr/bin | wc -l'
cap 0107-pipe-shells 'cut -d: -f7 /etc/passwd | sort | uniq -c | sort -rn'
cap 0108-stderr 'ls notes /nonexistent'
cap 0109-stderr-file 'ls notes /nonexistent 2> errors.txt; echo "---"; cat errors.txt; rm errors.txt'
cap 0110-not-dir 'cd notes/first.txt'
cap 0111-largest 'ls -S /usr/bin | head -3'
cap 0112-help 'ls --help | head -5'

# ---- L02 permissions
cap 0201-id 'id'
cap 0202-ls-l 'ls -l notes/first.txt'
printf '#!/usr/bin/env bash\necho "Hello from a script"\n' > ~/blueprint/machine/hello.sh
cap 0203-hello-cat 'cat hello.sh && ls -l hello.sh'
cap 0204-hello-denied './hello.sh'
cap 0205-hello-bash 'bash hello.sh'
cap 0206-hello-chmod 'chmod +x hello.sh && ls -l hello.sh && ./hello.sh'
cap 0207-hello-name 'hello.sh'
cap 0208-octal 'echo "my secret" > secret.txt && chmod 600 secret.txt && ls -l secret.txt && chmod 644 secret.txt && ls -l secret.txt && chmod 600 secret.txt'
cap 0209-dir-noexec 'mkdir -p box && echo inside > box/note.txt && chmod 600 box && ls -ld box; ls box; cd box; cat box/note.txt'
cap 0210-dir-fix 'chmod 700 box && ls -ld box && cat box/note.txt'
cap 0211-root 'ls -ld /root; ls /root; sudo ls -la /root | head -4'
cap 0212-hidden 'ls -a ~ && echo "$HOME"'

# ---- L03 storing data
cap 0301-binary 'echo $((2#1010)) && echo $((2#11111111)) && echo $((0xff)) && printf "%x\n" 255 && printf "%d\n" 0x41'
cap 0302-limits 'echo $((2**62)) && echo $((2**63 - 1)) && echo $((2**63)) && echo $((9223372036854775807 + 1))'
cap 0303-xxd-missing 'printf A | xxd'
sudo apt-get install -y -qq xxd >/dev/null 2>&1
cap 0304-text 'printf A | xxd && printf "Hi\n" | xxd'
cap 0305-utf8 'printf "é" | xxd && printf "café" | wc -c && printf "café" | wc -m'
cap 0306-source-bytes 'xxd ~/blueprint/day1/main.go | head -3'
cap 0307-binary-bytes 'cd ~/blueprint/day1 && go build -o day1 . && xxd day1 | head -2 && ls -l day1'
cap 0308-bigfile 'dd if=/dev/urandom of=big.bin bs=1048576 count=512 status=none && ls -l big.bin'
cap 0309-read-cold 'sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null && time cat big.bin > /dev/null'
cap 0310-read-warm 'time cat big.bin > /dev/null'
cap 0311-read-warm2 'time cat big.bin > /dev/null'
rm -f ~/blueprint/machine/big.bin

# ---- L04 programs and processes
cap 0401-program 'cd ~/blueprint/day1 && ls -l day1 && ./day1'
cap 0402-sleep 'echo "this shell: $$"; sleep 300 & echo "started: $!"; ps -o pid,ppid,stat,etime,command -p $!; kill $!'
cap 0403-proc 'sleep 300 & p=$!; ls /proc/$p | head -12; echo "---"; tr "\0" " " < /proc/$p/cmdline; echo; grep -E "^(Name|State|PPid|VmRSS)" /proc/$p/status; kill $p'
cap 0404-fds 'script -qc "bash --norc -i -c \"ls -l /proc/\\\$\\\$/fd; true\"" /dev/null | tr -d "\r"'
cap 0405-signal 'sleep 300 & p=$!; kill -TERM $p; wait $p; echo "exit status: $?"'
cap 0406-kill-l 'kill -l | head -3'
cap 0407-exit-codes 'true; echo "true: $?"; false; echo "false: $?"; ls /nope 2>/dev/null; echo "ls /nope: $?"; nosuchcommand 2>/dev/null; echo "nosuchcommand: $?"; chmod -x hello.sh; ./hello.sh 2>/dev/null; echo "not executable: $?"; chmod +x hello.sh'
cap 0408-redirect 'ls notes /nope > out.txt 2>&1; cat out.txt; echo "---"; wc -l < notes/first.txt; rm out.txt'
cat > ~/blueprint/machine/catch.sh <<'SH'
#!/usr/bin/env bash
trap 'echo "got TERM, cleaning up"; exit 0' TERM
echo "pid $$, waiting"
while :; do
  sleep 1
done
SH
chmod +x ~/blueprint/machine/catch.sh
cap 0409-trap './catch.sh & p=$!; sleep 0.5; kill -TERM $p; wait $p; echo "exit status: $?"'
sudo apt-get install -y -qq lsof >/dev/null 2>&1
cap 0410-lsof 'sleep 300 & p=$!; lsof -p $p | head -6; kill $p'

# ---- L05 shell scripts: monitor.sh, step by step (snapshots in /snap/monitor-N.sh)
for n in 1 2 3 4 5; do
  cp /snap/monitor-$n.sh ~/blueprint/machine/monitor.sh; chmod +x ~/blueprint/machine/monitor.sh
  cap 05$n-monitor './monitor.sh'
done
cap 0510-loadavg 'cat /proc/loadavg'
cap 0511-meminfo 'grep -E "^(MemTotal|MemFree|MemAvailable):" /proc/meminfo'
cap 0512-df 'df -P /'
cap 0513-memfree 'awk "/^MemTotal:/ {t=\$2} /^MemFree:/ {f=\$2} /^MemAvailable:/ {a=\$2} END {printf \"used, counting MemFree: %d%%\nused, counting MemAvailable: %d%%\n\", (t-f)*100/t, (t-a)*100/t}" /proc/meminfo'
cap 0514-nopath './monitor.sh /nope; echo "exit status: $?"'
cap 0515-tmp './monitor.sh /tmp'
cap 0516-loop 'for i in 1 2 3; do ./monitor.sh; sleep 1; done'
sudo apt-get install -y -qq shellcheck >/dev/null 2>&1
sed 's/df -P "$path"/df -P $path/' /final/monitor.sh > ~/blueprint/machine/monitor.sh
cap 0517-shellcheck-warn 'shellcheck monitor.sh'
cp /final/monitor.sh ~/blueprint/machine/monitor.sh
cap 0518-shellcheck-clean 'shellcheck monitor.sh && echo "no warnings"'

# ---- L06 git
cap 0601-init 'git init && git status'
printf '*.log\n*.log.*\n*.pid\n*.last\nbig.bin\nbox/\nsecret.txt\n' > ~/blueprint/machine/.gitignore
cap 0602-add 'git add monitor.sh .gitignore && git status --short && git commit -m "Add the system monitor"'
cap 0603-log 'git log --oneline'
sed -i 's|^#   load1=0.52 mem_used_pct=41 disk_used_pct=63$|#   load1=0.52 mem_used_pct=41 disk_used_pct=63\n# Works on Linux (from /proc) and macOS (from sysctl and vm_stat).|' ~/blueprint/machine/monitor.sh
cap 0604-diff 'git diff'
cap 0605-commit2 'git commit -am "Say which systems the monitor supports" && git log --oneline'
cap 0606-branch 'git switch -c usage && git branch'
cp /snap/monitor-usage.sh ~/blueprint/machine/monitor.sh
cap 0607-usage-diff 'git diff --stat && ./monitor.sh --help; echo "exit status: $?"'
cap 0608-usage-commit 'git commit -am "Add --help" && git switch main && git merge usage && git log --oneline --graph'
echo "garbage" >> ~/blueprint/machine/monitor.sh
cap 0609-restore 'git status --short && git restore monitor.sh && git status --short && echo "clean again"'
echo 'echo "debug: done" >&2' >> ~/blueprint/machine/monitor.sh
cap 0610-revert-setup 'git commit -qam "Print a debug line" && ./monitor.sh && git log --oneline | head -2'
cap 0611-revert 'git revert --no-edit HEAD && git log --oneline | head -3 && ./monitor.sh'

# ---- L07 log rotation
mkdir -p ~/blueprint/machine/logs
cp /final/writer.sh /final/check_lines.sh /final/rotate_copytruncate.sh ~/blueprint/machine/; chmod +x ~/blueprint/machine/*.sh
cap 0701-writer 'cd logs && ../writer.sh app.log & sleep 0.5; kill -TERM $(cat logs/app.log.pid); sleep 0.2; cd logs && wc -l app.log && head -3 app.log && cat app.log.last && rm app.log*'
cap 0702-naive 'cd logs && ../writer.sh app.log & sleep 0.3; for i in $(seq 10); do (cd logs && ../rotate_copytruncate.sh app.log); sleep 0.2; done; kill -TERM $(cat logs/app.log.pid); sleep 0.3; cd logs && ls && ../check_lines.sh app.log && rm app.log*'
cap 0703-inode 'cd logs && ../writer.sh app.log & sleep 0.3; cd logs; p=$(cat app.log.pid); ls -i app.log; ls -l /proc/$p/fd/3; mv app.log app.log.1; ls -i app.log.1; ls -l /proc/$p/fd/3; kill -HUP $p; sleep 0.2; ls -i app.log app.log.1; ls -l /proc/$p/fd/3; kill -TERM $p; sleep 0.2; rm -f app.log*'
rot() {  # rot NAME ROUNDS KEEP: writer + ROUNDS rotations, then count lines
  cap "$1" "cd logs && ../writer.sh app.log & sleep 0.3; for i in \$(seq $2); do (cd logs && ../rotate.sh app.log $3); sleep 0.2; done; kill -TERM \$(cat logs/app.log.pid); sleep 0.3; cd logs && ls && ../check_lines.sh app.log; rm -f app.log*"
}
cp /snap/rotate-1.sh ~/blueprint/machine/rotate.sh; chmod +x ~/blueprint/machine/rotate.sh
rot 0704-rotate-1-once 1 3
rot 0705-rotate-1-twice 2 3
cp /snap/rotate-2.sh ~/blueprint/machine/rotate.sh
rot 0706-rotate-2 10 20
cp /snap/rotate-3.sh ~/blueprint/machine/rotate.sh
rot 0707-rotate-3-keep3 10 3
rot 0708-rotate-3-keep20 10 20
cap 0709-gate 'bash /gate/run.sh ~/blueprint/machine'

