#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # commands are quoted on purpose: they run inside the capture shell
set -u
cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
for c in good slurp shortlines tie exitcode race; do
  mkdir -p ~/g/$c && cp -r /src/$c/. ~/g/$c/
  { echo "\$ bash gate/run.sh ~/blueprint/gofromzero   # $c"; bash -lc "bash /gate/run.sh ~/g/$c" 2>&1; echo "[exit $?]"; } > /cap/gate-$c.txt
done
