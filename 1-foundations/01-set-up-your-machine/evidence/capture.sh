#!/usr/bin/env bash
# Runs inside a fresh ubuntu:24.04 container as user "ada" (sudo without password).
# Prints each command, then its real output, into /cap/NN-name.txt.
set -u
cap() { local name=$1; shift; { echo "\$ $*"; bash -lc "$*" 2>&1; echo "[exit $?]"; } > "/cap/$name.txt"; }
cd ~
cap 01-apt-install 'sudo apt-get update -qq && sudo apt-get install -y -qq build-essential curl git unzip >/dev/null && echo installed'
cap 02-git-version 'git --version'
cap 03-git-config 'git config --global user.name "Ada Lovelace" && git config --global user.email "ada@example.com" && git config --global init.defaultBranch main && git config --global --list'
cap 04-go-download 'curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz && ls -l go1.27.4.linux-amd64.tar.gz'
cap 05-go-checksum 'echo "7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840  go1.27.4.linux-amd64.tar.gz" | sha256sum --check'
cp go1.27.4.linux-amd64.tar.gz /tmp/bad.tar.gz && printf 'x' | dd of=/tmp/bad.tar.gz bs=1 seek=1000 conv=notrunc 2>/dev/null
cap 05b-go-checksum-bad 'cd /tmp && echo "7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840  bad.tar.gz" | sha256sum --check'
cap 06-go-before-path 'go version'
cap 07-go-extract 'sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz && rm go1.27.4.linux-amd64.tar.gz && ls /usr/local/go/bin'
cap 08-go-path 'echo '"'"'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin'"'"' >> ~/.profile && source ~/.profile && go version'
cap 09-day1-init 'mkdir -p ~/blueprint/day1 && cd ~/blueprint/day1 && go mod init blueprint/day1 && cat go.mod'
mkdir -p ~/blueprint/day1 && cat > ~/blueprint/day1/main.go <<'GO'
package main

import (
	"fmt"
	"runtime"
)

func main() {
	fmt.Printf("Blueprint ready! OS: %s | Arch: %s | CPUs: %d\n", runtime.GOOS, runtime.GOARCH, runtime.NumCPU())
}
GO
cap 10-day1-run 'cd ~/blueprint/day1 && go run .'
cap 11-day1-compare 'uname -s && uname -m && nproc'
sed -i 's/Printf/PrintF/' ~/blueprint/day1/main.go
cap 12-day1-typo 'cd ~/blueprint/day1 && go run .'
sed -i 's/PrintF/Printf/' ~/blueprint/day1/main.go
cap 13-gate-pass 'bash /gate/run.sh ~/blueprint/day1'
cap 14-gate-no-git 'mv ~/.gitconfig ~/.gitconfig.off && bash /gate/run.sh ~/blueprint/day1; s=$?; mv ~/.gitconfig.off ~/.gitconfig; exit $s'
sed -i 's/runtime.NumCPU()/runtime.NumCPU()+1/' ~/blueprint/day1/main.go
cap 15-gate-wrong-cpus 'bash /gate/run.sh ~/blueprint/day1'
sed -i 's/runtime.NumCPU()+1/runtime.NumCPU()/' ~/blueprint/day1/main.go
