# 07 Rotating a log without losing a line

> Module: How the machine works · Time: ~4 h · Builds on: 04, 05, 06

## The problem

A server writes a log forever. Left alone, the log fills the disk and the server stops. So logs are **rotated**: every so often the current file is set aside, a fresh one is started, and old copies are compressed and eventually deleted.

The obvious way to do it, copy the log and then empty it, loses lines. Not in theory: on this lesson's machine, ten rotations lost 172 lines. Those are the lines written in the instant between the copy and the emptying, which is usually when something interesting is happening. Incident reviews end in "we have no logs for the minute it broke" because of exactly this.

## The mental model

~~~text
 a name is not the file:

   directory logs/                       the file itself (an "inode", number 34461331)
   ┌──────────────────────┐              ┌──────────────────────────────┐
   │ app.log ─────────────┼─────────────▶│ line 1, line 2, line 3, ...  │◀──── writer's file
   └──────────────────────┘              └──────────────────────────────┘      descriptor 3

 mv app.log app.log.1   changes the name only. The writer still holds the same file,
                        and keeps writing to it, now called app.log.1.
 kill -HUP writer       tells it to open "app.log" again: a new, empty file.
~~~

A file on Linux is an **inode**: the data, plus its owner, permissions and size, identified by a number. A **name** in a folder just points to an inode. A process that has opened a file holds the inode, not the name.

## The pattern

**Rename, then signal the writer to reopen.** Renaming is a single, instant operation that never touches the data, so there's no moment when a line can fall between two files. This is how `logrotate` handles servers like nginx, and why so many servers reopen their logs on `SIGHUP`.

## Build it

### Step 1: A program that writes a log

You need something that writes a log as fast as a busy server. This writer appends `line 1`, `line 2`, and so on, nonstop, and reopens its log when it receives `SIGHUP`. Create `writer.sh`:

<!-- file: writer.sh -->
~~~bash
#!/usr/bin/env bash
# A stand-in for a real program that writes a log: it appends "line N"
# nonstop, and reopens its log file when it receives SIGHUP.
#   ./writer.sh app.log &
set -euo pipefail

log=${1:?usage: writer.sh LOGFILE}
echo $$ > "$log.pid"

exec 3>>"$log"                      # file descriptor 3: the log, opened for appending
trap 'exec 3>>"$log"' HUP           # on SIGHUP, open the log by name again
trap 'echo "$written" > "$log.last"; exit 0' TERM   # the last line actually written

n=0
written=0
while :; do
  n=$((n + 1))
  echo "line $n" >&3
  written=$n
done
~~~

You know almost all of this from lesson 04:

- `exec 3>>"$log"` opens the log for appending as file descriptor 3, and keeps it open. `echo ... >&3` writes to that descriptor.
- `${1:?message}` stops the script with that message if no argument was given.
- The writer saves its PID in `app.log.pid`, so other programs can signal it.
- On `SIGTERM` it records the number of the last line it actually wrote, in `app.log.last`, so you can check later that nothing went missing.

Try it for half a second:

~~~bash
chmod +x writer.sh
mkdir -p logs && cd logs
../writer.sh app.log & sleep 0.5; kill -TERM "$(cat app.log.pid)"; wait
wc -l app.log && head -3 app.log && cat app.log.last
rm app.log*
cd ..
~~~

<!-- run: chmod +x writer.sh && mkdir -p logs && cd logs && { ../writer.sh app.log & sleep 0.5; kill -TERM "$(cat app.log.pid)"; wait; } && [ "$(head -1 app.log)" = "line 1" ] && rm app.log* -->

~~~text
17890 app.log
line 1
line 2
line 3
17889
~~~

Almost 18,000 lines in half a second. The file has one more line than `app.log.last` says: the `SIGTERM` arrived after a line was written but before the writer noted it, and bash ran the trap right there, as in lesson 04. That's why `.last` records `written`, the last line it's *sure* of.

### Step 2: An experiment that counts lost lines

You'll test several rotators the same way, so give the test a script. `check_lines.sh` reads the log and all its copies, compressed or not, and counts which line numbers are missing or appear twice:

<!-- file: check_lines.sh -->
~~~bash
#!/usr/bin/env bash
# Count lost and repeated lines across a log and its rotated copies.
#   ./check_lines.sh app.log
# Run it after the writer has stopped: it reads the last line number from app.log.last.
# Copies deleted on purpose (beyond KEEP) don't count as lost: only gaps after
# the oldest line still kept do.
set -euo pipefail

log=${1:?usage: check_lines.sh LOGFILE}
last=$(cat "$log.last")

all() {
  for f in "$log" "$log".[0-9]*; do
    [[ -e "$f" ]] || continue
    case "$f" in
      *.gz) gzip -dc "$f" ;;
      *) cat "$f" ;;
    esac
  done
}

all | awk -v last="$last" '
  { n = $2; seen[n]++; if (first == "" || n < first) first = n }
  END {
    for (i = first; i <= last; i++) {
      if (!(i in seen)) lost++
      else if (seen[i] > 1) repeated += seen[i] - 1
    }
    printf "lines written: %d, kept from line %d, lost: %d, repeated: %d\n", last, first, lost, repeated
  }'
~~~

`"$log".[0-9]*` matches `app.log.1`, `app.log.2.gz` and so on. `gzip -dc` decompresses to standard output. In `awk`, `seen[n]++` counts how often each number appears, using an **array** indexed by the number.

`experiment.sh` starts the writer, runs a rotator a number of times, stops the writer and counts:

<!-- file: experiment.sh -->
~~~bash
#!/usr/bin/env bash
# Start the writer, rotate its log ROUNDS times, stop it, and count the lines.
#   ./experiment.sh ROTATOR ROUNDS KEEP
set -euo pipefail

rotator=$PWD/${1:?usage: experiment.sh ROTATOR ROUNDS KEEP}
rounds=${2:?usage: experiment.sh ROTATOR ROUNDS KEEP}
keep=${3:?usage: experiment.sh ROTATOR ROUNDS KEEP}

mkdir -p logs && cd logs
rm -f app.log app.log.*            # start clean

../writer.sh app.log &
sleep 0.3
for _ in $(seq "$rounds"); do
  "$rotator" app.log "$keep"
  sleep 0.2
done
kill -TERM "$(cat app.log.pid)"
wait

ls
../check_lines.sh app.log
~~~

`seq 10` prints the numbers 1 to 10, so the `for` loop runs ten times.

### Step 3: The naive rotator, and what it loses

Copy, then empty:

<!-- file: rotate_copytruncate.sh -->
~~~bash
#!/usr/bin/env bash
# The naive way: copy the log, then empty it. Don't use this.
#   ./rotate_copytruncate.sh LOGFILE
set -euo pipefail
log=${1:?usage: rotate_copytruncate.sh LOGFILE}
n=1
while [[ -e "$log.$n" ]]; do n=$((n + 1)); done
cp "$log" "$log.$n"
: > "$log"
~~~

`: > "$log"` empties the file: `:` prints nothing, and `>` replaces the file's contents with that nothing. Predict how many lines ten rotations will lose, then run it (the last argument, how many copies to keep, is ignored by this rotator):

~~~bash
chmod +x check_lines.sh experiment.sh rotate_copytruncate.sh
./experiment.sh rotate_copytruncate.sh 10 0
~~~

<!-- run: chmod +x check_lines.sh experiment.sh rotate_copytruncate.sh && ./experiment.sh rotate_copytruncate.sh 10 0 | grep -q '^lines written' -->

~~~text
app.log
app.log.1
app.log.10
app.log.2
app.log.3
app.log.4
app.log.5
app.log.6
app.log.7
app.log.8
app.log.9
app.log.last
app.log.pid
lines written: 85810, kept from line 1, lost: 172, repeated: 0
~~~

172 lines gone. `cp` reads the log up to its end, and while it does, the writer keeps appending; whatever arrives after `cp` finishes and before `: >` empties the file is in neither copy. Your number will differ, but it's rarely zero. (`logrotate` has exactly this mode, called `copytruncate`; its manual warns that it can lose data.)

### Step 4: What a rename does to an open file

Watch the writer's descriptor 3 while you rename its file. `ls -i` shows a file's inode number; `/proc/PID/fd/3` shows which file descriptor 3 points to. (On macOS, use `lsof -p PID` instead of `/proc`.)

~~~bash
cd logs
../writer.sh app.log & sleep 0.3
p=$(cat app.log.pid)
ls -i app.log; ls -l /proc/$p/fd/3
mv app.log app.log.1
ls -i app.log.1; ls -l /proc/$p/fd/3
kill -HUP $p; sleep 0.2
ls -i app.log app.log.1; ls -l /proc/$p/fd/3
kill -TERM $p; wait; rm -f app.log*
cd ..
~~~

~~~text
34461331 app.log
l-wx------ 1 ada ada 64 Nov 19 06:11 /proc/245/fd/3 -> /home/ada/blueprint/machine/logs/app.log
34461331 app.log.1
l-wx------ 1 ada ada 64 Nov 19 06:11 /proc/245/fd/3 -> /home/ada/blueprint/machine/logs/app.log.1
34461332 app.log
34461331 app.log.1
l-wx------ 1 ada ada 64 Nov 19 06:11 /proc/245/fd/3 -> /home/ada/blueprint/machine/logs/app.log
~~~

Read it top to bottom:

1. `app.log` is inode 34461331, and the writer's descriptor 3 points to it.
2. After `mv`, the same inode is called `app.log.1`, and descriptor 3 *followed it*: the writer is still writing into the same file, under its new name. Nothing was copied, so nothing could be lost.
3. After `SIGHUP`, the writer opened `app.log` again. There was no such name, so a new file was created, inode 34461332, and descriptor 3 now points there. `app.log.1` is complete and nobody's writing to it.

### Step 5: Rename and signal

**Starter.** Write `rotate.sh LOGFILE KEEP` that renames the log to `LOGFILE.1`, then sends `SIGHUP` to the writer, whose PID is in `LOGFILE.pid`. Ignore KEEP for now.

~~~bash
#!/usr/bin/env bash
# Rotate a log that a program is still writing to.
#   ./rotate.sh LOGFILE KEEP
set -euo pipefail

log=${1:?usage: rotate.sh LOGFILE KEEP}
pid=$(cat "$log.pid")

# TODO: rename the live log to "$log.1"
# TODO: send SIGHUP to the writer
~~~

<details>
<summary>The answer</summary>

<!-- file: rotate.sh -->
~~~bash
#!/usr/bin/env bash
# Rotate a log that a program is still writing to.
#   ./rotate.sh LOGFILE KEEP
set -euo pipefail

log=${1:?usage: rotate.sh LOGFILE KEEP}
pid=$(cat "$log.pid")

# Rename the live log. The writer keeps writing to it under its new name.
mv "$log" "$log.1"

# Ask the writer to reopen the log by name, which creates a new, empty one.
kill -HUP "$pid"
~~~

</details>

Rotate once:

~~~bash
chmod +x rotate.sh
./experiment.sh rotate.sh 1 3
~~~

<!-- run: chmod +x rotate.sh && ./experiment.sh rotate.sh 1 3 | grep -q 'kept from line 1, lost: 0, repeated: 0' -->

~~~text
app.log
app.log.1
app.log.last
app.log.pid
lines written: 18454, kept from line 1, lost: 0, repeated: 0
~~~

Nothing lost. Now rotate twice:

~~~bash
./experiment.sh rotate.sh 2 3
~~~

~~~text
app.log
app.log.1
app.log.last
app.log.pid
lines written: 25528, kept from line 11230, lost: 0, repeated: 0
~~~

Still no gaps, but lines 1 to 11,229 are gone: the second rotation renamed the new log onto `app.log.1`, replacing the first copy. The checker doesn't call that "lost", because it only counts gaps after the oldest line still kept; but you wanted those lines.

### Step 6: Keep several copies, and wait for the writer

Two fixes:

1. **Shift the old copies up** before renaming: `app.log.2` becomes `app.log.3`, `app.log.1` becomes `app.log.2`, and the one numbered KEEP is deleted. Work from the highest number down, so nothing is overwritten.
2. **Wait until the writer has reopened.** `kill` only *sends* the signal; the writer handles it when it gets to it. If the rotator returns immediately and runs again before the writer has reopened, it renames a file that doesn't exist yet. Check for the new `app.log` to appear, for up to 5 seconds, and fail loudly if it doesn't.

<details>
<summary>Hint</summary>

`for ((i = keep - 1; i >= 1; i--)); do ... done` counts down. `$((i + 1))` is the next number up. For the wait: loop 50 times, each time checking `[[ -e "$log" ]] && exit 0`, then `sleep 0.1`.

</details>

<details>
<summary>The answer</summary>

<!-- file: rotate.sh -->
~~~bash
#!/usr/bin/env bash
# Rotate a log that a program is still writing to, without losing a line.
#   ./rotate.sh LOGFILE KEEP
# Keeps KEEP old copies: LOGFILE.1 (the newest) to LOGFILE.KEEP.
# The writer's process ID is in LOGFILE.pid.
set -euo pipefail

log=${1:?usage: rotate.sh LOGFILE KEEP}
keep=${2:?usage: rotate.sh LOGFILE KEEP}
pid=$(cat "$log.pid")

# 1. Make room: drop the oldest copy, and move each copy up one.
rm -f "$log.$keep"
for ((i = keep - 1; i >= 1; i--)); do
  if [[ -f "$log.$i" ]]; then
    mv "$log.$i" "$log.$((i + 1))"
  fi
done

# 2. Rename the live log. The writer keeps writing to it under its new name.
mv "$log" "$log.1"

# 3. Ask the writer to reopen the log by name, which creates a new, empty one.
kill -HUP "$pid"

# 4. Wait until it has.
for _ in $(seq 50); do
  [[ -e "$log" ]] && exit 0
  sleep 0.1
done
echo "rotate.sh: the writer (pid $pid) didn't reopen $log within 5 seconds" >&2
exit 1
~~~

</details>

~~~bash
./experiment.sh rotate.sh 10 20
~~~

<!-- run: ./experiment.sh rotate.sh 10 20 | grep -q 'kept from line 1, lost: 0, repeated: 0' -->

~~~text
app.log
app.log.1
app.log.10
app.log.2
app.log.3
app.log.4
app.log.5
app.log.6
app.log.7
app.log.8
app.log.9
app.log.last
app.log.pid
lines written: 94845, kept from line 1, lost: 0, repeated: 0
~~~

Ten rotations, every line kept, none repeated.

### Step 7: Compress the old copies, one rotation late

Old logs compress very well, so compress every copy except the newest. But not the moment you rename it: a real server may still be finishing requests that started before the `SIGHUP`, and write their last lines to the old file through the old descriptor. So compress `app.log.1` at the *next* rotation, when it becomes `app.log.2.gz`. (`logrotate` calls this `delaycompress`.) The numbering becomes `app.log.1`, then `app.log.2.gz` up to `app.log.KEEP.gz`.

<details>
<summary>The answer</summary>

<!-- file: rotate.sh -->
~~~bash
#!/usr/bin/env bash
# Rotate a log that a program is still writing to, without losing a line.
#   ./rotate.sh LOGFILE KEEP
# Keeps KEEP old copies: LOGFILE.1 (the newest, not yet compressed),
# then LOGFILE.2.gz ... LOGFILE.KEEP.gz. The writer's process ID is in LOGFILE.pid.
set -euo pipefail

log=${1:?usage: rotate.sh LOGFILE KEEP}
keep=${2:?usage: rotate.sh LOGFILE KEEP}
pid=$(cat "$log.pid")

# 1. Make room: drop the oldest copy, and move each compressed copy up one.
rm -f "$log.$keep.gz"
for ((i = keep - 1; i >= 2; i--)); do
  if [[ -f "$log.$i.gz" ]]; then
    mv "$log.$i.gz" "$log.$((i + 1)).gz"
  fi
done

# 2. Compress last time's copy. The writer let go of it long ago.
if [[ -f "$log.1" ]]; then
  if ((keep >= 2)); then
    gzip -c "$log.1" > "$log.2.gz"
  fi
  rm "$log.1"
fi

# 3. Rename the live log. The writer keeps writing to it under its new name.
mv "$log" "$log.1"

# 4. Ask the writer to reopen the log by name, which creates a new, empty one.
kill -HUP "$pid"

# 5. Wait until it has, so the next rotation never compresses a file still in use.
for _ in $(seq 50); do
  [[ -e "$log" ]] && exit 0
  sleep 0.1
done
echo "rotate.sh: the writer (pid $pid) didn't reopen $log within 5 seconds" >&2
exit 1
~~~

`gzip -c` writes the compressed data to standard output, which `>` puts in the `.gz` file; then the original is removed. `(( ... ))` is a numeric test.

</details>

Keep 3 copies, then 20:

~~~bash
./experiment.sh rotate.sh 10 3
./experiment.sh rotate.sh 10 20
~~~

<!-- run: ./experiment.sh rotate.sh 10 3 | grep -q 'lost: 0, repeated: 0' && [ -f logs/app.log.3.gz ] && [ ! -e logs/app.log.4.gz ] && ./experiment.sh rotate.sh 10 20 | grep -q 'kept from line 1, lost: 0, repeated: 0' -->

~~~text
app.log
app.log.1
app.log.2.gz
app.log.3.gz
app.log.last
app.log.pid
lines written: 96057, kept from line 60452, lost: 0, repeated: 0
app.log
app.log.1
app.log.10.gz
app.log.2.gz
app.log.3.gz
app.log.4.gz
app.log.5.gz
app.log.6.gz
app.log.7.gz
app.log.8.gz
app.log.9.gz
app.log.last
app.log.pid
lines written: 96519, kept from line 1, lost: 0, repeated: 0
~~~

With 3 kept, exactly three copies exist and there's no gap from line 60,452 on; the older lines were deleted on purpose. With 20 kept, all 96,519 lines are there. Clean up, and commit your work:

~~~bash
rm -rf logs
git add writer.sh check_lines.sh experiment.sh rotate.sh rotate_copytruncate.sh
git commit -m "Rotate logs without losing a line"
~~~

<!-- run: rm -rf logs && git add writer.sh check_lines.sh experiment.sh rotate.sh rotate_copytruncate.sh && git commit -qm "Rotate logs without losing a line" -->

## Check it

Run the [gate](../gate/README.md) against your folder. It uses its own writer, runs your `rotate.sh` ten times keeping 20 copies and ten times keeping 3, checks your `monitor.sh` against the system, and runs `shellcheck` on both:

~~~bash
bash ~/Nicholas-Engineering-Blueprint/1-foundations/02-how-the-machine-works/gate/run.sh ~/blueprint/machine
~~~

<!-- run: if command -v shellcheck >/dev/null; then bash "$BLUEPRINT_ROOT/1-foundations/02-how-the-machine-works/gate/run.sh" .; fi -->

~~~text
PASS  monitor.sh: load 0.37 (system: 0.37)
PASS  monitor.sh: memory 21% (system: 21%)
PASS  monitor.sh: disk 21% (system: 21%)
PASS  rotate.sh, 10 rotations, keep 20: all 97128 lines kept, none lost or repeated
PASS  rotate.sh, 10 rotations, keep 3: exactly app.log.1, app.log.2.gz, app.log.3.gz, with no gaps
PASS  shellcheck: no warnings
Gate passed: on to Foundations 03.
~~~

This proves your rotator loses nothing against a writer that reopens on `SIGHUP`, at full speed, across twenty rotations. It doesn't prove it's safe against every program: one that never reopens its log keeps writing to `app.log.1` forever, and your rotator will say so after 5 seconds instead of silently compressing a file in use.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `lost` is more than 0 | Something copies or truncates instead of renaming | Rotate only with `mv`, and never empty a live log |
| `cat: app.log.pid: No such file or directory` | The writer isn't running in that folder | Start `../writer.sh app.log &` in `logs/` first |
| `the writer didn't reopen app.log within 5 seconds` | The writer has no `HUP` trap, or the PID is stale | Check `trap ... HUP` in the writer, and that `ps -p $(cat app.log.pid)` shows it |
| `mv: cannot stat 'app.log'` | A rotation ran before the writer reopened | Keep the wait loop in step 6 |
| `repeated` is more than 0 | A copy was made *and* the log kept | Never `cp` a live log; only `mv` it |
| `app.log.4.gz` exists with KEEP 3 | Shifting starts at the wrong number | Delete `$log.$keep.gz` first, then shift from `keep - 1` down to 2 |
