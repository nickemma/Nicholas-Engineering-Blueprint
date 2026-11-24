# 05 Shell scripts

> Module: How the machine works · Time: ~4 h · Builds on: 04

## The problem

You've typed the same commands three times today. On a server, you'll type them at the worst possible moment, under pressure, and get one wrong. A **script** saves the commands once, runs them the same way every time, and can be checked by a tool before it runs. This lesson builds a script you'll use for the rest of the course: a **system monitor** that prints, in one line, how loaded the machine is.

## The mental model

~~~text
 monitor.sh
   ├─ load1()          reads the load average  ◀── /proc/loadavg      (macOS: sysctl)
   ├─ mem_used_pct()   reads memory figures    ◀── /proc/meminfo      (macOS: vm_stat)
   ├─ disk_used_pct()  reads disk use          ◀── df
   └─ echo "load1=... mem_used_pct=... disk_used_pct=..."
~~~

The kernel already publishes every number you need, as text. The script's job is to read the right lines and turn them into one tidy line.

## The pattern

**Fail fast and loudly.** A script that carries on after a failed command does damage quietly. Three settings make bash stop at the first error, and a linter catches the mistakes people make most.

## Build it

### Step 1: A first script that reads the kernel

The **load average** is how many processes, on average, were running or waiting to run over the last 1, 5 and 15 minutes. Linux publishes it in a file:

~~~bash
cat /proc/loadavg
~~~

~~~text
0.81 0.64 0.49 1/667 4903
~~~

The first three numbers are the averages; then running/total processes, and the newest PID. As a rough guide, a load above your number of CPUs means work is queuing for the processor.

Create `monitor.sh`:

<!-- file: monitor.sh -->
~~~bash
#!/usr/bin/env bash
# Print the 1-minute load average.
set -euo pipefail

echo "load1=$(cut -d' ' -f1 /proc/loadavg)"
~~~

- `set -e` stops the script as soon as a command fails. `-u` treats using an unset variable as an error instead of quietly using an empty string. `-o pipefail` makes a pipeline fail if *any* command in it fails, not just the last. Start every script with this line.
- `$( ... )` is **command substitution**: it runs the command and puts its output in its place.
- `cut -d' ' -f1` splits each line at spaces and keeps the first field.

~~~bash
chmod +x monitor.sh && ./monitor.sh
~~~

<!-- run: chmod +x monitor.sh && ./monitor.sh | grep -Eqx 'load1=[0-9]+\.[0-9]+' -->

~~~text
load1=0.81
~~~

### Step 2: Functions, and a second system

macOS has no `/proc`; it reports the load with `sysctl -n vm.loadavg`, as `{ 0.52 0.61 0.70 }`. The script needs to ask which system it's on, `uname -s`, and choose.

**Starter.** Replace the `echo` line with a function, `load1`, that prints the load on either system, then call it:

~~~bash
load1() {
  case "$(uname -s)" in
    Linux) # TODO: the first field of /proc/loadavg
      ;;
    Darwin) # TODO: the second word of `sysctl -n vm.loadavg`
      ;;
  esac
}

echo "load1=$(load1)"
~~~

- A **function** is a named group of commands; you call it like a command, and its output can be captured with `$(load1)`.
- `case WORD in PATTERN) commands ;; esac` runs the commands for the first pattern that matches.

<details>
<summary>Hint</summary>

The Linux case is the `cut` you already have. For macOS, `awk '{print $2}'` prints the second word of each line it reads; the first word is the `{`.

</details>

<details>
<summary>The answer</summary>

Change this:

<!-- edit: monitor.sh -->
~~~bash
echo "load1=$(cut -d' ' -f1 /proc/loadavg)"
~~~

to:

~~~bash
load1() {
  case "$(uname -s)" in
    Linux) cut -d' ' -f1 /proc/loadavg ;;
    Darwin) sysctl -n vm.loadavg | awk '{print $2}' ;;  # "{ 0.52 0.61 0.70 }"
  esac
}

echo "load1=$(load1)"
~~~

</details>

<!-- run: ./monitor.sh | grep -Eqx 'load1=[0-9]+\.[0-9]+' -->

The output is unchanged: `load1=0.81`. Changing how code is organised without changing what it does is called **refactoring**.

### Step 3: Memory, with `awk`

Linux's memory figures are in `/proc/meminfo`:

~~~bash
grep -E "^(MemTotal|MemFree|MemAvailable):" /proc/meminfo
~~~

~~~text
MemTotal:        7776128 kB
MemFree:         5695244 kB
MemAvailable:    6060388 kB
~~~

Which number means "free"? Not `MemFree`. Linux deliberately fills spare RAM with the page cache from lesson 03, and gives it back the moment a program asks. `MemFree` counts only RAM doing nothing at all; `MemAvailable` counts what programs could actually get. So "in use" is `MemTotal − MemAvailable`. The difference is real:

~~~bash
awk "/^MemTotal:/ {t=\$2} /^MemFree:/ {f=\$2} /^MemAvailable:/ {a=\$2} END {printf \"used, counting MemFree: %d%%\nused, counting MemAvailable: %d%%\n\", (t-f)*100/t, (t-a)*100/t}" /proc/meminfo
~~~

~~~text
used, counting MemFree: 26%
used, counting MemAvailable: 22%
~~~

Counting `MemFree` would overstate memory use by 4 points here, and by far more on a busy server whose cache is full.

**`awk`** reads input line by line. A program is a list of `/pattern/ {action}`: for each line matching the pattern, run the action. `$2` is the line's second field (fields are split at spaces). `END {...}` runs after the last line.

**Starter.** Add a function `mem_used_pct` that prints the percentage of memory in use, as a whole number, then print it after the load:

~~~bash
mem_used_pct() {
  case "$(uname -s)" in
    Linux)
      # TODO: with awk, remember MemTotal and MemAvailable, and print (total - available) * 100 / total
      ;;
    Darwin)
      # given: macOS reports memory in pages
      total=$(sysctl -n hw.memsize)
      vm_stat | awk -v total="$total" '
        /page size of/ {ps=$8}
        /^Pages free:/ {f=$3} /^Pages inactive:/ {i=$3} /^Pages speculative:/ {s=$3}
        END {avail=(f+i+s)*ps; printf "%d\n", (total-avail)*100/total}'
      ;;
  esac
}
~~~

On macOS, `hw.memsize` is the total in bytes, and `vm_stat` counts memory in pages of a size it states on its first line. Free, inactive and speculative pages are the ones macOS can hand to programs, so they play the part of `MemAvailable`.

<details>
<summary>Hint</summary>

`awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {...}' /proc/meminfo`. In the `END` block, `printf "%d\n", ...` prints a whole number.

</details>

<details>
<summary>The answer</summary>

Change the comment at the top:

<!-- edit: monitor.sh -->
~~~bash
# Print the 1-minute load average.
~~~

to:

~~~bash
# Print the 1-minute load average and the percentage of memory in use.
~~~

and change this:

<!-- edit: monitor.sh -->
~~~bash
echo "load1=$(load1)"
~~~

to:

~~~bash
mem_used_pct() {
  case "$(uname -s)" in
    Linux)
      # MemAvailable: what programs could still use without swapping.
      awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%d\n", (t-a)*100/t}' /proc/meminfo
      ;;
    Darwin)
      # Free, inactive and speculative pages can be handed to programs.
      total=$(sysctl -n hw.memsize)
      vm_stat | awk -v total="$total" '
        /page size of/ {ps=$8}
        /^Pages free:/ {f=$3} /^Pages inactive:/ {i=$3} /^Pages speculative:/ {s=$3}
        END {avail=(f+i+s)*ps; printf "%d\n", (total-avail)*100/total}'
      ;;
  esac
}

echo "load1=$(load1) mem_used_pct=$(mem_used_pct)"
~~~

</details>

~~~bash
./monitor.sh
~~~

<!-- run: ./monitor.sh | grep -Eqx 'load1=[0-9]+\.[0-9]+ mem_used_pct=[0-9]+' -->

~~~text
load1=0.81 mem_used_pct=22
~~~

### Step 4: Disk use, and an argument

`df` reports disk use for each file system. `-P` asks for a fixed format that's the same on Linux and macOS:

~~~bash
df -P /
~~~

~~~text
Filesystem     1024-blocks      Used Available Capacity Mounted on
overlay         1055762868 208284104 793775292      21% /
~~~

You want the fifth field of the second line, without the `%`. The script should also accept a path, so you can ask about another disk, and default to `/` when you don't give one.

- `$1` is the script's first argument.
- `${1:-/}` means "`$1`, or `/` if it's missing or empty". Without the `:-/`, `set -u` would stop the script whenever you gave no argument.
- Always put variables in double quotes, `"$path"`: an unquoted variable is split at spaces, so a path with a space in it would become two arguments.

<details>
<summary>The answer</summary>

Change the comment at the top:

<!-- edit: monitor.sh -->
~~~bash
# Print the 1-minute load average and the percentage of memory in use.
~~~

to:

~~~bash
# Print one line: the 1-minute load average, the percentage of memory in use,
# and the percentage of the disk in use under PATH (default /).
#   ./monitor.sh [PATH]
#   load1=0.52 mem_used_pct=41 disk_used_pct=63
~~~

After `set -euo pipefail`:

<!-- edit: monitor.sh -->
~~~bash
set -euo pipefail
~~~

~~~bash
set -euo pipefail

path=${1:-/}
~~~

and at the end, change this:

<!-- edit: monitor.sh -->
~~~bash
echo "load1=$(load1) mem_used_pct=$(mem_used_pct)"
~~~

to:

~~~bash
disk_used_pct() {
  # -P: one line per file system, the same columns on Linux and macOS.
  df -P "$path" | awk 'NR==2 {sub(/%/, "", $5); print $5}'
}

echo "load1=$(load1) mem_used_pct=$(mem_used_pct) disk_used_pct=$(disk_used_pct)"
~~~

`NR==2` matches only the second line (`NR` is the line number), and `sub(/%/, "", $5)` removes the `%` from the fifth field.

</details>

~~~bash
./monitor.sh
./monitor.sh /tmp
~~~

<!-- run: ./monitor.sh | grep -Eqx 'load1=[0-9]+\.[0-9]+ mem_used_pct=[0-9]+ disk_used_pct=[0-9]+' && ./monitor.sh /tmp | grep -q disk_used_pct= -->

~~~text
load1=0.81 mem_used_pct=22 disk_used_pct=21
load1=0.81 mem_used_pct=22 disk_used_pct=21
~~~

Here `/tmp` is on the same disk as `/`, so the figure is the same.

### Step 5: Saying what went wrong

What should `./monitor.sh /nope` do? A path that doesn't exist is the caller's mistake, so the script should say so on standard error and exit with a code that isn't 0. Check before using the path:

<!-- edit: monitor.sh -->
~~~bash
path=${1:-/}
~~~

~~~bash
path=${1:-/}
if [[ ! -e "$path" ]]; then
  echo "monitor.sh: no such path: $path" >&2
  exit 2
fi
~~~

- `[[ ... ]]` is bash's test. `-e "$path"` is true if the path exists; `!` negates it.
- `>&2` sends the message to standard error, so it won't be mixed up with real output.
- Exit code 2 conventionally means "used wrongly", as `ls` used it in lesson 04.

~~~bash
./monitor.sh /nope; echo "exit status: $?"
~~~

<!-- run: ./monitor.sh /nope 2>err.txt; s=$?; [ $s = 2 ] && grep -q "no such path" err.txt && rm err.txt -->

~~~text
monitor.sh: no such path: /nope
exit status: 2
~~~

### Step 6: A loop, and a linter

A loop runs a command several times. Watch the machine for three seconds:

~~~bash
for i in 1 2 3; do ./monitor.sh; sleep 1; done
~~~

~~~text
load1=0.81 mem_used_pct=22 disk_used_pct=21
load1=0.75 mem_used_pct=22 disk_used_pct=21
load1=0.75 mem_used_pct=21 disk_used_pct=21
~~~

**`shellcheck`** reads a script and warns about mistakes before you run it. Install it (`sudo apt install -y shellcheck`, or `brew install shellcheck`), then remove the quotes around `$path` in `disk_used_pct` on purpose, and check:

~~~bash
shellcheck monitor.sh
~~~

~~~text

In monitor.sh line 40:
  df -P $path | awk 'NR==2 {sub(/%/, "", $5); print $5}'
        ^---^ SC2086 (info): Double quote to prevent globbing and word splitting.

Did you mean: 
  df -P "$path" | awk 'NR==2 {sub(/%/, "", $5); print $5}'

For more information:
  https://www.shellcheck.net/wiki/SC2086 -- Double quote to prevent globbing ...
~~~

Put the quotes back, and check again:

~~~bash
shellcheck monitor.sh && echo "no warnings"
~~~

~~~text
no warnings
~~~

Run `shellcheck` on every script you write. The gate does.

## Check it

~~~bash
./monitor.sh && cat /proc/loadavg && grep -E "^(MemTotal|MemAvailable):" /proc/meminfo && df -P /
~~~

Work out the three figures by hand from the raw numbers, and compare them with your script's line. The [gate](../gate/README.md) does the same comparison automatically. This proves your script reads the system correctly at one moment. It doesn't make it a monitoring system: that needs history, alerts and a way to collect it from many machines, which is what Prometheus does in a later unit.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `unbound variable` | `set -u` caught a variable that was never set, often `$1` | Give it a default: `${1:-/}` |
| The script prints nothing and exits 1 | `set -e` stopped it at a failing command | Run it as `bash -x monitor.sh`: it prints each command before running it |
| `mem_used_pct=` is empty | A typo in a field name; `awk` found nothing to match | `grep MemAvailable /proc/meminfo` and compare the spelling |
| `syntax error near unexpected token` | A missing `;;`, `esac` or `}` | `bash -n monitor.sh` checks the syntax without running it |
| `shellcheck: command not found` | Not installed | `sudo apt install -y shellcheck` or `brew install shellcheck` |
