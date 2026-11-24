# Exercises: How the machine works

Each exercise is a different project that uses this module's ideas, so you can't just retrace the lessons. There's no solution code.

## Exercise 1: `diskwatch`, a disk-space alarm

1. **What you're building:** a script that checks every mounted file system and warns about any that are filling up. Running out of disk is one of the commonest causes of outages, and this is the check that would have caught it.
2. **The finished result:**
   - `./diskwatch.sh THRESHOLD` checks every file system `df -P` lists, skipping those whose name starts with `tmpfs`, `devtmpfs` or `overlay`.
   - For each one at or above THRESHOLD percent, it prints `WARN <mount point> <percent>%` on standard output.
   - It exits with 0 if nothing is over the threshold, 1 if anything is, and 2 if THRESHOLD is missing or isn't a whole number from 1 to 100 (with a usage message on standard error).
   - It starts with `set -euo pipefail` and passes `shellcheck`.
3. **A sample session:**

   ~~~text
   $ ./diskwatch.sh 90; echo "exit: $?"
   exit: 0
   $ ./diskwatch.sh 20; echo "exit: $?"
   WARN / 21%
   exit: 1
   $ ./diskwatch.sh lots; echo "exit: $?"
   usage: diskwatch.sh THRESHOLD   (a whole number from 1 to 100)
   exit: 2
   ~~~

   Your mount points and percentages will differ.
4. **Done when:**
   1. The three cases above behave as shown on your machine, with thresholds you choose to trigger each one.
   2. A threshold of `0`, `101`, `-5` or `9x` exits with 2.
   3. Its output can be piped: `./diskwatch.sh 20 | wc -l` counts the warnings.
   4. `shellcheck diskwatch.sh` prints nothing.
5. **Stretch goals:** add `--json`, printing one JSON object per warning; run it every minute with `cron` and send warnings to a log that your `rotate.sh` rotates.
6. **Hints:** lesson 05's `df -P` and `awk` (`NR > 1` skips the header line); lesson 04's exit codes; `[[ $1 =~ ^[0-9]+$ ]]` tests for digits only.

## Exercise 2: `whoisusing`, what's holding a file

1. **What you're building:** a script that answers a question you'll ask during incidents: "which processes have this file open?" (A full disk often comes down to a deleted log that a process still holds open; its space only comes back when that process closes it.)
2. **The finished result:**
   - `./whoisusing.sh PATH` prints one line per process that has PATH open: `PID COMMAND FD`, sorted by PID.
   - On Linux it reads `/proc/*/fd/` (skipping processes you aren't allowed to read, without error messages); on macOS it uses `lsof`.
   - It prints nothing and exits 1 if no process has the file open; it exits 2 if PATH doesn't exist.
3. **A sample session:**

   ~~~text
   $ cd logs && ../writer.sh app.log &
   $ ./whoisusing.sh logs/app.log
   245 writer.sh 3
   $ mv logs/app.log logs/app.log.1 && ./whoisusing.sh logs/app.log.1
   245 writer.sh 3
   ~~~
4. **Done when:**
   1. It finds the lesson's writer through its descriptor 3, before and after a rename, as above.
   2. It exits 1 for a file nobody has open, and 2 for a path that doesn't exist.
   3. It produces no "Permission denied" noise when run as a normal user.
   4. `shellcheck whoisusing.sh` prints nothing.
5. **Stretch goal:** `--deleted`, listing files that are deleted but still held open (Linux shows them in `/proc/PID/fd` with ` (deleted)` after the name), with their sizes.
6. **Hints:** lesson 04's `/proc/PID/fd` and `ls -l`; `readlink` prints where a link points; `2>/dev/null` hides errors; compare against `realpath PATH`.
