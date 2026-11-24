# 02 Files and permissions

> Module: How the machine works · Time: ~3 h · Builds on: 01

## The problem

A server holds things that must not leak: database passwords, private keys, other people's data. It also runs programs that, if anyone could change them, would let an attacker run anything. Linux decides who may read, change or run each file with a few bits stored beside it. Most "Permission denied" errors you'll ever see, and many security holes, come down to those bits.

## The mental model

~~~text
 -rw-r--r--  1  ada  ada  18  Nov 18 16:47  notes/first.txt
 │└┬┘└┬┘└┬┘     │    │    │   │             └ name
 │ │  │  │      │    │    │   └ last changed
 │ │  │  │      │    │    └ size in bytes
 │ │  │  │      │    └ group
 │ │  │  │      └ owner
 │ │  │  └ everyone else: r-- (read)
 │ │  └ the group: r-- (read)
 │ └ the owner: rw- (read, write)
 └ type: - file, d directory, l link
~~~

Every file has an **owner** and a **group**. Its permissions say what three kinds of people may do: the owner, members of the group, and everyone else. Each gets three bits: **r**ead, **w**rite and e**x**ecute (run it as a program).

## The pattern

**Least privilege:** give each person and each program only the access it needs. Here, that means files private by default, and only programs executable.

## Build it

### Step 1: Who you are

~~~bash
id
~~~

~~~text
uid=1000(ada) gid=1000(ada) groups=1000(ada)
~~~

The system knows you by a number, your **user ID** (`uid`), and the name is a label for it. You're also in at least one **group**, here one with your own name. Your list of groups will probably be longer (`sudo`, for example).

~~~bash
ls -l notes/first.txt
~~~

~~~text
-rw-rw-r-- 1 ada ada 18 Nov 18 16:47 notes/first.txt
~~~

You (`ada`) may read and write it; members of the `ada` group may too; everyone else may only read it. The `1` is the number of names this file has; you'll meet that idea in lesson 07.

### Step 2: Making a file runnable

Create a script, a text file of shell commands:

<!-- file: hello.sh -->
~~~bash
#!/usr/bin/env bash
echo "Hello from a script"
~~~

Save it as `hello.sh` (in VS Code, or with `nano hello.sh`: type, then Ctrl+O, Enter, Ctrl+X). The first line, the **shebang**, says which program should run the rest: here, `bash`, wherever `env` finds it.

Run it:

~~~bash
./hello.sh
~~~

~~~text
bash: line 1: ./hello.sh: Permission denied
~~~

The file exists, but it isn't allowed to run:

~~~bash
ls -l hello.sh
~~~

~~~text
-rw-rw-r-- 1 ada ada 47 Nov 18 16:47 hello.sh
~~~

No `x` anywhere. You can still have `bash` read it and run the commands inside, because that only needs `r`:

~~~bash
bash hello.sh
~~~

~~~text
Hello from a script
~~~

Give it the execute bit, and run it directly:

~~~bash
chmod +x hello.sh && ls -l hello.sh && ./hello.sh
~~~

<!-- run: chmod +x hello.sh && [ "$(./hello.sh)" = "Hello from a script" ] -->

~~~text
-rwxrwxr-x 1 ada ada 47 Nov 18 16:47 hello.sh
Hello from a script
~~~

`chmod` ("change mode") changes permissions; `+x` adds execute for everyone.

Why `./hello.sh` and not just `hello.sh`?

~~~bash
hello.sh
~~~

~~~text
bash: line 1: hello.sh: command not found
~~~

A bare name makes the shell search the folders in `PATH`, as you saw when installing Go. Your current folder isn't one of them, on purpose: otherwise a file planted in some folder could pretend to be `ls`. `./` says "this one, here".

### Step 3: Permissions as numbers

Each group of three bits is also a number: `r` = 4, `w` = 2, `x` = 1, added up. So `rw-` = 6, `r--` = 4, `rwx` = 7, and `---` = 0. Three digits set all nine bits at once:

~~~bash
echo "my secret" > secret.txt
chmod 600 secret.txt && ls -l secret.txt
chmod 644 secret.txt && ls -l secret.txt
chmod 600 secret.txt
~~~

<!-- run: echo "my secret" > secret.txt && chmod 600 secret.txt && [ "$(stat -c %a secret.txt)" = 600 ] -->

~~~text
-rw------- 1 ada ada 10 Nov 18 16:47 secret.txt
-rw-r--r-- 1 ada ada 10 Nov 18 16:47 secret.txt
~~~

`600` is "only I can read or write this": the right setting for anything secret, such as the SSH keys you'll create later. `644` is "I can write it, everyone can read it", typical for ordinary files. `755` is the same for programs and folders.

**Break it.** `chmod 777` ("everyone may do everything") makes many errors go away, which is why people reach for it. Don't: it also lets every user and every program on the machine change the file.

### Step 4: Permissions on a folder

On a folder, the bits mean something slightly different: `r` lets you list the names inside, `w` lets you create and delete files in it, and `x` lets you go into it and reach the files inside. Take `x` away from a folder you own:

~~~bash
mkdir -p box && echo inside > box/note.txt
chmod 600 box && ls -ld box
ls box
cd box
cat box/note.txt
~~~

~~~text
drw------- 2 ada ada 4096 Nov 18 16:47 box
note.txt
bash: line 1: cd: box: Permission denied
cat: box/note.txt: Permission denied
~~~

You can still list the names (`r`), but you can't enter the folder or open anything in it (`x` is missing). (`ls -ld` describes the folder itself instead of listing what's in it.) Put it back:

~~~bash
chmod 700 box && ls -ld box && cat box/note.txt
~~~

<!-- run: mkdir -p box && echo inside > box/note.txt && chmod 700 box && [ "$(cat box/note.txt)" = inside ] -->

~~~text
drwx------ 2 ada ada 4096 Nov 18 16:47 box
inside
~~~

### Step 5: The administrator, and `sudo`

One user, **root** (user ID 0), may do anything: permissions don't apply to it. Its home folder is closed to everyone else:

~~~bash
ls -ld /root
ls /root
sudo ls -la /root | head -4
~~~

~~~text
drwx------ 2 root root 4096 Nov 10 04:35 /root
ls: cannot open directory '/root': Permission denied
total 16
drwx------ 2 root root 4096 Nov 10 04:35 .
drwxr-xr-x 1 root root 4096 Nov 18 16:44 ..
-rw-r--r-- 1 root root 3106 Apr 22  2024 .bashrc
~~~

`sudo` runs one command as root, after asking for *your* password. Use it only for commands that really change the system, such as installing software. Never use it to make a "Permission denied" go away without understanding why it happened: that error usually means you're about to change something you shouldn't.

### Step 6: Hidden files and your home

~~~bash
ls -a ~ && echo "$HOME"
~~~

~~~text
.
..
.bash_logout
.bashrc
.config
.gitconfig
.profile
blueprint
go
/home/ada
~~~

Files whose names start with `.` are hidden from a plain `ls`. They're usually settings: `.gitconfig` holds what you set with `git config --global`, and `.profile` holds the `PATH` line you added for Go. `$HOME` is a **variable** the shell sets to your home folder; `$` asks for its value.

## Check it

~~~bash
ls -l hello.sh secret.txt && ls -ld box
~~~

You should see `hello.sh` executable (`-rwx...`), `secret.txt` readable only by you (`-rw-------`), and `box` open only to you (`drwx------`). That proves you can read and set permissions. It doesn't cover ownership changes (`chown`, which needs `sudo`), which you won't need until later modules.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `./script.sh: Permission denied` | The file has no `x` bit | `chmod +x script.sh` |
| `script.sh: command not found` | The current folder isn't in `PATH` | Run it as `./script.sh` |
| `cannot open directory: Permission denied` | No `r` on the folder | `chmod u+r folder` if it's yours |
| `cd: Permission denied` | No `x` on the folder | `chmod u+x folder` if it's yours |
| `sudo` asks for a password and rejects it | It wants *your* Linux password, not root's | Type the password you created for Ubuntu |
