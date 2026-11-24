# 11 Serve framed bytes in Rust

## The problem

A stream can split a header across reads, merge multiple frames, or end in the middle of a payload. One connection can also occupy a server indefinitely.

## The mental model

The listener grants a bounded connection slot. The reader verifies a fixed-size header, reads its body, and decodes one borrowed frame. A response returns through the same connection.

## The pattern

Keep framing at the byte boundary and put limits before allocating or blocking. Share the codec between both socket transports.

## Build it

### Step 1. Continue the Rust package

Keep the Rust work in `wire/klog` beside the Go checkout that the next lesson will add. The replay reconstructs the Core 05 parser and its checked header.

<!-- continue: ../../05-rust-for-systems into wire/klog -->

### Step 2. Read one frame at a time

Read exactly one byte to distinguish clean EOF between frames from truncated input. Verify the fixed header before resizing the bounded buffer. Then let the Core 05 cursor validate and borrow the payload. The service acknowledges its byte length as an eight-byte little-endian number inside a frame.

Create `wire/klog/src/data_plane.rs`.

<!-- file: wire/klog/src/data_plane.rs -->
~~~rust
use std::io::{self, Read, Write};

use crate::frame_cursor::FrameCursor;
use crate::record::{self, HEADER_LEN};

fn invalid(cause: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, cause)
}

pub fn serve(stream: &mut (impl Read + Write)) -> io::Result<()> {
    let mut frame = Vec::new();
    let mut header = [0; HEADER_LEN];
    loop {
        // An EOF between frames is a clean close. After the first byte,
        // both the rest of the header and all its payload must arrive.
        match stream.read(&mut header[..1]) {
            Ok(0) => return Ok(()),
            Ok(_) => {}
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        }
        stream.read_exact(&mut header[1..])?;
        let parsed = record::parse_header(&header).map_err(invalid)?;
        frame.resize(HEADER_LEN + parsed.len, 0);
        frame[..HEADER_LEN].copy_from_slice(&header);
        stream.read_exact(&mut frame[HEADER_LEN..])?;

        let mut cursor = FrameCursor::new(&frame);
        let bytes = cursor
            .next_frame()
            .map_err(invalid)?
            .ok_or_else(|| invalid("incomplete frame"))?;
        let response = (bytes.len() as u64).to_le_bytes();
        let response_header = record::encode_header(&response).map_err(invalid)?;
        stream.write_all(&response_header)?;
        stream.write_all(&response)?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[derive(Default)]
    struct SplitIO {
        input: Cursor<Vec<u8>>,
        output: Vec<u8>,
    }

    impl Read for SplitIO {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            let n = buf.len().min(1);
            self.input.read(&mut buf[..n])
        }
    }

    impl Write for SplitIO {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.output.write(&buf[..buf.len().min(2)])
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn fixture() -> Vec<u8> {
        let value = b"job";
        let mut built = record::encode_header(value).unwrap().to_vec();
        built.extend_from_slice(value);
        built
    }

    #[test]
    fn partial_io_and_multiple_frames() {
        let mut stream = SplitIO {
            input: Cursor::new([fixture(), fixture()].concat()),
            ..Default::default()
        };
        serve(&mut stream).unwrap();
        let mut response = FrameCursor::new(&stream.output);
        for _ in 0..2 {
            assert_eq!(
                response.next_frame().unwrap(),
                Some(3u64.to_le_bytes().as_slice())
            );
        }
        assert!(response.remaining().is_empty());
    }

    #[test]
    fn truncated_and_corrupt_frames_do_not_get_acknowledged() {
        let mut corrupt = fixture();
        corrupt[0] ^= 1;
        for (input, kind) in [
            (
                fixture()[..HEADER_LEN + 1].to_vec(),
                io::ErrorKind::UnexpectedEof,
            ),
            (corrupt, io::ErrorKind::InvalidData),
        ] {
            let mut stream = SplitIO {
                input: Cursor::new(input),
                ..Default::default()
            };
            assert_eq!(serve(&mut stream).unwrap_err().kind(), kind);
            assert!(stream.output.is_empty());
        }
    }
}
~~~

Append to `wire/klog/src/lib.rs`.

<!-- append: wire/klog/src/lib.rs -->
~~~rust
pub mod data_plane;
~~~

### Step 3. Bind either socket type

TCP and Unix sockets share the same service code. Limit active readers and give idle sockets a deadline. A Unix socket has a filesystem path. Use a fresh lab directory so there is no stale socket to unlink.

Create `wire/klog/src/bin/data-plane.rs`.

<!-- file: wire/klog/src/bin/data-plane.rs -->
~~~rust
use std::io;
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;

const CONNECTIONS: usize = 64;
const IDLE: Duration = Duration::from_secs(10);

trait Stream: io::Read + io::Write + Send + 'static {
    fn configure(&self) -> io::Result<()>;
}

impl Stream for TcpStream {
    fn configure(&self) -> io::Result<()> {
        self.set_nodelay(true)?;
        self.set_read_timeout(Some(IDLE))?;
        self.set_write_timeout(Some(IDLE))
    }
}

impl Stream for UnixStream {
    fn configure(&self) -> io::Result<()> {
        self.set_read_timeout(Some(IDLE))?;
        self.set_write_timeout(Some(IDLE))
    }
}

struct Permit(Arc<AtomicUsize>);

impl Drop for Permit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

/// Takes a connection slot if fewer than `CONNECTIONS` are in use. The
/// compare-and-swap retries when another thread changed the count first, so
/// two connections can't both take the last slot.
fn try_admit(active: &AtomicUsize) -> bool {
    let mut current = active.load(Ordering::Relaxed);
    while current < CONNECTIONS {
        match active.compare_exchange_weak(
            current,
            current + 1,
            Ordering::Relaxed,
            Ordering::Relaxed,
        ) {
            Ok(_) => return true,
            Err(actual) => current = actual,
        }
    }
    false
}

fn run<S: Stream>(incoming: impl Iterator<Item = io::Result<S>>) -> io::Result<()> {
    let active = Arc::new(AtomicUsize::new(0));
    for result in incoming {
        let mut stream = result?;
        if !try_admit(&active) {
            continue;
        }
        let permit = Permit(Arc::clone(&active));
        thread::Builder::new().spawn(move || {
            let _permit = permit;
            let _ = stream
                .configure()
                .and_then(|()| klog::data_plane::serve(&mut stream));
        })?;
    }
    Ok(())
}

fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [transport, address] if transport == "tcp" => {
            let listener = TcpListener::bind(address)?;
            println!("tcp {}", listener.local_addr()?);
            run(listener.incoming())
        }
        [transport, address] if transport == "unix" => {
            let listener = UnixListener::bind(address)?;
            println!("unix {address}");
            run(listener.incoming())
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: data-plane tcp ADDRESS | data-plane unix PATH",
        )),
    }
}
~~~

### Step 4. Exercise short reads and writes

~~~bash
cd wire/klog && cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet data_plane::tests
~~~

<!-- run: cd wire/klog && cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet data_plane::tests -->

~~~text

running 2 tests
..
test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 24 filtered out; finished in 0.00s
~~~

## Check it

Why is an early EOF clean in one place and an error in another? Which operation bounds the Rust allocation? Explain what the small response proves about the accepted request.

## If it goes wrong

If the client disconnects without an acknowledgment, inspect the header checksum and length. If a Unix bind fails, check ownership and use a fresh path.
