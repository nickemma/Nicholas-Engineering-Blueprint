# 01 A container is a process

## The problem

The same binary can see a different process list or mount table depending on how it starts. It can also run under a resource limit even though the host reports plenty of capacity.

## The mental model

~~~text
image configuration --> runtime starts a process
                         |-- namespaces: the process's view
                         |-- cgroup: accounting and limits
                         +-- root filesystem and working directory
~~~

An image supplies a filesystem and configuration such as its user, entrypoint, and arguments. The kernel runs the resulting process. A PID namespace changes the view of process IDs, a mount namespace the view of mounts, and a UTS namespace the view of the hostname. A cgroup accounts for and limits a group of processes. These are separate controls. A process can join a cgroup without changing namespaces.

## Build it

### Step 1. Inspect the host view

~~~bash
readlink /proc/self/ns/pid /proc/self/ns/mnt
cat /proc/self/cgroup
stat -fc '%T' /sys/fs/cgroup
~~~

Record the namespace IDs, the cgroup path, and filesystem type. `cgroup2fs` identifies the unified cgroup filesystem on this machine. [Reference capture](../evidence/01-linux.txt)

### Step 2. Start the same command with a new view

> **Run locally.** This requires a host that permits user namespaces. The reference capture shows the smaller process view on the build host.

~~~bash
hostname
ps -o pid,ppid,comm -e
unshare --user --map-root-user --pid --fork --mount-proc --uts sh -c '
  hostname ship-lab
  hostname
  ps -o pid,ppid,comm -e
  readlink /proc/self/ns/pid /proc/self/ns/mnt
'
hostname
~~~

Expect a different PID namespace and a short process list inside it. The shell is PID 1 in that view. The host hostname remains the value printed before the command. If `unshare` reports `Operation not permitted`, record that host constraint and use a lab VM that allows user namespaces.

### Step 3. Compare accounting inside a delegated group

> **Run locally.** Set `delegated` to an empty, writable cgroup v2 subtree delegated for this lab with the pids controller enabled for its children. Ask the machine owner for this subtree when using a managed host.

~~~bash
(
  set -eu
  group="$delegated/ship-lab-$$"
  mkdir -- "$group"
  trap 'rmdir -- "$group"' EXIT
  printf '8\n' > "$group/pids.max"
  sh -c '
    printf "%s\n" "$$" > "$1/cgroup.procs"
    read -r current < "$1/pids.current"
    read -r limit < "$1/pids.max"
    printf "inside: %s task(s), limit %s\n" "$current" "$limit"
    cat /proc/self/cgroup
  ' sh "$group"
  cat "$group/pids.current"
)
~~~

The shell should see its own task counted and a limit of eight. Once it exits, the final count should be zero. The outer shell stays in its original group. A missing `pids.max` means the pids controller is unavailable in that subtree.

### Step 4. Read an image's process configuration

> **Run locally.** Use an image you already built in Core 03 and a Docker engine where you can inspect images.

~~~bash
docker image inspect --format '{{json .Config}}' "$switchyard_image"
~~~

Find the named user, working directory, entrypoint, and default arguments. Explain how those settings and the namespace and cgroup setup combine when the image starts. Note which settings belong to the image and which belong to the runtime.

## Explain it

1. Which observation shows isolation and which shows accounting?
2. What must a PID 1 process do to receive a graceful shutdown signal and reap its children?
