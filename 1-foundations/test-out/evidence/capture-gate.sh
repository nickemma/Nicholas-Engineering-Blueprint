#!/usr/bin/env bash
# shellcheck disable=SC2016  # commands are quoted on purpose: they run inside the capture shell
# Test-out gate runs: a reference solution and eight broken versions, as "ada" in a
# fresh ubuntu:24.04 (blueprint-capture image), Go 1.27.4, uv 0.12.7, Python 3.14.
# Mounts: /ref /broken /gate (read-only), /cap (output). The reference isn't published.
set -u
cd ~ && curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
curl -fsSLO https://github.com/astral-sh/uv/releases/download/0.12.7/uv-x86_64-unknown-linux-gnu.tar.gz
tar -xzf uv-x86_64-unknown-linux-gnu.tar.gz && mkdir -p ~/.local/bin && mv uv-x86_64-unknown-linux-gnu/uv ~/.local/bin/
mkdir -p ~/g/good && cp -r /ref/. ~/g/good/
for v in slurp shortbuf rank floats extraarg traceback allfiles realtally; do mkdir -p ~/g/$v && cp -r /broken/$v/. ~/g/$v/; done
find ~/g \( -name .venv -o -name __pycache__ -o -name .pytest_cache -o -name .ruff_cache \) -prune -exec rm -rf {} +
for v in good slurp shortbuf rank floats extraarg traceback allfiles realtally; do
  { echo "\$ bash gate/run.sh ~/your-repo    # the $v version"; bash -lc "bash /gate/run.sh ~/g/$v" 2>&1; echo "[exit $?]"; } > /cap/gate-$v.txt
done
echo "gate captures done"
