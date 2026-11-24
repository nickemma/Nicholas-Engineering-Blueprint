# 08 Recover a torn tail and refuse corruption

> About 7 hours · Work in the same `klog` package throughout the module.

## The problem

A process dies during an append. A later reader can see only part of the last record. Other failures can damage a complete header or payload, and the log must leave those files available for diagnosis.

## The mental model

The scanner knows the offset of the last verified record. Short header or short payload at EOF means bytes are missing. A complete header or payload with a failing checksum is evidence of corruption even when it is the last record.

## The pattern

Recover only an incomplete EOF suffix. Truncate to the verified offset, synchronize the truncation, then resume appending. Keep checksum failure a separate, non-mutating error path.

## Build it

### Step 1. Remember the short suffix and repair it under the lock

The scanner returns the verified offset, record count, and number of bytes in an incomplete suffix. A bad checksum still returns a corruption error before repair can run. Opening for append or check may repair. Opening for cat reports an incomplete frame and leaves the file as it was.

<!-- edit: src/log.rs -->
~~~rust
struct Scan {
    offset: u64,
    records: u64,
}

fn scan(file: &mut File, mut visit: impl FnMut(&[u8]) -> io::Result<()>) -> Result<Scan, LogError> {
~~~

~~~rust
struct Scan {
    offset: u64,
    records: u64,
    torn_bytes: u64,
}

fn scan(file: &mut File, mut visit: impl FnMut(&[u8]) -> io::Result<()>) -> Result<Scan, LogError> {
~~~

<!-- edit: src/log.rs -->
~~~rust
            return Ok(progress);
        }
        if n < HEADER_LEN {
            return Err(LogError::Torn {
                offset: progress.offset,
                bytes: n as u64,
            });
        }

        let at = |cause| LogError::Corrupt {
~~~

~~~rust
            return Ok(progress);
        }
        if n < HEADER_LEN {
            progress.torn_bytes = n as u64;
            return Ok(progress);
        }

        let at = |cause| LogError::Corrupt {
~~~

<!-- edit: src/log.rs -->
~~~rust
        payload.resize(header.len, 0);
        let n = read_until_full(file, &mut payload)?;
        if n < header.len {
            return Err(LogError::Torn {
                offset: progress.offset,
                bytes: (HEADER_LEN + n) as u64,
            });
        }
        record::verify(&header, &payload).map_err(at)?;
        visit(&payload)?;
~~~

~~~rust
        payload.resize(header.len, 0);
        let n = read_until_full(file, &mut payload)?;
        if n < header.len {
            progress.torn_bytes = (HEADER_LEN + n) as u64;
            return Ok(progress);
        }
        record::verify(&header, &payload).map_err(at)?;
        visit(&payload)?;
~~~

<!-- edit: src/log.rs -->
~~~rust
    parent_synced: bool,
    end: u64,
    records: u64,
    failed: bool,
}
~~~

~~~rust
    parent_synced: bool,
    end: u64,
    records: u64,
    recovered_bytes: u64,
    failed: bool,
}
~~~

<!-- edit: src/log.rs -->
~~~rust
            .open(path)?;
        file.try_lock().map_err(io::Error::from)?;
        let progress = scan(&mut file, |_| Ok(()))?;
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
~~~

~~~rust
            .open(path)?;
        file.try_lock().map_err(io::Error::from)?;
        let progress = scan(&mut file, |_| Ok(()))?;
        if progress.torn_bytes != 0 {
            file.set_len(progress.offset)?;
            file.sync_all()?;
        }
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
~~~

<!-- edit: src/log.rs -->
~~~rust
            parent_synced: false,
            end: progress.offset,
            records: progress.records,
            failed: false,
        })
    }

    pub fn records(&self) -> u64 {
        self.records
    }

    pub fn append(&mut self, payload: &[u8]) -> Result<u64, LogError> {
~~~

~~~rust
            parent_synced: false,
            end: progress.offset,
            records: progress.records,
            recovered_bytes: progress.torn_bytes,
            failed: false,
        })
    }

    pub fn records(&self) -> u64 {
        self.records
    }

    pub fn recovered_bytes(&self) -> u64 {
        self.recovered_bytes
    }

    pub fn append(&mut self, payload: &[u8]) -> Result<u64, LogError> {
~~~

<!-- edit: src/log.rs -->
~~~rust
) -> Result<(), LogError> {
    let mut file = File::open(path)?;
    file.try_lock_shared().map_err(io::Error::from)?;
    scan(&mut file, visit)?;
    Ok(())
}
~~~

~~~rust
) -> Result<(), LogError> {
    let mut file = File::open(path)?;
    file.try_lock_shared().map_err(io::Error::from)?;
    let progress = scan(&mut file, visit)?;
    if progress.torn_bytes != 0 {
        return Err(LogError::Torn {
            offset: progress.offset,
            bytes: progress.torn_bytes,
        });
    }
    Ok(())
}
~~~

### Step 2. Report every repair

The CLI prints the number of removed bytes before continuing with the requested operation.

<!-- edit: src/main.rs -->
~~~rust
        [command, path, text] if command == OsStr::new("append") => {
            let payload = text.to_str().ok_or("append requires UTF-8 text")?;
            let mut log = Log::open(Path::new(path))?;
            let offset = log.append(payload.as_bytes())?;
            println!("appended at byte {offset}");
        }
~~~

~~~rust
        [command, path, text] if command == OsStr::new("append") => {
            let payload = text.to_str().ok_or("append requires UTF-8 text")?;
            let mut log = Log::open(Path::new(path))?;
            report_recovery(&log);
            let offset = log.append(payload.as_bytes())?;
            println!("appended at byte {offset}");
        }
~~~

<!-- edit: src/main.rs -->
~~~rust
        }
        [command, path] if command == OsStr::new("check") => {
            let log = Log::open_existing(Path::new(path))?;
            println!("{} records, all checksums valid", log.records());
        }
        _ => return Err("usage: klog append FILE TEXT | klog cat FILE | klog check FILE".into()),
~~~

~~~rust
        }
        [command, path] if command == OsStr::new("check") => {
            let log = Log::open_existing(Path::new(path))?;
            report_recovery(&log);
            println!("{} records, all checksums valid", log.records());
        }
        _ => return Err("usage: klog append FILE TEXT | klog cat FILE | klog check FILE".into()),
~~~

<!-- append: src/main.rs -->
~~~rust
fn report_recovery(log: &Log) {
    if log.recovered_bytes() != 0 {
        println!("recovered: removed {} torn bytes", log.recovered_bytes());
    }
}
~~~

### Step 3. Recover a short payload, then corrupt a complete frame

~~~bash
cargo build --quiet
~~~

<!-- run: cargo build --quiet -->

Use a fresh scratch directory for these commands. The first run chops two bytes from a completed test file to reproduce the same byte layout as an interrupted append.

~~~bash
work=$(mktemp -d)
bin=./target/debug/klog
"$bin" append "$work/torn" "job queued"
"$bin" append "$work/torn" "job completed"
truncate -s -2 "$work/torn"
"$bin" check "$work/torn"
"$bin" cat "$work/torn"
rm -rf "$work"
~~~

~~~text
appended at byte 0
appended at byte 22
recovered: removed 23 torn bytes
1 records, all checksums valid
0: job queued
~~~

Next, alter a byte inside the payload of a complete final record. Preserve the damaged file for comparison.

~~~bash
work=$(mktemp -d)
bin=./target/debug/klog
"$bin" append "$work/corrupt" "last job"
printf X | dd of="$work/corrupt" bs=1 seek=12 conv=notrunc status=none
cp "$work/corrupt" "$work/before"
"$bin" check "$work/corrupt"
cmp "$work/before" "$work/corrupt"
rm -rf "$work"
~~~

~~~text
appended at byte 0
klog: corrupt record at byte 0: payload checksum mismatch
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Explain why the tool can distinguish a damaged complete header from a short valid one. A shortened final frame can also be caused by someone truncating the file after a successful append. The byte format cannot distinguish that event from a torn write. A storage engine that needs those events distinguished can keep a separate committed boundary.

## If it goes wrong

Read the offset and checksum that failed. Keep a copy of a corrupt log. A recovery that succeeds should report how many bytes it removed. The final gate checks every incomplete cut of a frame and byte preservation on refusal.
