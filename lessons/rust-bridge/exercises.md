# Rust Bridge exercise: bitlog, a log-structured key-value store

Build this **on your own**, as a new Rust crate, after the [checkpoint](TEACHING.md#checkpoint). It applies every idea from the bridge (ownership, `Result`, a binary format, checksums, `fsync`, recovery and threads) to a new problem: a key-value store whose only storage is an append-only log.

The design follows **Bitcask**, the storage engine of the Riak database. Read the short Bitcask paper (Sheehy and Smith, 2010) before you start: it's six pages. There's no solution in this repository.

## What you're building

`bitlog` stores keys and values. Every `put` or `delete` **appends** a record to a data file; nothing is ever overwritten. An in-memory **index**, a hash map from each key to where its latest value sits in the file, makes every `get` a single read. Deletes append a **tombstone**. Because old values pile up, a **compaction** step rewrites the file with only the live entries.

## The finished result

### Command line

| Command | Output | Exit status |
|---|---|---|
| `bitlog put DIR KEY VALUE` | `ok` | 0 |
| `bitlog get DIR KEY` | the value, or `not found` | 0 if found, 1 if not |
| `bitlog delete DIR KEY` | `ok` (also for a key that doesn't exist) | 0 |
| `bitlog keys DIR` | each live key on its own line, sorted | 0 |
| `bitlog compact DIR` | `compacted: N live keys, M bytes -> K bytes` | 0 |
| `bitlog check DIR` | `N records, all checksums valid`, plus a recovery line if a torn tail was cut | 0, or 1 on mid-file corruption |

`DIR` holds the store's files: `data.log`, plus whatever compaction needs.

### Record format

~~~text
length     u32 LE   bytes after this header
checksum   u32 LE   CRC-32C of everything after this header
kind       u8       1 = put, 2 = tombstone
key_len    u16 LE
key        key_len bytes
value      the remaining bytes (empty for a tombstone)
~~~

Keys are 1–1024 bytes, values 0–1 MiB. Anything outside those limits is rejected before writing.

### Rules

- Every `put` and `delete` is synced to disk before `ok` is printed.
- Opening the store **replays** the log to rebuild the index. The last record for a key wins, and a tombstone removes the key.
- A torn last record is cut off, exactly as in `klog`. Damage anywhere else makes every command fail with `corrupt at byte N`, and nothing is modified.
- `compact` writes the live entries to a **new** file, syncs it, then atomically **renames** it over the old one, and syncs the directory. A crash at any moment leaves either the old store or the new one, never a mix.
- The store is safe to share between threads: one writer at a time, many readers.

### Structure

~~~text
src/record.rs    encode and decode records (reuse your klog design)
src/store.rs     Store: open (replay), put, get, delete, keys, compact
src/main.rs      the CLI
tests/           integration tests using temporary directories
~~~

## Sample session

~~~text
$ bitlog put ./db job:1 queued
ok
$ bitlog put ./db job:1 running
ok
$ bitlog put ./db job:2 queued
ok
$ bitlog get ./db job:1
running
$ bitlog delete ./db job:2
ok
$ bitlog get ./db job:2
not found
$ bitlog keys ./db
job:1
$ bitlog compact ./db
compacted: 1 live keys, 83 bytes -> 23 bytes
$ bitlog get ./db job:1
running
~~~

The byte counts follow from the record format: 8 header + 1 kind + 2 key length + key + value. The three puts are 22, 23 and 22 bytes, and the tombstone is 16, for 83 in all. Compaction keeps one 23-byte record. Check your own arithmetic against this.

## Acceptance checks

You're done when all of these are true:

1. Unit tests cover the record format (round trip, truncation, a flipped bit, oversized keys and values) and replay rules (last write wins, tombstones).
2. An integration test writes 1,000 keys with overwrites and deletes, reopens the store, and checks every key against a `HashMap` that was updated alongside. This is a **model-based test**.
3. A torn-tail test and a mid-file corruption test behave exactly as the rules say.
4. **The crash test:** a test spawns `bitlog put` in a loop as a child process, kills it with SIGKILL at a random moment, and checks that the store opens and that every acknowledged `ok` is readable. Run it 50 times.
5. A compaction test: crash (or simulate a failure) between writing the new file and the rename, and the store still opens with all data.
6. A concurrency test: 4 threads write and 4 threads read for a second, under `cargo test`, with no corruption.
7. `cargo fmt --check`, `cargo clippy -- -D warnings` and `cargo test` pass, and CI is green.

## Stretch goals

- **Hint files:** compaction also writes a small index file, so opening a large store doesn't have to replay everything.
- **Segmented logs:** roll to a new data file at 64 MiB, and compact old segments in the background thread.
- **Benchmark** writes per second with `sync_data` after every write, against batching 100 writes per sync. Explain the trade-off you'd offer users.

## Hints

- Index values hold the file *offset* and length of the latest record for each key, not the value itself.
- Atomic replacement on Linux means: write the temporary file, `sync_all` it, `rename` it, then open the directory and `sync_all` that too, so the rename itself is durable.
- `std::process::Command` spawns the child process for the crash test, and `Child::kill` sends SIGKILL.
