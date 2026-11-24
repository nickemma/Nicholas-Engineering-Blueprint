# 09 Process memory and the page cache

## The problem

A process can have a large mapping before it touches those bytes. A successful write and a synchronized file mark different points in the path to storage.

## The mental model

Virtual addresses are translated through page tables. File-backed mappings and file I/O can share cached pages. Page faults, syscall counts, and storage I/O are different measurements.

## The pattern

Measure first touch and a repeated pass separately. Pair a userspace observation with the relevant kernel event.

## Build it

### Step 1. Map a file and touch one byte per page

Create `labs/memory.py`.

<!-- file: labs/memory.py -->
~~~python
import mmap
import os
import resource
import tempfile


def minor_faults():
    return resource.getrusage(resource.RUSAGE_SELF).ru_minflt


page = os.sysconf("SC_PAGE_SIZE")
length = 8 * 1024 * 1024
with tempfile.TemporaryFile() as file:
    file.truncate(length)
    with mmap.mmap(file.fileno(), length, access=mmap.ACCESS_WRITE) as data:
        before = minor_faults()
        for offset in range(0, length, page):
            data[offset] = 7
        after_write = minor_faults()
        total = sum(data[offset] for offset in range(0, length, page))
        after_read = minor_faults()
        assert total == (length // page) * 7
        print(f"page_bytes={page} mapped_bytes={length}")
        print(f"first-touch minor faults={after_write - before}")
        print(f"second-pass minor faults={after_read - after_write}")
        data.flush()
    os.fsync(file.fileno())
    print("mapping flushed and file synchronized")
~~~

~~~bash
python3 labs/memory.py
~~~

<!-- run: python3 labs/memory.py -->

~~~text
page_bytes=4096 mapped_bytes=8388608
first-touch minor faults=2049
second-pass minor faults=0
mapping flushed and file synchronized
~~~

### Step 2. Find the syscalls around persistence

A syscall crosses into the kernel. strace sees the calls made during mapping and synchronization. Page faults happen when the CPU needs the kernel to resolve a mapping. The fault count is a separate signal from the syscall trace.

~~~bash
strace -e trace=mmap,msync,fsync python3 labs/memory.py
~~~

~~~text
msync(0x7d9ef7000000, 8388608, MS_SYNC) = 0
fsync(3)                                = 0
~~~

### Step 3. Separate address space from backing storage

An address names a virtual page. The kernel can fill in a mapping on first touch. File-backed dirty pages can remain in the page cache before writeback. Core 04 distinguishes the file sync from synchronizing a newly created name in its parent directory.

## Check it

Explain why reading the same mapped pages can produce a different fault count. Identify the calls that ask the kernel to synchronize the mapped writes and the file.

## If it goes wrong

If strace is restricted, start the lab process under strace on a Linux host with ptrace access. Keep the basic fault-count capture from the normal replay.
