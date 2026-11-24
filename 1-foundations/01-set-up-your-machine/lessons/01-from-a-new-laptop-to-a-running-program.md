# 01 From a new laptop to a running program

> Module: Set up your machine · Time: ~45 min · Builds on: nothing

## The problem

You want to write code that runs on servers. Almost every server on the internet runs **Linux**, and almost every tool in this course (Docker, Kubernetes, `perf`, the networking tools) is built for it. If your laptop runs Windows or macOS, the commands in later lessons won't behave the same, and you'll spend your time fighting the machine instead of learning.

So before any code, you need three things that work: a Linux shell, Git, and Go. This lesson gets you there and proves it, with one command at the end of each step that says whether that step worked.

## The mental model

~~~text
 your laptop
 ┌─────────────────────────────────────────────────────────┐
 │  Windows or macOS (or Linux itself)                      │
 │   ┌──────────────┐        ┌───────────────────────────┐  │
 │   │ VS Code      │ edits  │ Linux                     │  │
 │   │ (the editor) │ ─────▶ │  shell: where you type    │  │
 │   └──────────────┘        │  git:   saves versions    │  │
 │                           │  go:    builds programs   │  │
 │                           │  ~/blueprint: your code   │  │
 │                           └───────────────────────────┘  │
 └─────────────────────────────────────────────────────────┘
~~~

- On **Windows**, Linux runs beside Windows in **WSL2** (Windows Subsystem for Linux): a real Linux kernel in a lightweight virtual machine. Your code lives inside it.
- On **macOS**, the system underneath is a Unix very close to Linux, so the same commands mostly work. Later modules that need Linux itself use containers.
- On **Linux**, you're already there.

## The pattern

**Install, then verify.** Every tool you install in this course ends with one command and the output it should print. If the output matches, move on. If it doesn't, stop and fix it now: a broken setup only gets harder to diagnose later.

## Build it

### Step 1: A Linux shell

A **shell** is the program that reads the commands you type and runs them. You'll meet it properly in the next module; for now, you just need one.

**Windows (WSL2).** You need Windows 10 version 2004 or later, or Windows 11. Open **PowerShell as Administrator** (right-click the Start button, then "Terminal (Admin)") and run:

~~~powershell
wsl --install -d Ubuntu-24.04
~~~

Restart when it asks. Then open **Ubuntu 24.04** from the Start menu. The first time, it asks you to create a Linux username and password. They're separate from your Windows account; remember the password, because `sudo` will ask for it.

Check that it's WSL **2**, from PowerShell:

~~~powershell
wsl -l -v
~~~

The `VERSION` column for Ubuntu-24.04 must say `2`.

**macOS.** Open **Terminal** (press Cmd+Space, type "Terminal"). Install Apple's command-line developer tools, which include Git and a compiler:

~~~bash
xcode-select --install
~~~

**Linux.** Open your terminal. You already have a shell.

**On Windows (inside Ubuntu) and on Linux,** install the basic build tools. `sudo` runs one command as the administrator, so it asks for the password you just created:

~~~bash
sudo apt update && sudo apt install -y build-essential curl git unzip
~~~

The output is long, and its details vary. It has worked if it ends without a line starting with `E:`.

**Verify:**

~~~bash
uname -s
~~~

~~~text
Linux
~~~

On macOS it prints `Darwin`, the name of the system underneath macOS.

### Step 2: Git, configured

**Git** saves versions of your work, so you can always go back, and it's how code moves between you and everyone else. Tell it who you are once; every version you save carries this name and email:

~~~bash
git config --global user.name "Ada Lovelace"
git config --global user.email "ada@example.com"
git config --global init.defaultBranch main
~~~

Use your own name and email. If you'll publish code on GitHub later, use the email of your GitHub account.

**Verify:**

~~~bash
git config --global --list
~~~

~~~text
user.name=Ada Lovelace
user.email=ada@example.com
init.defaultbranch=main
~~~

### Step 3: Go, installed and checked

**Go** is the language you'll write first. Download it from Go's own site, then **check the download** before installing it: a checksum is a fingerprint of the file, and the one published on [go.dev/dl](https://go.dev/dl/) tells you the file you received is exactly the one Go released.

**Windows (inside Ubuntu) and Linux** on a normal PC (`uname -m` prints `x86_64`):

~~~bash
cd ~
curl -fsSLO https://go.dev/dl/go1.27.4.linux-amd64.tar.gz
echo "7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840  go1.27.4.linux-amd64.tar.gz" | sha256sum --check
~~~

~~~text
go1.27.4.linux-amd64.tar.gz: OK
~~~

If `uname -m` prints `aarch64` instead (an ARM machine), use `go1.27.4.linux-arm64.tar.gz` and its checksum, `3392582988a273a87ab5043ee1b2c9c17a2c3c00580bf9326c47a2e0aaaeac92`, in both commands.

A damaged or tampered file looks like this. If you see it, delete the file and download again; never install it:

~~~text
go1.27.4.linux-amd64.tar.gz: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
~~~

Now unpack it into `/usr/local/go`, replacing any older Go, and delete the download:

~~~bash
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.27.4.linux-amd64.tar.gz
rm go1.27.4.linux-amd64.tar.gz
~~~

Go is installed, but your shell can't find it yet:

~~~bash
go version
~~~

~~~text
bash: go: command not found
~~~

The shell looks for commands in the folders listed in a variable called `PATH`. Add Go's folder to it, in the file your shell reads when it starts, then reload that file:

~~~bash
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
source ~/.profile
~~~

**macOS.** Download the installer for your Mac from [go.dev/dl](https://go.dev/dl/): `go1.27.4.darwin-arm64.pkg` for Apple silicon (M1 and later), `go1.27.4.darwin-amd64.pkg` for Intel. Check it in Terminal, from your Downloads folder:

~~~bash
cd ~/Downloads
shasum -a 256 go1.27.4.darwin-arm64.pkg
~~~

The result must be `2c13315bb6e702283547083be8f43803d178355ff74e9e7ff2692175b1655760` (or `98b6668684006873a3befee5cf155a110f79c3156ac718ddf45f59e4043a16b9` for the Intel package). Then open the `.pkg` and follow the installer. It sets up `PATH` for you; close Terminal and open a new one.

**Verify, on every system:**

~~~bash
go version
~~~

~~~text
go version go1.27.4 linux/amd64
~~~

On a Mac it ends `darwin/arm64` or `darwin/amd64`. Any Go from 1.26 up works for this course; a newer release than 1.27.4 is fine.

### Step 4: Your editor

Install **[VS Code](https://code.visualstudio.com/)** on your main system (Windows or macOS), then add its official **Go** extension (search the Extensions panel for "Go", published by the Go Team at Google).

**Windows:** also install the **WSL** extension (published by Microsoft). Then, inside your Ubuntu terminal, go to a folder and run `code .`: VS Code opens connected to Linux, and edits and runs everything there. Keep your code in your Linux home folder (`~`, which is `/home/your-name`), **never** under `/mnt/c/...`: those are Windows folders, reached across a bridge that makes builds many times slower.

**Verify:** in VS Code, the bottom-left corner says **WSL: Ubuntu-24.04** (Windows only), and opening a `.go` file in the next step shows its code in colour.

### Step 5: Your first program

Make a folder for it, and turn the folder into a Go **module**, Go's word for a project:

~~~bash
mkdir -p ~/blueprint/day1 && cd ~/blueprint/day1
go mod init blueprint/day1
~~~

<!-- run: go mod init blueprint/day1 -->

~~~text
go: creating new go.mod: module blueprint/day1
~~~

Create a file called `main.go` in that folder (in VS Code: `code .`, then File → New File) with exactly this:

<!-- file: main.go -->
~~~go
package main

import (
	"fmt"
	"runtime"
)

func main() {
	fmt.Printf("Blueprint ready! OS: %s | Arch: %s | CPUs: %d\n", runtime.GOOS, runtime.GOARCH, runtime.NumCPU())
}
~~~

You'll understand every word of it in [Go from zero](../../03-go-from-zero/README.md). For now: it asks Go's `runtime` package which operating system, which processor type and how many processors it's running on, and prints them.

Run it:

~~~bash
go run .
~~~

<!-- run: go vet ./... && go run . | grep -Eqx 'Blueprint ready! OS: [a-z]+ \| Arch: [a-z0-9]+ \| CPUs: [0-9]+' -->

~~~text
Blueprint ready! OS: linux | Arch: amd64 | CPUs: 16
~~~

Your CPU count will differ. Compare it with what the system itself reports:

~~~bash
uname -s && uname -m && nproc
~~~

~~~text
Linux
x86_64
16
~~~

`x86_64` and `amd64` are two names for the same processor type. (On macOS, `nproc` doesn't exist; use `sysctl -n hw.logicalcpu`.)

**What a failure looks like.** Change `Printf` to `PrintF` and run it again:

~~~text
# blueprint/day1
./main.go:9:6: undefined: fmt.PrintF (but have Printf)
~~~

The program never started: Go checks every name before it builds anything, and Go is case-sensitive. `./main.go:9:6` means file `main.go`, line 9, column 6. Read the first error line carefully; it nearly always tells you exactly what's wrong. Change it back.

<details>
<summary>Stuck?</summary>

- **`go: command not found`:** open a new terminal (or run `source ~/.profile`), then `go version` again. If it still fails, check that `/usr/local/go/bin/go version` works; if it does, the `PATH` line in step 3 is missing or mistyped.
- **`go: cannot find main module`:** you're not in `~/blueprint/day1`. Run `cd ~/blueprint/day1`.
- **`no required module provides package`** or a different module name: delete `go.mod` and rerun `go mod init blueprint/day1` in the right folder.

</details>

## Check it

Run the [gate](../gate/README.md) against your folder:

~~~bash
bash ~/path/to/Nicholas-Engineering-Blueprint/1-foundations/01-set-up-your-machine/gate/run.sh ~/blueprint/day1
~~~

(If you haven't downloaded this repository yet, `git clone https://github.com/nickemma/Nicholas-Engineering-Blueprint.git` in your home folder first; then the path is `~/Nicholas-Engineering-Blueprint/...`.)

~~~text
PASS  Go is installed (go1.27.4)
PASS  Git identity is set (Ada Lovelace <ada@example.com>)
PASS  Your code lives inside Linux (/home/ada/blueprint/day1)
PASS  Your program reports this machine: OS: linux | Arch: amd64 | CPUs: 16
Gate passed: your machine is ready for Foundations 02.
~~~

<!-- run: g=$(mktemp) && git config --file "$g" user.name "Ada Lovelace" && git config --file "$g" user.email ada@example.com && GIT_CONFIG_GLOBAL="$g" bash "$BLUEPRINT_ROOT/1-foundations/01-set-up-your-machine/gate/run.sh" . -->

The "inside Linux" line appears only on WSL. This proves your tools work and your program reports the machine it runs on. It doesn't prove you understand the program yet: that's the next three modules.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `wsl --install` says the command isn't found | Windows is older than version 2004 | Update Windows, then retry |
| `wsl -l -v` shows `VERSION 1` | The distribution was installed as WSL 1 | In PowerShell: `wsl --set-version Ubuntu-24.04 2` |
| `E: Unable to locate package` from `apt install` | The package list wasn't downloaded | Run `sudo apt update` first, then the install again |
| `sha256sum` says `FAILED` | The download is damaged or isn't the released file | Delete it and download again. Never install a file that fails its checksum |
| `go: command not found` after installing | `PATH` doesn't include `/usr/local/go/bin` yet | `source ~/.profile`, or open a new terminal |
| `go version` shows an old version | An older Go installed by `apt` comes first in `PATH` | `sudo apt remove golang-go`, then open a new terminal |
| Builds are very slow on Windows | Your code is under `/mnt/c/...` | Move it into your Linux home (`~`) |
