# 07 Append a record and sync it

> About 5 hours · Work in the same `klog` package throughout the module.

## The problem

Your decoder can validate a frame in memory. The CLI needs to keep records across invocations. It must acknowledge an append after the data and file name have been synchronized.

## The mental model

The process builds the header and calls `write_all` for the header and payload. The operating system can accept those bytes into its page cache. `sync_all` asks the OS to synchronize file contents and metadata. Synchronizing the parent directory also covers the file name when it was just created.

## The pattern

Use the same streaming scanner to read and validate a file. Lock the log while opening, scanning, or writing so cooperating processes cannot interleave records. Fail immediately if another holder has the file locked.

## Build it

### Step 1. Scan from byte zero and stop at the first invalid frame

The buffer grows only to the largest validated record length. Distinguish clean EOF, short header, short payload, and a checksum error. The scanner passes borrowed payloads to a callback. In this lesson it refuses an incomplete write. Lesson 08 decides when the tail can be repaired.

Create `src/log.rs`.

<!-- file: src/log.rs -->
~~~rust
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use crate::record::{self, HEADER_LEN, RecordError};

#[derive(Debug)]
pub enum LogError {
    Io(io::Error),
    BadInput(RecordError),
    Corrupt { offset: u64, cause: RecordError },
    Torn { offset: u64, bytes: u64 },
    WriterFailed,
}

impl fmt::Display for LogError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(err) => write!(f, "{err}"),
            Self::BadInput(err) => write!(f, "{err}"),
            Self::Corrupt { offset, cause } => {
                write!(f, "corrupt record at byte {offset}: {cause}")
            }
            Self::Torn { offset, bytes } => {
                write!(f, "incomplete record at byte {offset} ({bytes} bytes)")
            }
            Self::WriterFailed => write!(f, "writer had an I/O failure; reopen the log"),
        }
    }
}

impl std::error::Error for LogError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(err) => Some(err),
            Self::BadInput(err) => Some(err),
            Self::Corrupt { cause, .. } => Some(cause),
            Self::Torn { .. } | Self::WriterFailed => None,
        }
    }
}

impl From<io::Error> for LogError {
    fn from(err: io::Error) -> Self {
        Self::Io(err)
    }
}

// EOF can arrive partway through a frame. Read::read is also allowed to
// return a short count when more data is available.
fn read_until_full(reader: &mut File, buf: &mut [u8]) -> io::Result<usize> {
    let mut used = 0;
    while used < buf.len() {
        match reader.read(&mut buf[used..]) {
            Ok(0) => break,
            Ok(n) => used += n,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        }
    }
    Ok(used)
}

#[derive(Default)]
struct Scan {
    offset: u64,
    records: u64,
}

fn scan(file: &mut File, mut visit: impl FnMut(&[u8]) -> io::Result<()>) -> Result<Scan, LogError> {
    let mut progress = Scan::default();
    let mut bytes = [0; HEADER_LEN];
    let mut payload = Vec::new();
    loop {
        let n = read_until_full(file, &mut bytes)?;
        if n == 0 {
            return Ok(progress);
        }
        if n < HEADER_LEN {
            return Err(LogError::Torn {
                offset: progress.offset,
                bytes: n as u64,
            });
        }

        let at = |cause| LogError::Corrupt {
            offset: progress.offset,
            cause,
        };
        let header = record::parse_header(&bytes).map_err(at)?;
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
        progress.offset += (HEADER_LEN + header.len) as u64;
        progress.records += 1;
    }
}

pub struct Log {
    file: File,
    parent: PathBuf,
    parent_synced: bool,
    end: u64,
    records: u64,
    failed: bool,
}

impl Log {
    pub fn open(path: &Path) -> Result<Self, LogError> {
        Self::open_with(path, true)
    }

    pub fn open_existing(path: &Path) -> Result<Self, LogError> {
        Self::open_with(path, false)
    }

    fn open_with(path: &Path, create: bool) -> Result<Self, LogError> {
        let mut file = OpenOptions::new()
            .read(true)
            .append(true)
            .create(create)
            .open(path)?;
        file.try_lock().map_err(io::Error::from)?;
        let progress = scan(&mut file, |_| Ok(()))?;
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        Ok(Self {
            file,
            parent: parent.to_path_buf(),
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
        if self.failed {
            return Err(LogError::WriterFailed);
        }
        let header = record::encode_header(payload).map_err(LogError::BadInput)?;
        let start = self.end;
        // Once writing starts, an I/O failure leaves the tail uncertain.
        // Refuse further writes through this handle until it is reopened.
        self.failed = true;
        self.file.write_all(&header)?;
        self.file.write_all(payload)?;
        self.file.sync_all()?;
        if !self.parent_synced {
            File::open(&self.parent)?.sync_all()?;
            self.parent_synced = true;
        }
        self.end += (header.len() + payload.len()) as u64;
        self.records += 1;
        self.failed = false;
        Ok(start)
    }
}

pub fn visit_records(
    path: &Path,
    visit: impl FnMut(&[u8]) -> io::Result<()>,
) -> Result<(), LogError> {
    let mut file = File::open(path)?;
    file.try_lock_shared().map_err(io::Error::from)?;
    scan(&mut file, visit)?;
    Ok(())
}
~~~

Add this to `src/lib.rs`.

<!-- append: src/lib.rs -->
~~~rust
pub mod log;
~~~

### Step 2. Expose append, cat, and check

A single quoted string supplies the payload. `args_os` keeps paths in their native OS representation and the tool explicitly checks UTF-8 for the text. The library accepts raw bytes. `cat` displays text with replacement characters for invalid UTF-8 and returns an error if scanning fails.

Create `src/main.rs`.

<!-- file: src/main.rs -->
~~~rust
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::io::{self, Write};
use std::path::Path;
use std::process::ExitCode;

use klog::log::{Log, visit_records};

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("klog: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[OsString]) -> Result<(), Box<dyn Error>> {
    match args {
        [command, path, text] if command == OsStr::new("append") => {
            let payload = text.to_str().ok_or("append requires UTF-8 text")?;
            let mut log = Log::open(Path::new(path))?;
            let offset = log.append(payload.as_bytes())?;
            println!("appended at byte {offset}");
        }
        [command, path] if command == OsStr::new("cat") => {
            let mut line = 0;
            let mut out = io::stdout().lock();
            visit_records(Path::new(path), |payload| {
                writeln!(out, "{line}: {}", String::from_utf8_lossy(payload))?;
                line += 1;
                Ok(())
            })?;
        }
        [command, path] if command == OsStr::new("check") => {
            let log = Log::open_existing(Path::new(path))?;
            println!("{} records, all checksums valid", log.records());
        }
        _ => return Err("usage: klog append FILE TEXT | klog cat FILE | klog check FILE".into()),
    }
    Ok(())
}
~~~

### Step 3. Append from two sequential processes

~~~bash
work=$(mktemp -d) && trap 'rm -rf "$work"' EXIT && cargo run --quiet -- append "$work/log" "job queued" && cargo run --quiet -- append "$work/log" "job completed" && cargo run --quiet -- cat "$work/log" && cargo run --quiet -- check "$work/log"
~~~

<!-- run: work=$(mktemp -d) && trap 'rm -rf "$work"' EXIT && cargo run --quiet -- append "$work/log" "job queued" && cargo run --quiet -- append "$work/log" "job completed" && cargo run --quiet -- cat "$work/log" && cargo run --quiet -- check "$work/log" -->

~~~text
appended at byte 0
appended at byte 22
0: job queued
1: job completed
2 records, all checksums valid
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Compute the expected file size and offsets from the header size and the input's byte lengths. Explain why a process stuck with a partially written record refuses further appends through the same handle.

## If it goes wrong

If a second process gets a lock error, let the holder finish or use a different log. If `check` cannot find the file, run an append first or pass the existing path.
