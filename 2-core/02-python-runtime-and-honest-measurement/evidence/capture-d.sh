#!/usr/bin/env bash
# shellcheck disable=SC2016  # commands are quoted on purpose: they run inside the capture shell
# Core 02 capture, fourth run: httpx against kload's own Pool (probes/clients.py), against the
# gate's server with a 5 ms delay. Same image; mounts /final, /gate, /probes, /pbs, /uv; /cap.
set -u
export LANG=C.UTF-8 HOME=/home/ada
cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
mkdir -p ~/.local/bin && cp /uv/uv ~/.local/bin/
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/.local/bin' >> ~/.profile
bash -lc 'uv python install 3.14' > /dev/null 2>&1
cp -r /final ~/kload && rm -rf ~/kload/.venv
bash -lc 'cd /gate/delay-fixture && go build -o /tmp/target .' || exit 1
/tmp/target -addr 127.0.0.1:18081 -delay 5ms -log /tmp/arrivals.log > /dev/null &
sleep 0.5
{ echo '$ uv run python clients.py 18081'; bash -lc 'cd ~/kload && uv run python /probes/clients.py 18081' 2>&1 | grep -v 'Building\|Built\|Installed\|Download\|Prepared\|Resolved\|Using\|Creating'; echo "[exit ${PIPESTATUS[0]}]"; } > /cap/clients.txt
