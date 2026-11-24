# 06 Git

> Module: How the machine works · Time: ~3 h · Builds on: 05

## The problem

Your monitor works. Tomorrow you'll change it, and one of those changes will break it, maybe in a way you won't notice for a week. Without a record of every version, "what changed, and when?" has no answer. Every team, and every tool that deploys code, works from that record. That record is **Git**.

## The mental model

~~~text
 working folder          staging area           history (the repository, in .git/)
 (files you edit)  ──add──▶ (what goes in  ──commit──▶  831b3c6 ── 0402975 ── de4bee1   ◀ main
                           the next commit)                              └─ de4bee1   ◀ usage
~~~

- A **commit** is a snapshot of the files you chose, with a message, an author and a time. Each has an ID made from its contents, such as `831b3c6`.
- The **staging area** is where you put changes you want in the next commit, so one commit can hold exactly one idea.
- A **branch** is a name pointing at a commit. Committing on a branch moves its name forward.

## The pattern

**Small commits, each with one purpose and a message that says why.** Then any change can be found, explained, and undone on its own.

## Build it

### Step 1: A repository

You configured your name and email in Foundations 01. Turn the folder into a repository:

~~~bash
git init && git status
~~~

<!-- run: git init -q -b main && git config user.name "Ada Lovelace" && git config user.email ada@example.com -->

~~~text
Initialized empty Git repository in /home/ada/blueprint/machine/.git/
On branch main

No commits yet

Untracked files:
  (use "git add <file>..." to include in what will be committed)
	box/
	catch.sh
	hello.sh
	monitor.sh
	notes/
	secret.txt

nothing added to commit but untracked files present (use "git add" to track)
~~~

Git now lives in a hidden folder, `.git`. **Untracked** files are files Git sees but doesn't keep.

Some files should never be committed: secrets, logs, big generated files. List them in `.gitignore`:

<!-- file: .gitignore -->
~~~text
*.log
*.log.*
*.pid
*.last
big.bin
box/
secret.txt
~~~

`*` matches any characters, so `*.log` covers every file ending in `.log`. `secret.txt` is in the list on purpose: a secret committed even once stays in the history, and anyone who gets a copy of the repository can read it.

### Step 2: The first commits

Stage the monitor and the ignore list, look at what's staged, and commit:

~~~bash
git add monitor.sh .gitignore
git status --short
git commit -m "Add the system monitor"
~~~

<!-- run: git add monitor.sh .gitignore && git commit -qm "Add the system monitor" -->

~~~text
A  .gitignore
A  monitor.sh
?? catch.sh
?? hello.sh
?? notes/
[main (root-commit) 831b3c6] Add the system monitor
 2 files changed, 50 insertions(+)
 create mode 100644 .gitignore
 create mode 100755 monitor.sh
~~~

`A` means added to the staging area; `??` means untracked. `secret.txt` and `box/` no longer appear: Git ignores them. `100755` records that `monitor.sh` is executable. Your commit ID will differ.

~~~bash
git log --oneline
~~~

~~~text
831b3c6 Add the system monitor
~~~

Now change something. Add a line to the comment at the top of `monitor.sh`, after the example output:

<!-- edit: monitor.sh -->
~~~bash
#   load1=0.52 mem_used_pct=41 disk_used_pct=63
~~~

~~~bash
#   load1=0.52 mem_used_pct=41 disk_used_pct=63
# Works on Linux (from /proc) and macOS (from sysctl and vm_stat).
~~~

`git diff` shows what changed and isn't yet staged:

~~~bash
git diff
~~~

~~~text
diff --git a/monitor.sh b/monitor.sh
index eaa6da5..1f3a2ac 100755
--- a/monitor.sh
+++ b/monitor.sh
@@ -3,6 +3,7 @@
 # and the percentage of the disk in use under PATH (default /).
 #   ./monitor.sh [PATH]
 #   load1=0.52 mem_used_pct=41 disk_used_pct=63
+# Works on Linux (from /proc) and macOS (from sysctl and vm_stat).
 set -euo pipefail
 
 path=${1:-/}
~~~

Lines starting with `+` were added, `-` removed, and the rest are context. `@@ -3,6 +3,7 @@` says where: from line 3, 6 lines before and 7 after.

~~~bash
git commit -am "Say which systems the monitor supports"
git log --oneline
~~~

<!-- run: git commit -qam "Say which systems the monitor supports" && [ "$(git log --oneline | wc -l)" = 2 ] -->

~~~text
[main 0402975] Say which systems the monitor supports
 1 file changed, 1 insertion(+)
0402975 Say which systems the monitor supports
831b3c6 Add the system monitor
~~~

`-a` stages every change to files Git already tracks, so you can skip `git add` for them.

### Step 3: A branch

A **branch** lets you work on a change without disturbing `main`. Make one for a `--help` option:

~~~bash
git switch -c usage && git branch
~~~

<!-- run: git switch -q -c usage -->

~~~text
Switched to a new branch 'usage'
  main
* usage
~~~

**Starter.** Make `./monitor.sh --help` print a usage line and exit with code 0, before anything else runs. Put it straight after `set -euo pipefail`.

<details>
<summary>Hint</summary>

`[[ ${1:-} == "--help" ]]` is true when the first argument is `--help`. The `:-` matters: with `set -u`, a plain `$1` would stop the script when there's no argument.

</details>

<details>
<summary>The answer</summary>

<!-- edit: monitor.sh -->
~~~bash
set -euo pipefail
~~~

~~~bash
set -euo pipefail

if [[ ${1:-} == "--help" ]]; then
  echo "usage: monitor.sh [PATH]   print load, memory use, and disk use under PATH (default /)"
  exit 0
fi
~~~

</details>

~~~bash
git diff --stat && ./monitor.sh --help; echo "exit status: $?"
~~~

<!-- run: ./monitor.sh --help | grep -q '^usage: monitor.sh' -->

~~~text
 monitor.sh | 5 +++++
 1 file changed, 5 insertions(+)
usage: monitor.sh [PATH]   print load, memory use, and disk use under PATH (default /)
exit status: 0
~~~

Commit it on the branch, go back to `main`, and **merge** the branch in:

~~~bash
git commit -am "Add --help"
git switch main
git merge usage
git log --oneline --graph
~~~

<!-- run: git commit -qam "Add --help" && git switch -q main && git merge -q usage && ./monitor.sh --help | grep -q '^usage:' -->

~~~text
[usage de4bee1] Add --help
 1 file changed, 5 insertions(+)
Switched to branch 'main'
Updating 0402975..de4bee1
Fast-forward
 monitor.sh | 5 +++++
 1 file changed, 5 insertions(+)
* de4bee1 Add --help
* 0402975 Say which systems the monitor supports
* 831b3c6 Add the system monitor
~~~

**Fast-forward** means `main` hadn't moved since you branched, so Git just moved the `main` name forward to your commit. When both branches have new commits, Git makes a **merge commit** that joins them; if both changed the same lines, it asks you to choose (a **conflict**). You'll meet that in Core 01.

### Step 4: Undoing mistakes

**A change you haven't committed.** Break the script, then throw the change away:

~~~bash
echo "garbage" >> monitor.sh
git status --short
git restore monitor.sh
git status --short && echo "clean again"
~~~

<!-- run: echo "garbage" >> monitor.sh && git restore monitor.sh && [ -z "$(git status --short monitor.sh)" ] -->

~~~text
 M monitor.sh
?? catch.sh
?? hello.sh
?? notes/
?? catch.sh
?? hello.sh
?? notes/
clean again
~~~

` M` means modified. `git restore` put the committed version back, and the change is gone for good.

**A change you've already committed.** Commit a debugging line by mistake:

~~~bash
echo 'echo "debug: done" >&2' >> monitor.sh
git commit -qam "Print a debug line"
./monitor.sh && git log --oneline | head -2
~~~

<!-- run: echo 'echo "debug: done" >&2' >> monitor.sh && git commit -qam "Print a debug line" -->

~~~text
load1=0.77 mem_used_pct=22 disk_used_pct=21
debug: done
dd0c30a Print a debug line
de4bee1 Add --help
~~~

`git revert` makes a *new* commit that undoes an old one. History keeps both, so anyone who already has the old commit isn't confused:

~~~bash
git revert --no-edit HEAD
git log --oneline | head -3 && ./monitor.sh
~~~

<!-- run: git revert --no-edit HEAD >/dev/null && ! ./monitor.sh 2>&1 | grep -q debug && [ "$(git log --oneline | wc -l)" = 5 ] -->

~~~text
[main 33135ce] Revert "Print a debug line"
 Date: Wed Nov 18 16:47:52 2026 +0000
 1 file changed, 1 deletion(-)
33135ce Revert "Print a debug line"
dd0c30a Print a debug line
de4bee1 Add --help
load1=0.77 mem_used_pct=22 disk_used_pct=21
~~~

`HEAD` means "the commit you're on". The debug line is gone, and the history says exactly what happened.

## Check it

~~~bash
git log --oneline && git status --short
~~~

You should see five commits, newest first, and only untracked files you chose not to commit. That proves you can record, branch, merge and undo. It doesn't cover sharing: pushing to GitHub and reviewing each other's changes come in Core 01, when your work becomes a public repository with CI.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `Author identity unknown` | Git doesn't know your name | Run the two `git config --global` lines from Foundations 01 |
| An editor opens when you commit | You left out `-m "message"` | Type a message, save and close; or quit and commit again with `-m` |
| `fatal: not a git repository` | You're outside the repository's folder | `cd ~/blueprint/machine` |
| `git switch main` fails: `would be overwritten` | You have uncommitted changes | Commit them, or `git restore` the file |
| A secret got committed | `.gitignore` was added too late | Change the secret (it's exposed), then remove the file from tracking with `git rm --cached FILE` |
