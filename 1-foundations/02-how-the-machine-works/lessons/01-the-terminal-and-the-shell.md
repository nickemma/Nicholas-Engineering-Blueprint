# 01 The terminal and the shell

> Module: How the machine works · Time: ~3 h · Builds on: [Set up your machine](../../01-set-up-your-machine/README.md)

## The problem

Servers have no desktop. When something breaks at 3 a.m., there are no windows to click: you connect to the machine and type. Every tool in this course, from Git to Kubernetes, is driven the same way. If the terminal feels foreign, everything after it feels harder than it is.

## The mental model

~~~text
 you type ──▶ terminal (the window) ──▶ shell (bash or zsh) ──▶ runs a program, e.g. ls
                                              ▲                      │
                                              └──── output ◀─────────┘
~~~

- The **terminal** is only a window that shows text and sends your keystrokes.
- The **shell** is a program running inside it. It reads one line, works out what you asked for, runs it, and shows you the result. On Linux it's usually **bash**; on macOS it's **zsh**, which behaves the same for everything in this module.
- Almost every command is a separate small program on disk. `ls` is the file `/usr/bin/ls` (on macOS, `/bin/ls`).

## The pattern

**Small tools, joined together.** Each command does one job well, reads text and writes text. The shell lets you send one command's output straight into the next, so a few small tools make a big one.

## Build it

### Step 1: Where am I?

~~~bash
cd ~ && pwd && whoami
~~~

~~~text
/home/ada
ada
~~~

- `pwd` ("print working directory") shows the folder you're in. Every command runs *somewhere*, and this is where.
- `whoami` shows your user name.
- `~` is short for your **home folder**: `/home/ada` on Linux, `/Users/ada` on macOS.
- `&&` runs the next command only if the one before it succeeded.

A command has a **name**, optional **flags** that change what it does, and **arguments** it acts on. List what's in your home folder, then list it again with two flags:

~~~bash
ls
ls -la
~~~

~~~text
blueprint
go
total 40
drwxr-x--- 5 ada  ada  4096 Nov 18 16:47 .
drwxr-xr-x 1 root root 4096 Nov 18 16:44 ..
-rw-r--r-- 1 ada  ada   220 Mar 31  2024 .bash_logout
-rw-r--r-- 1 ada  ada  3771 Mar 31  2024 .bashrc
drwxrwxr-x 3 ada  ada  4096 Nov 18 16:47 .config
-rw-rw-r-- 1 ada  ada    82 Nov 18 16:47 .gitconfig
-rw-r--r-- 1 ada  ada   856 Nov 18 16:47 .profile
drwxrwxr-x 3 ada  ada  4096 Nov 18 16:47 blueprint
drwxrwxr-x 3 ada  ada  4096 Nov 18 16:47 go
~~~

`-l` gives the long form, one file per line; `-a` shows **all** files, including those whose names start with a dot, which are hidden by default. Your list will differ; you'll read every column in the next lesson. `blueprint` is the folder you made in Foundations 01, and `go` is where Go keeps downloaded code.

### Step 2: Moving around

Make the folder you'll work in for this whole module, and go into it:

~~~bash
mkdir -p ~/blueprint/machine/notes && cd ~/blueprint/machine && pwd && ls
~~~

<!-- run: mkdir -p notes -->

~~~text
/home/ada/blueprint/machine
notes
~~~

`mkdir -p` makes a folder, and any missing folders above it; `-p` also means "don't complain if it already exists". `cd` ("change directory") moves you.

A **path** names a file or folder:

- An **absolute** path starts at the top of the file system, `/`, such as `/home/ada/blueprint/machine`.
- A **relative** path starts where you are now, such as `notes`.
- `.` means "the folder I'm in" and `..` means "the folder above it".

~~~bash
cd notes && pwd && cd .. && pwd && cd /tmp && pwd && cd ~/blueprint/machine && pwd
~~~

~~~text
/home/ada/blueprint/machine/notes
/home/ada/blueprint/machine
/tmp
/home/ada/blueprint/machine
~~~

From here on, every command in this module runs in `~/blueprint/machine` unless it says otherwise.

### Step 3: Making and reading files

~~~bash
echo "hello" > notes/first.txt
echo "second line" >> notes/first.txt
cat notes/first.txt
~~~

<!-- run: echo "hello" > notes/first.txt && echo "second line" >> notes/first.txt && [ "$(cat notes/first.txt)" = "$(printf 'hello\nsecond line')" ] -->

~~~text
hello
second line
~~~

- `echo` prints its arguments.
- `>` **redirects** what a command prints into a file, replacing what was there. `>>` adds to the end instead.
- `cat` prints a file. For a long file, use `less notes/first.txt`: arrow keys to scroll, `/word` to search, `q` to quit.

`>` replaces without asking:

~~~bash
echo "replaced" > notes/second.txt && cat notes/second.txt
~~~

<!-- run: echo "replaced" > notes/second.txt -->

~~~text
replaced
~~~

There's no undo and no recycle bin in a shell. The same goes for `rm`, which deletes files: they're gone, not moved somewhere.

### Step 4: Pipes

A **pipe**, `|`, sends one command's output into the next command instead of the screen. How many programs are in `/usr/bin`?

~~~bash
ls /usr/bin | wc -l
~~~

~~~text
543
~~~

`wc -l` counts lines. Your number will be different: a full Ubuntu has far more programs than the minimal one this was captured on.

A longer pipeline. `/etc/passwd` lists the system's users, one per line, with fields separated by `:`; the seventh field is the shell each user gets. Which shells are in use, and how often?

~~~bash
cut -d: -f7 /etc/passwd | sort | uniq -c | sort -rn
~~~

~~~text
     16 /usr/sbin/nologin
      2 /bin/bash
      1 /bin/sync
~~~

Read it left to right: `cut` takes field 7 of each line; `sort` puts equal lines next to each other; `uniq -c` collapses each run of equal lines into one, with a count; `sort -rn` sorts by that count, largest first (`-n` numerically, `-r` reversed). `nologin` is for system accounts that run services but must never log in. (On macOS, users live elsewhere; this file exists but lists only a few system accounts.)

<!-- run: [ "$(printf 'b\na\nb\n' | sort | uniq -c | sort -rn | head -1 | tr -s ' ')" = " 2 b" ] -->

**Your turn.** Print the names of the three largest files in `/usr/bin`. `ls` has a flag that sorts by size (look in `ls --help`, or `man ls` on macOS), and `head -3` keeps the first three lines.

<details>
<summary>Hint</summary>

`-S` sorts by size, largest first.

</details>

<details>
<summary>The answer</summary>

~~~bash
ls -S /usr/bin | head -3
~~~

~~~text
x86_64-linux-gnu-lto-dump-13
git
perl
~~~

Yours will differ.

</details>

### Step 5: Output and errors are separate

A command has two output streams: **standard output** for results, and **standard error** for problems. Both appear on your screen, mixed together:

~~~bash
ls notes /nonexistent
~~~

~~~text
ls: cannot access '/nonexistent': No such file or directory
notes:
first.txt
second.txt
~~~

`>` redirects only standard output. `2>` redirects standard error (stream number 2):

~~~bash
ls notes /nonexistent 2> errors.txt
cat errors.txt
~~~

~~~text
notes:
first.txt
second.txt
ls: cannot access '/nonexistent': No such file or directory
~~~

The listing reached the screen; the complaint went into the file. You'll see why there are numbers here in lesson 04. Delete the file: `rm errors.txt`.

### Step 6: Getting help

Every command documents itself:

~~~bash
ls --help | head -5
~~~

~~~text
Usage: ls [OPTION]... [FILE]...
List information about the FILEs (the current directory by default).
Sort entries alphabetically if none of -cftuvSUX nor --sort is specified.

Mandatory arguments to long options are mandatory for short options too.
~~~

`man ls` opens the full manual (`q` to quit). On macOS, many commands don't support `--help`; use `man` there.

## Check it

~~~bash
ls -R ~/blueprint/machine && cat ~/blueprint/machine/notes/first.txt
~~~

You should see `notes`, holding `first.txt` and `second.txt`, and the two lines you wrote. That proves you can move around, create files and read them. It doesn't prove you know what the long listing's columns mean: that's next.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `cd: notes/first.txt: Not a directory` | You tried to `cd` into a file | `cd` into folders; read files with `cat` or `less` |
| `No such file or directory` | You're in a different folder than you think, or a typo | Run `pwd`, then `ls`, and compare |
| The terminal seems stuck, with no prompt | A command is waiting for input (for example `cat` with no file) | Press Ctrl+C to stop it |
| A file's contents vanished | `>` replaced it | Use `>>` to add to a file |
| `less` won't close | It's waiting for a key | Press `q` |
