#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
# Foundations 04 captures: user "ada" in a fresh ubuntu:24.04 (blueprint-capture image),
# Go 1.27.4, uv 0.12.7, Python 3.14. Mounts: /final /snap /variants (read-only), /cap (output).
set -u
export LANG=C.UTF-8
W=~/blueprint/internet

# cap NAME DIR COMMAND: run COMMAND in DIR as a login shell, save "$ COMMAND", its output
# and its exit code. Anything it left running in the background is stopped afterwards.
cap() {
  local name=$1 dir=$2
  shift 2
  { echo "\$ $*"; timeout 120 bash -lc "cd $dir; $*" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"
  pkill -x echo; pkill -x nc; pkill -f "python drills/trickle.py"; sleep 0.2
}

# One deliberate mistake, laid over ~/blueprint/internet, then undone.
vcap() {
  local name=$1 v=$2 dir=$3 f b
  shift 3
  while read -r f; do
    b="/tmp/bak-${f//\//_}"
    if [ -e "$W/$f" ]; then cp "$W/$f" "$b"; fi
  done < <(cd "/variants/$v" && find . -type f)
  cp -r "/variants/$v/." "$W/"
  cap "$name" "$dir" "$@"
  while read -r f; do
    b="/tmp/bak-${f//\//_}"
    if [ -e "$b" ]; then mv "$b" "$W/$f"; else rm -f "$W/$f"; fi
  done < <(cd "/variants/$v" && find . -type f)
  # Python's bytecode cache keys on mtime (whole seconds) and size: a same-size
  # file restored within the same second would keep running the mistake.
  find "$W" -name __pycache__ -prune -exec rm -rf {} +
}

# ------------------------------------------------------------ setup: Go, as Foundations 01 does
cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
mkdir -p "$W"

# ------------------------------------------------------------ lesson 01
cap 0101-apt '~' 'sudo apt-get update -qq && sudo apt-get install -y iproute2 iputils-ping traceroute dnsutils netcat-openbsd tcpdump curl 2>&1 | tail -3'
cap 0102-ip-addr '~' 'ip addr'
cap 0103-ip-route '~' 'ip route'
cap 0104-ping-loopback '~' 'ping -c 3 127.0.0.1'
cap 0105-ping-remote '~' 'ping -c 3 one.one.one.one'
cap 0106-traceroute '~' 'traceroute -n -m 3 -q 1 1.1.1.1'
cap 0107-lost '~' 'ping -c 2 -W 1 10.255.255.1'

# ------------------------------------------------------------ lesson 02
cap 0201-getent '~' 'getent hosts localhost'
cap 0202-hosts '~' 'cat /etc/hosts'
cap 0203-resolv '~' 'grep -v "^#" /etc/resolv.conf | grep .'
cap 0204-dig '~' 'dig example.com'
cap 0205-ttl '~' 'dig +noall +answer example.com; sleep 10; dig +noall +answer example.com'
cap 0206-nxdomain '~' 'dig nosuch.invalid | grep -E "status|ANSWER:"; getent hosts nosuch.invalid; echo "getent exit: $?"'
cap 0207-trace '~' 'dig +trace +nodnssec @1.1.1.1 example.com'
cap 0209-trace-wsl '~' 'dig +trace +nodnssec example.com'
cap 0208-own-name '~' 'echo "127.0.0.1 blueprint.test" | sudo tee -a /etc/hosts && getent hosts blueprint.test && dig +short blueprint.test; echo "dig printed nothing: exit $?"; ping -c 1 blueprint.test'

# ------------------------------------------------------------ lesson 03
cap 0301-listen '~' 'nc -l 127.0.0.1 9000 > /tmp/got.txt & sleep 0.5; ss -tln; printf "hello\n" | nc -N 127.0.0.1 9000; sleep 0.3; cat /tmp/got.txt'
cap 0302-handshake '~' 'sudo tcpdump -i lo -n -l "port 9000" 2>/dev/null > /tmp/td.txt & sleep 1; nc -l 127.0.0.1 9000 > /dev/null & sleep 0.3; printf "hello\n" | nc -N 127.0.0.1 9000; sleep 0.5; sudo pkill tcpdump; sleep 0.3; cat /tmp/td.txt'
cap 0303-ss-established '~' 'nc -l 127.0.0.1 9000 > /dev/null & sleep 0.3; sleep 2 | nc -N 127.0.0.1 9000 & sleep 0.5; ss -tn state established "( sport = :9000 or dport = :9000 )"; wait'
cap 0304-refused '~' 'sudo tcpdump -i lo -n -l "port 9001" 2>/dev/null > /tmp/td.txt & sleep 1; nc -v 127.0.0.1 9001; echo "exit $?"; sleep 0.3; sudo pkill tcpdump; sleep 0.3; cat /tmp/td.txt'
cap 0305-udp '~' 'sudo tcpdump -i lo -n -l "udp port 9002" 2>/dev/null > /tmp/td.txt & sleep 1; nc -u -l 127.0.0.1 9002 > /tmp/u.txt & sleep 0.3; printf "one datagram\n" | nc -u -w1 127.0.0.1 9002; sleep 0.3; sudo pkill tcpdump; sleep 0.3; cat /tmp/td.txt; echo "--- the listener got:"; cat /tmp/u.txt'
cap 0306-udp-closed '~' 'sudo tcpdump -i lo -n -l "udp port 9003 or icmp" 2>/dev/null > /tmp/td.txt & sleep 1; printf "anyone there?\n" | nc -u -w1 127.0.0.1 9003; echo "exit $?"; sleep 0.3; sudo pkill tcpdump; sleep 0.3; cat /tmp/td.txt'

# ------------------------------------------------------------ lesson 04
cap 0401-mod-init "$W" 'mkdir echo && cd echo && go mod init echo && cat go.mod'
cp /snap/e1/main.go "$W/echo/"
cap 0402-serial-hello "$W/echo" 'go build -o /tmp/echo . && { /tmp/echo & sleep 0.5; printf "hello\n" | nc -N 127.0.0.1 9000; sleep 0.3; kill %1; }'
cap 0403-read-sizes "$W/echo" '/tmp/echo & sleep 0.5; head -c 200000 /dev/zero | tr "\0" x | nc -N 127.0.0.1 9000 | wc -c; sleep 0.3; kill %1'
cap 0404-serial-second "$W/echo" '/tmp/echo & sleep 0.5; sleep 3 | nc -N 127.0.0.1 9000 & sleep 0.3; date +%T; printf "second\n" | nc -N 127.0.0.1 9000; date +%T; wait $!; kill %1'
cp /snap/e2/main.go "$W/echo/"
cap 0405-goroutines "$W/echo" 'go build -o /tmp/echo . && { /tmp/echo & sleep 0.5; sleep 3 | nc -N 127.0.0.1 9000 & sleep 0.3; date +%T; printf "second\n" | nc -N 127.0.0.1 9000; date +%T; wait $!; kill %1; }'
cp /snap/e3/main.go "$W/echo/"
cap 0406-lines "$W/echo" 'go build -o /tmp/echo . && { /tmp/echo -addr 127.0.0.1:0 > /tmp/echo.out & sleep 0.5; cat /tmp/echo.out; port=$(sed "s/.*://" /tmp/echo.out); printf "one\ntwo\nno newline" | nc -N 127.0.0.1 $port | od -c; sleep 0.3; kill %1; }'
cp /snap/e4b/main.go "$W/echo/"
cap 0408-idle "$W/echo" 'go build -o /tmp/echo . && { /tmp/echo -idle 2s > /dev/null & sleep 0.5; date +%T; nc 127.0.0.1 9000; date +%T; kill %1; }'
cp /final/echo/main_test.go "$W/echo/"
cap 0409-test-reset "$W/echo" 'go test ./...'
cp /final/echo/main.go "$W/echo/"
cap 0411-test-linger "$W/echo" 'go test -race ./...'
cap 0412-test-final "$W/echo" 'gofmt -l . && go vet ./... && go test -race -v ./... 2>&1 | grep -E "^(=== RUN|--- |ok|FAIL|PASS)"'
vcap 0407-scanner l04-scanner "$W/echo" 'go build -o /tmp/echo . && { /tmp/echo > /dev/null & sleep 0.5; printf "windows\r\nlast" | nc -N 127.0.0.1 9000 | od -c; sleep 0.3; kill %1; }'
vcap 0413-closewait l04-closewait "$W/echo" 'go build -o /tmp/echo . && { /tmp/echo 2>/dev/null > /dev/null & p=$!; sleep 0.5; for i in 1 2 3; do printf "hi\n" | nc -N -w 1 127.0.0.1 9000 > /dev/null; done; sleep 0.3; ss -tn state close-wait; ls /proc/$p/fd | wc -l; kill $p; }'
cap 0414-fds "$W/echo" 'go build -o /tmp/echo . && { /tmp/echo 2>/dev/null > /dev/null & p=$!; sleep 0.5; for i in 1 2 3; do printf "hi\n" | nc -N -w 1 127.0.0.1 9000 > /dev/null; done; sleep 0.3; ss -tn state close-wait; ls /proc/$p/fd | wc -l; kill $p; }'

# ------------------------------------------------------------ lesson 05
cap 0501-curl-request '~' 'nc -l 127.0.0.1 8080 > /tmp/request.txt & sleep 0.3; curl -s -m 1 http://127.0.0.1:8080/health; echo "curl exit: $?"; cat -A /tmp/request.txt'
cap 0502-reply-by-hand '~' 'printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 16\r\n\r\n{\"status\":\"ok\"}\n" | nc -l 127.0.0.1 8080 > /dev/null & sleep 0.3; curl -sv http://127.0.0.1:8080/health'
cap 0503-real-by-hand '~' 'printf "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n" | nc example.com 80 | head -16 | cut -c1-72'
cap 0504-curl-v '~' 'curl -v -o /dev/null http://example.com/ 2>&1 | grep -E "^[<>*]"'
cap 0505-status '~' 'for path in / /nope; do curl -s -o /dev/null -w "GET $path -> %{http_code}\n" http://example.com$path; done; curl -s -o /dev/null -w "POST / -> %{http_code}\n" -X POST http://example.com/'
cap 0506-curl-echo "$W/echo" 'go build -o /tmp/echo . && { /tmp/echo 2>/dev/null > /dev/null & sleep 0.5; curl -sv -m 2 http://127.0.0.1:9000/hello; echo "curl exit: $?"; kill %1; }'
cap 0507-https '~' 'curl -sv -o /dev/null https://example.com/ 2>&1 | grep -E "^\* (Connected|SSL connection|TLS|Server certificate|.*subject:|.*issuer:)|^> GET|^< HTTP"'

# ------------------------------------------------------------ lesson 06
cap 0601-uv-install '~' 'curl -fsSLO https://github.com/astral-sh/uv/releases/download/0.12.7/uv-x86_64-unknown-linux-gnu.tar.gz && curl -fsSLO https://github.com/astral-sh/uv/releases/download/0.12.7/uv-x86_64-unknown-linux-gnu.tar.gz.sha256 && sha256sum -c uv-x86_64-unknown-linux-gnu.tar.gz.sha256 && tar -xzf uv-x86_64-unknown-linux-gnu.tar.gz && mkdir -p ~/.local/bin && mv uv-x86_64-unknown-linux-gnu/uv uv-x86_64-unknown-linux-gnu/uvx ~/.local/bin/ && rm -r uv-x86_64-unknown-linux-gnu uv-x86_64-unknown-linux-gnu.tar.gz uv-x86_64-unknown-linux-gnu.tar.gz.sha256'
cap 0602-uv-version '~' 'command -v uv && uv --version'
cap 0603-init "$W" 'mkdir measure && cd measure && uv init --bare --name measure --python 3.14 && uv python pin 3.14 && uv add --dev pytest ruff && ls -a'
cap 0604-python-version "$W/measure" 'uv run python --version'
cp /final/measure/pyproject.toml "$W/measure/"
sed -i '/^dependencies = \[$/,/^\]$/c\dependencies = []' "$W/measure/pyproject.toml"
cp /final/measure/hello.py "$W/measure/"
cap 0605-hello "$W/measure" 'uv run python hello.py'
mkdir -p "$W/measure/drills"
cp /final/measure/drills/values.py /final/measure/drills/containers.py /final/measure/drills/functions.py "$W/measure/drills/"
cap 0606-values "$W/measure" 'uv run python drills/values.py'
cap 0607-containers "$W/measure" 'uv run python drills/containers.py'
cap 0608-functions "$W/measure" 'uv run python drills/functions.py'
cp /snap/py06/stats.py /snap/py06/test_stats.py "$W/measure/"
cap 0609-pytest "$W/measure" 'uv run pytest -v'
cap 0610-ruff "$W/measure" 'uv run ruff format . && uv run ruff check .'
vcap 0611-indent l06-indent "$W/measure" 'uv run python bad.py'
cap 0612-hints "$W/measure" 'uv run python -c "from stats import summarize; summarize([\"12\", \"15\"])"'
cat "$W/measure/pyproject.toml" > /cap/0613-pyproject.txt

# ------------------------------------------------------------ lesson 07
cp /final/measure/drills/classes.py /final/measure/drills/errors.py "$W/measure/drills/"
cap 0701-classes "$W/measure" 'uv run python drills/classes.py'
cap 0702-frozen "$W/measure" 'PYTHONUNBUFFERED=1 uv run python -c "from drills.classes import Timed; t = Timed(1, 250.0); t.latency_ms = 1.0"'
cap 0703-traceback "$W/measure" 'uv run python -c "from pathlib import Path; Path(\"/nope\").read_text()"'
cap 0704-errors "$W/measure" 'uv run python drills/errors.py'
cp /final/measure/results.py /final/measure/test_results.py "$W/measure/"
cap 0705-roundtrip "$W/measure" 'uv run python -c "from pathlib import Path; from results import Result, write_csv, read_csv; write_csv(Path(\"try.csv\"), [Result(0, 0, 16, 0.4567)]); print(repr(Path(\"try.csv\").read_bytes())); print(read_csv(Path(\"try.csv\")))" && rm try.csv'
cap 0706-badrow "$W/measure" 'printf "request,connection,bytes,latency_ms\n0,0,16,fast\n" > bad.csv; uv run python -c "from pathlib import Path; from results import read_csv; read_csv(Path(\"bad.csv\"))" 2>&1 | tail -3; rm bad.csv'
cap 0707-pytest "$W/measure" 'uv run pytest -v test_results.py'
vcap 0708-csv2 l07-csv2 "$W/measure" 'uv run pytest -q test_results.py'
cap 0709-all "$W/measure" 'uv run ruff format --check . && uv run ruff check . && uv run pytest -q'

# ------------------------------------------------------------ lesson 08
cp /final/measure/drills/waits.py /final/measure/drills/talk.py /final/measure/drills/trickle.py /final/measure/drills/halves.py "$W/measure/drills/"
cap 0801-waits "$W/measure" 'uv run python drills/waits.py'
vcap 0802-blocking l08-blocking "$W/measure" 'uv run python drills/waits.py'
vcap 0803-noawait l08-noawait "$W/measure" 'uv run python drills/waits.py'
cap 0804-talk "$W/measure" '(cd ../echo && go build -o /tmp/echo .) && { /tmp/echo 2>/dev/null > /dev/null & sleep 0.5; uv run python drills/talk.py; kill %1; }'
cap 0805-halves "$W/measure" 'uv run python drills/trickle.py & sleep 2; uv run python drills/halves.py; kill %1'

# ------------------------------------------------------------ lesson 09
cp /snap/m1/measure.py "$W/measure/"
cap 0901-one-connection "$W/measure" '/tmp/echo 2>/dev/null > /dev/null & sleep 0.5; uv run measure.py; kill %1'
cp /final/measure/stats.py /final/measure/test_stats.py "$W/measure/"
cap 0902-percentile "$W/measure" 'uv run pytest -q test_stats.py'
cp /snap/m2/measure.py "$W/measure/"
cap 0903-many "$W/measure" '/tmp/echo 2>/dev/null > /dev/null & sleep 0.5; uv run measure.py --port 9000 && head -4 results.csv && wc -l results.csv; kill %1'
cap 0904-help "$W/measure" 'uv run measure.py --help'
cap 0905-refused "$W/measure" 'uv run measure.py --port 9000; echo "exit $?"'
cap 0906-add-matplotlib "$W/measure" 'uv add matplotlib 2>&1 | tail -3'
cp /final/measure/measure.py /final/measure/test_measure.py "$W/measure/"
cap 0907-plot "$W/measure" '/tmp/echo 2>/dev/null > /dev/null & sleep 0.5; uv run measure.py --port 9000 && ls -l latency.png; kill %1'
cp "$W/measure/latency.png" /cap/latency-10.png
cap 0908-pytest "$W/measure" 'uv run pytest -v test_measure.py'
cap 0909-all "$W/measure" 'uv run ruff format --check . && uv run ruff check . && uv run pytest -q'
cap 0910-connections "$W/measure" '/tmp/echo 2>/dev/null > /dev/null & sleep 0.5; for c in 1 10 100; do uv run measure.py --port 9000 --connections $c --csv c$c.csv --plot c$c.png; echo; done; kill %1'
cp "$W/measure/c1.png" /cap/latency-1.png; cp "$W/measure/c100.png" /cap/latency-100.png
cap 0911-by-size "$W/measure" 'for c in 1 100; do echo "connections: $c"; uv run python -c "
from pathlib import Path
from results import read_csv
from stats import percentile
results = read_csv(Path(\"c$c.csv\"))
for size in sorted({r.size for r in results}):
    ms = [r.latency_ms for r in results if r.size == size]
    print(f\"{size:>6} bytes: p50 {percentile(ms, 50):.3f} ms, p99 {percentile(ms, 99):.3f} ms\")
"; done'
cap 0912-nproc '~' 'nproc'
cp -r /gate "$W/../gate-f04"
cap 0913-gate "$W" 'bash ~/blueprint/gate-f04/run.sh ~/blueprint/internet'
echo "captures done"
