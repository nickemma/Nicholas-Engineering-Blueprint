# Self-check: How the machine works

## Explain it

Answer in your own words. Where you can, point at something you ran.

### 01 The terminal and the shell

1. What's the difference between the terminal and the shell?
2. What do `>`, `>>`, `2>` and `|` each do? Give one command that uses two of them.
3. Explain each stage of `cut -d: -f7 /etc/passwd | sort | uniq -c | sort -rn`. Why does `sort` come before `uniq`?

### 02 Files and permissions

1. Read `-rw-r-----` aloud: who may do what?
2. Why did `./hello.sh` fail but `bash hello.sh` work?
3. On a folder, what do `r` and `x` each allow? What happened when `box` had one but not the other?
4. Why isn't `chmod 777` a fix?

### 03 How a computer stores data

1. Why did `$((2**63))` print a negative number?
2. How many bytes is "naïve" in UTF-8, and how many characters? Why do they differ?
3. What are the first four bytes of a Linux program, and what are they for?
4. Why was the second read of `big.bin` faster than the first?

### 04 Programs and processes

1. What's the difference between a program and a process?
2. What do exit codes 0, 1, 126, 127 and 143 each mean?
3. What are file descriptors 0, 1 and 2, and how do you see where they point for a running process?
4. Why did `catch.sh` print its message up to a second after you sent `SIGTERM`?

### 05 Shell scripts

1. What does each part of `set -euo pipefail` protect you from?
2. Why does the monitor use `MemAvailable` and not `MemFree`? What did the difference come to on your machine?
3. Why must `"$path"` be in quotes? What did `shellcheck` say without them?

### 06 Git

1. What's the staging area for?
2. What's a fast-forward merge?
3. When would you use `git restore`, and when `git revert`?
4. Why was `secret.txt` in `.gitignore` before the first commit, not after?

### 07 Rotating a log without losing a line

1. Why does copy-then-truncate lose lines? Where exactly do they go?
2. After `mv app.log app.log.1`, where does the writer's next line go, and why?
3. Why does the rotator wait for the new `app.log` to appear?
4. Why compress `app.log.1` one rotation later instead of immediately?

## From memory

Close the lessons. Without notes:

1. Write the command that lists every process with its PID, parent PID and command, and the one that shows which files process 1234 has open (on Linux and on macOS).
2. Write a script that prints `big` if its first argument is a number over 100, `small` otherwise, and exits with 2 if there's no argument. It must start with `set -euo pipefail` and pass `shellcheck`.
3. Make a file only you can read and write, using numbers with `chmod`.
4. Start `sleep 300` in the background, stop it with `SIGTERM`, and print its exit code.
5. Sketch, in shell, the five steps of a rotator that keeps three copies, compresses all but the newest, and loses no lines. Then explain each step's reason in one sentence.
