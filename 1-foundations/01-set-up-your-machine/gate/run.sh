#!/usr/bin/env bash
# Gate for Foundations 01: is this machine ready?
#
#   bash gate/run.sh ~/blueprint/day1
#
# Checks Go (1.26 or newer), Git's identity, and that your first program builds
# and reports this machine's OS, architecture and CPU count. On WSL it also checks
# that your code lives inside Linux, not in a Windows folder under /mnt/.
# Exits 0 when every check passes, 1 otherwise. Works with macOS's bash 3.2.

set -u

dir=${1:-}
failed=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; echo "      $2"; failed=1; }

if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "usage: bash gate/run.sh PATH_TO_YOUR_DAY1_FOLDER"
  exit 1
fi
dir=$(cd "$dir" && pwd -P)

# 1. Go 1.26 or newer, on the PATH.
if ! command -v go >/dev/null 2>&1; then
  fail "Go is installed" "'go' isn't on your PATH. Redo step 3, then open a new terminal."
else
  version=$(go env GOVERSION 2>/dev/null)            # e.g. go1.27.4
  minor=$(echo "$version" | sed -n 's/^go1\.\([0-9]*\).*/\1/p')
  if [ -n "$minor" ] && [ "$minor" -ge 26 ]; then
    pass "Go is installed ($version)"
  else
    fail "Go is 1.26 or newer" "found '$version'. Install the current release from step 3."
  fi
fi

# 2. Git knows who you are.
name=$(git config --global user.name 2>/dev/null)
email=$(git config --global user.email 2>/dev/null)
if [ -n "$name" ] && [ -n "$email" ]; then
  pass "Git identity is set ($name <$email>)"
else
  fail "Git identity is set" "run: git config --global user.name \"Your Name\" and git config --global user.email \"you@example.com\""
fi

# 3. On WSL, the code lives inside Linux.
if grep -qi microsoft /proc/version 2>/dev/null; then
  case "$dir" in
    /mnt/*) fail "Your code lives inside Linux" "$dir is a Windows folder. Move it under your Linux home (cd ~) and work there." ;;
    *) pass "Your code lives inside Linux ($dir)" ;;
  esac
fi

# 4. The first program builds and tells the truth about this machine.
if command -v go >/dev/null 2>&1; then
  if ! out=$(cd "$dir" && go run . 2>&1); then
    fail "Your program builds and runs" "go run . failed:
$out"
  else
    expected_os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$(uname -m)" in
      x86_64 | amd64) expected_arch=amd64 ;;
      aarch64 | arm64) expected_arch=arm64 ;;
      *) expected_arch=$(uname -m) ;;
    esac
    if command -v nproc >/dev/null 2>&1; then
      expected_cpus=$(nproc)
    else
      expected_cpus=$(sysctl -n hw.logicalcpu)
    fi
    expected="OS: $expected_os | Arch: $expected_arch | CPUs: $expected_cpus"
    if echo "$out" | grep -qF "$expected"; then
      pass "Your program reports this machine: $expected"
    else
      fail "Your program reports this machine" "expected a line containing '$expected', got: $out"
    fi
  fi
fi

if [ "$failed" -eq 0 ]; then
  echo "Gate passed: your machine is ready for Foundations 02."
else
  echo "Gate failed: fix the FAIL lines above and run it again."
fi
exit "$failed"
