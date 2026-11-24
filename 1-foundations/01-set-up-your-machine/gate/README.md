# Gate: Set up your machine

## What it checks

1. Go is on your `PATH`, at version 1.26 or newer.
2. Git knows your name and email.
3. On WSL: your code lives inside Linux, not in a Windows folder under `/mnt/`.
4. Your first program builds, runs, and reports this machine's OS, architecture and CPU count, matching what the system reports (`uname -s`, `uname -m`, and `nproc` or `sysctl -n hw.logicalcpu` on macOS).

## Run it

~~~bash
bash gate/run.sh ~/blueprint/day1
~~~

It needs only Go, Git and a shell, and takes a few seconds. It works on Linux, WSL and macOS.

## A pass looks like

~~~text
PASS  Go is installed (go1.27.4)
PASS  Git identity is set (Ada Lovelace <ada@example.com>)
PASS  Your code lives inside Linux (/home/ada/blueprint/day1)
PASS  Your program reports this machine: OS: linux | Arch: amd64 | CPUs: 16
Gate passed: your machine is ready for Foundations 02.
~~~

## A fail looks like

Each failing check says what's wrong and what to do. Git without an identity:

~~~text
FAIL  Git identity is set
      run: git config --global user.name "Your Name" and git config --global user.email "you@example.com"
~~~

Code kept in a Windows folder, on WSL:

~~~text
FAIL  Your code lives inside Linux
      /mnt/c/Users/Public/day1-gate-mTaI is a Windows folder. Move it under your Linux home (cd ~) and work there.
~~~

A program that misreports the machine (here, one CPU too many):

~~~text
FAIL  Your program reports this machine
      expected a line containing 'OS: linux | Arch: amd64 | CPUs: 16', got: Blueprint ready! OS: linux | Arch: amd64 | CPUs: 17
~~~

The gate was checked both ways: it passes on the lesson's program in a fresh Ubuntu 24.04, and fails on each of the three breakages above. The runs are in [evidence/](../evidence/).
