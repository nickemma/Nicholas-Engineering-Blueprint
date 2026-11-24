# 04 Programs and processes

> Module: How the machine works · Time: ~4 h · Builds on: 03

## The problem

"The service is down" almost always means one of a few things: a process died, a process is stuck, or a process was told to stop and didn't clean up. To diagnose any of it, you need to tell a *program* (a file on disk) from a *process* (that program running), find a process, see what it's doing, and talk to it with signals. Every later module relies on this, from graceful shutdown in Go to Kubernetes restarting your containers.

## The mental model

~~~text
 on disk                          in memory, running
 ┌──────────────┐   start it      ┌─────────────────────────────────┐
 │ day1         │ ──────────────▶ │ process 4759                    │
 │ (a program,  │                 │  parent: 4757 (your shell)      │
 │  just bytes) │                 │  open files: 0 stdin, 1 stdout, │
 └──────────────┘                 │              2 stderr, ...      │
                                  │  state: running or sleeping     │
                                  └──────────▲──────────────────────┘
                                             │ signals (TERM, KILL, HUP...)
                                       you, with kill
~~~

A **program** is a file. A **process** is the operating system running a copy of it, with its own memory, its own **process ID** (PID), a **parent** (the process that started it), and a list of open files. The same program can be running as many processes at once.

## The pattern

**Processes are controlled from outside, through signals, and report back through exit codes.** A well-behaved process catches the "please stop" signal, cleans up, and exits with a code that says whether it succeeded.

## Build it

### Step 1: A program, then a process

You built `day1` in the last lesson. On disk, it's a file:

~~~bash
cd ~/blueprint/day1 && ls -l day1 && ./day1
cd ~/blueprint/machine
~~~

~~~text
-rwxrwxr-x 1 ada ada 2359414 Nov 18 16:47 day1
Blueprint ready! OS: linux | Arch: amd64 | CPUs: 16
~~~

`./day1` turned the file into a process, which printed one line and exited, all within a few milliseconds: too fast to look at. `sleep 300` runs for 300 seconds, which is long enough. A trailing `&` runs it in the **background**, so your shell stays free:

~~~bash
echo "this shell: $$"; sleep 300 & echo "started: $!"; ps -o pid,ppid,stat,etime,command -p $!
~~~

~~~text
this shell: 4757
started: 4759
    PID    PPID STAT     ELAPSED COMMAND
   4759    4757 S          00:00 sleep 300
~~~

- `$$` is your shell's own PID; `$!` is the PID of the last process started in the background.
- `ps` lists processes. `-p` picks which ones; `-o` picks the columns.
- The `sleep` process (4759) has your shell (4757) as its **parent** (`PPID`). Every process has a parent; follow them up and you reach process 1, the first process the system started.
- `STAT` `S` means **sleeping**: waiting, not using the CPU. `R` would mean running.

Your PIDs will differ. Stop it with `kill $!` (step 3 explains `kill`).

### Step 2: What Linux knows about a process

Linux publishes everything it knows about each process as files in `/proc/PID/`. Nothing there is stored on disk; the kernel generates it when you read it.

~~~bash
sleep 300 & p=$!
ls /proc/$p | head -12
tr "\0" " " < /proc/$p/cmdline; echo
grep -E "^(Name|State|PPid|VmRSS)" /proc/$p/status
kill $p
~~~

~~~text
arch_status
attr
auxv
cgroup
clear_refs
cmdline
comm
coredump_filter
cpuset
cwd
environ
exe
sleep 300 
Name:	sleep
State:	S (sleeping)
PPid:	4761
VmRSS:	    1988 kB
~~~

`cmdline` is the command that started it (its words are separated by zero bytes, which `tr` turns into spaces). `status` says what it's doing and `VmRSS` how much RAM it's actually using: about 2 MB. `ps`, `top` and every monitoring tool get their numbers from these files. Try `top` now (press `q` to quit): it's a live view of the same data.

**macOS** has no `/proc`. Use `ps` (it works the same) and, for open files, `lsof` (step 4).

### Step 3: Signals and exit codes

A **signal** is a short message from the kernel to a process. The common ones:

~~~bash
kill -l | head -3
~~~

~~~text
 1) SIGHUP	 2) SIGINT	 3) SIGQUIT	 4) SIGILL	 5) SIGTRAP
 6) SIGABRT	 7) SIGBUS	 8) SIGFPE	 9) SIGKILL	10) SIGUSR1
11) SIGSEGV	12) SIGUSR2	13) SIGPIPE	14) SIGALRM	15) SIGTERM
~~~

| Signal | Number | Means | Sent by |
|---|---|---|---|
| `SIGTERM` | 15 | Please stop: tidy up and exit | `kill PID` (the default), Kubernetes, `systemd` |
| `SIGINT` | 2 | Interrupt | Ctrl+C in the terminal |
| `SIGKILL` | 9 | Stop *now* | `kill -9 PID`. It can't be caught, so nothing gets cleaned up |
| `SIGHUP` | 1 | Hang up; by convention, "reload your settings" or "reopen your files" | `kill -HUP PID` |

Every process ends with an **exit code**, a number from 0 to 255: 0 means success, anything else means failure. `$?` holds the last one:

~~~bash
true; echo "true: $?"
false; echo "false: $?"
ls /nope 2>/dev/null; echo "ls /nope: $?"
nosuchcommand 2>/dev/null; echo "nosuchcommand: $?"
chmod -x hello.sh; ./hello.sh 2>/dev/null; echo "not executable: $?"; chmod +x hello.sh
~~~

<!-- run: true; [ $? = 0 ]; false || [ $? = 1 ]; ls /nope 2>/dev/null || [ $? = 2 ] -->

~~~text
true: 0
false: 1
ls /nope: 2
nosuchcommand: 127
not executable: 126
~~~

`127` always means "command not found" and `126` "found but can't run it". A process killed by a signal exits with 128 plus the signal's number:

~~~bash
sleep 300 & p=$!; kill -TERM $p; wait $p; echo "exit status: $?"
~~~

<!-- run: sleep 300 & p=$!; kill -TERM $p; wait $p; [ $? = 143 ] -->

~~~text
exit status: 143
~~~

`143` = 128 + 15 (`SIGTERM`). `wait` waits for a background process to finish and gives you its exit code. When a container in Kubernetes shows "exit code 137", you'll now know: 128 + 9, it was killed with `SIGKILL`.

### Step 4: Standard input, output and error are open files

Every process starts with three open files, numbered: **0** standard input (what it reads), **1** standard output and **2** standard error. Those numbers are **file descriptors**. Look at your shell's:

~~~bash
ls -l /proc/$$/fd
~~~

~~~text
total 0
lrwx------ 1 ada ada 64 Nov 18 16:47 0 -> /dev/pts/0
lrwx------ 1 ada ada 64 Nov 18 16:47 1 -> /dev/pts/0
lrwx------ 1 ada ada 64 Nov 18 16:47 2 -> /dev/pts/0
lrwx------ 1 ada ada 64 Nov 18 16:47 255 -> /dev/pts/0
~~~

All three point at `/dev/pts/0`, your terminal. (Bash also keeps descriptor 255 on the terminal for itself.) That's why `2>` in lesson 01 meant standard error: it redirects descriptor 2. A few more redirections:

~~~bash
ls notes /nope > out.txt 2>&1; cat out.txt; rm out.txt
wc -l < notes/first.txt
~~~

~~~text
ls: cannot access '/nope': No such file or directory
notes:
first.txt
second.txt
2
~~~

`2>&1` sends descriptor 2 wherever descriptor 1 is going, so both streams land in the file. `<` connects a file to standard input.

On both Linux and macOS, `lsof -p PID` lists every file a process has open (install it on Ubuntu with `sudo apt install -y lsof`):

~~~bash
sleep 300 & p=$!; lsof -p $p | head -6; kill $p
~~~

~~~text
COMMAND  PID USER   FD   TYPE DEVICE SIZE/OFF     NODE NAME
sleep   4850  ada  cwd    DIR   0,79     4096 34487407 /home/ada/blueprint/machine
sleep   4850  ada  rtd    DIR   0,79     4096 34461218 /
sleep   4850  ada  txt    REG   0,79    35336 34458177 /usr/bin/sleep
sleep   4850  ada  mem    REG   0,79   360460 34461728 /usr/lib/locale/C.utf8/LC_CTYPE
sleep   4850  ada  mem    REG   0,79       50 34461780 /usr/lib/locale/C.utf8/LC_NUMERIC
~~~

`cwd` is its current folder, `txt` the program it's running, and `mem` files it has mapped into memory.

### Step 5: Catching a signal

A process can **trap** a signal: run its own code when it arrives, instead of dying straight away. That's how a server finishes the requests it's handling before it stops. Here's the smallest version.

**Starter.** Write `catch.sh` so that, on `SIGTERM`, it prints `got TERM, cleaning up` and exits with code 0:

~~~bash
#!/usr/bin/env bash
# TODO: on TERM, print "got TERM, cleaning up" and exit 0
echo "pid $$, waiting"
while :; do
  sleep 1
done
~~~

`while :; do ... done` loops forever (`:` is a command that always succeeds).

<details>
<summary>Hint</summary>

`trap 'COMMANDS' SIGNAL` runs COMMANDS when SIGNAL arrives. Put it before the loop. Leave `SIG` off the name: `TERM`.

</details>

<details>
<summary>The answer</summary>

<!-- file: catch.sh -->
~~~bash
#!/usr/bin/env bash
trap 'echo "got TERM, cleaning up"; exit 0' TERM
echo "pid $$, waiting"
while :; do
  sleep 1
done
~~~

</details>

Make it executable, start it in the background, and stop it:

~~~bash
chmod +x catch.sh
./catch.sh & p=$!; sleep 0.5; kill -TERM $p; wait $p; echo "exit status: $?"
~~~

<!-- run: chmod +x catch.sh; ./catch.sh > catch.out & p=$!; sleep 0.5; kill -TERM $p; wait $p; s=$?; grep -qx "got TERM, cleaning up" catch.out && [ $s = 0 ] && rm catch.out -->

~~~text
pid 4796, waiting
got TERM, cleaning up
exit status: 0
~~~

Exit code 0 instead of 143: the script decided how to stop. Notice that the message took up to a second to appear. Bash runs a trap only once the command it's running, here `sleep 1`, has finished. Lesson 07 depends on this detail.

**Your turn.** Add a second trap, so that `kill -HUP` makes the script print `reloading` and keep running. Check it with `kill -HUP`, then stop it with `kill -TERM`.

## Check it

Start `catch.sh` in the background, and from the same terminal find its PID with `ps`, read its state from `/proc` (or `ps` on macOS), send it `SIGHUP` and then `SIGTERM`, and read its exit code with `wait`. If you can do all of that without the lesson, you can handle any process on a server. What this doesn't cover is processes that ignore `SIGTERM`; Core 01 builds a Go server that shuts down properly.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `kill: (4759) - No such process` | It already exited, or the PID is wrong | List what's running with `ps -ef` and check |
| A background job keeps printing into your terminal | Its output still goes to your terminal | Redirect it: `./catch.sh > out.txt &` |
| The trap message never appears | The process was killed with `-9`, which can't be trapped | Use `kill` or `kill -TERM` |
| `wait: pid 1234 is not a child of this shell` | You started it from another terminal | `wait` only works in the shell that started it |
| `lsof: command not found` | Not installed | `sudo apt install -y lsof` |
