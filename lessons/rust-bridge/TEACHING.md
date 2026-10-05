# Rust Bridge teaching: bytes, ownership and a log that survives crashes

Phase 3 makes Runway's data durable, and part of that is an **append-only log** written in Rust. Before you can trust bytes on disk, you need a language that makes memory, ownership and bytes **explicit**. That's Rust. This bridge teaches it by building `klog`, a small, real log:
- a record format with a checksum you write yourself;
- recovery from torn writes;
- refusal to open after real corruption;
- many threads safely sharing one writer.

**The goal:** a tested Rust crate and command-line tool, `klog`, plus a clear understanding of ownership, borrowing, `Result`, traits, bytes, files and threads.

**Time:** about 3 weeks. **Before you start:** finish Phase 2. Install Rust with [rustup](https://rustup.rs/), then check `rustc --version` (1.85 or newer, for the 2024 edition).

| Step | What you add |
|---|---|
| 1 | A first program: variables, types, `Option`, `match`, iterators, tests |
| 2 | Ownership and borrowing: moves, references, slices, and the compiler errors that teach them |
| 3 | Errors as values: `Result`, custom error enums, `Display`, `?` |
| 4 | Bytes and a record format: little-endian integers, a CRC-32C from scratch, decoding without copying |
| 5 | A log file: `fsync`, torn writes, recovery, and refusing real corruption |
| 6 | Threads: `Send`, `Sync`, channels, and one writer for many threads |

## Go and Rust side by side

| Idea | Go | Rust |
|---|---|---|
| Memory | A garbage collector frees memory | **Ownership**: each value has one owner and is freed when the owner goes out of scope. No collector |
| Sharing | Pointers anywhere; races caught (sometimes) at run time by `-race` | **Borrowing** rules checked at compile time; data races in safe code **don't compile** |
| Errors | `(value, error)` returns | `Result<T, E>`, with the `?` operator |
| Nothing | `nil` | `Option<T>`; there's no null |
| Interfaces | Implicit (`interface`) | Explicit **traits** (`impl Display for X`) |
| Build and test | `go build`, `go test` | `cargo build`, `cargo test` |
| Format and lint | `gofmt`, `go vet` | `cargo fmt`, `cargo clippy` |

Set up from the repository root:

~~~bash
cd lessons/rust-bridge
mkdir -p practice && cd practice
cargo init --name klog --vcs none
~~~

<!-- run: cargo init -q --name klog --vcs none -->

`cargo init` makes a **crate** (a Rust package): `Cargo.toml` describes it, and `src/main.rs` is the program. `--vcs none` skips creating a Git repository inside this one.

---

## Step 1: A first program

**The problem.** You need the basics: variables, types, functions, handling "maybe nothing", and tests.

**New ideas.**

- Variables are **immutable by default**: `let x = 5;` can't be changed. `let mut x = 5;` can. Immutability is the default because most values never need to change, and the compiler can then rule out a whole class of bugs.
- Types are inferred, and you can write them: `let total: u64 = ...`. `u64` is an unsigned 64-bit integer, `f64` a 64-bit float, `usize` the machine's pointer-sized unsigned integer (used for lengths and indexes).
- `[12, 15, 11]` is an **array** with a fixed length. `&[u64]` is a **slice**: a borrowed view of some elements, of any length.
- **`Option<T>`** is either `Some(value)` or `None`. Rust has no null, and the type system forces you to handle `None`.
- **`match`** compares a value against patterns and must cover **every** case.
- **Iterators** process sequences: `.iter().filter(...).count()`. `|&&ms| ms > 100` is a **closure** (an anonymous function); the `&&` pattern unwraps two layers of reference.
- `println!` ends in `!` because it's a **macro**: code that writes code at compile time, here so it can check the format string against its arguments.
- Tests live in the same file, in a module marked `#[cfg(test)]`, which is compiled only for `cargo test`.

Replace `src/main.rs`:

<!-- file: src/main.rs -->
~~~rust
fn main() {
    let name = "Runway";
    let latencies_ms = [12, 15, 11, 250, 14];

    println!("Hello, {name}!");
    let slow = latencies_ms.iter().filter(|&&ms| ms > 100).count();
    println!("{} requests, {slow} slow", latencies_ms.len());

    match mean(&latencies_ms) {
        Some(m) => println!("mean: {m:.1} ms"),
        None => println!("no requests"),
    }
}

/// Returns the mean of values, or None if there are none.
fn mean(values: &[u64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let total: u64 = values.iter().sum();
    Some(total as f64 / values.len() as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mean_of_some_values() {
        assert_eq!(mean(&[12, 15, 11, 250, 14]), Some(60.4));
    }

    #[test]
    fn mean_of_nothing_is_none() {
        assert_eq!(mean(&[]), None);
    }
}
~~~

**Run it.**

~~~bash
cargo run
cargo test
cargo fmt
cargo clippy
~~~

~~~text
Hello, Runway!
5 requests, 1 slow
mean: 60.4 ms
~~~

`cargo test` reports `2 passed`. `cargo clippy` is Rust's linter: it knows hundreds of mistakes and better idioms.

- `{m:.1}` formats a float with one decimal place.
- `total as f64` converts explicitly. Rust never converts between number types silently.
- `fn mean(values: &[u64]) -> Option<f64>` *borrows* a slice and *may* return a number. The signature tells you both.

**Break it.**

1. Add `total = 5;` after a `let total = 0;` (without `mut`):

   ~~~text
   error[E0384]: cannot assign twice to immutable variable `total`
   ~~~

2. In a `match` on an `Option`, handle only `Some(v)`:

   ~~~text
   error[E0004]: non-exhaustive patterns: `None` not covered
   ~~~

   That second one is the reason Rust has no null pointer exceptions: forgetting the "nothing" case is a **compile error**, not a crash at 3 a.m.

**Explain it:** why is immutability the default? What does returning `Option<f64>` force the caller to do?

<!-- run: cargo fmt --check && cargo clippy -q --all-targets -- -D warnings && cargo test -q -->

---

## Step 2: Ownership and borrowing

**The problem.** Go frees memory with a garbage collector, which pauses now and then and costs memory. C frees memory by hand, which causes use-after-free bugs and security holes. Rust frees memory **automatically and immediately**, with no collector, by tracking at compile time who **owns** each value. This is the idea everything else in Rust rests on.

**New ideas.**

- **The stack and the heap.** Small values of known size (numbers, fixed arrays) live on the **stack**, which is fast and freed when a function returns. Values that can grow (`String`, `Vec`) keep their contents on the **heap**, with a small handle (pointer, length, capacity) on the stack.
- **The three ownership rules:**
  1. Each value has one **owner**, a variable.
  2. There is only one owner at a time.
  3. When the owner goes out of scope, the value is **dropped** (freed).
- **Move.** `let b = a;` *moves* a `String` from `a` to `b`. Now only `b` owns it, and using `a` is a compile error. Small `Copy` types like `u64` are copied instead.
- **Borrowing.** `&a` lends a **shared reference**: read-only, and many may exist at once. `&mut a` lends an **exclusive reference**: read-write, and only one may exist, with no shared ones alongside it. *Many readers or one writer*: the same rule as `RWMutex` from Phase 1, but enforced by the compiler.
- **`String` vs `&str`.** `String` is an owned, growable piece of text. `&str` is a borrowed view of text, such as a string literal or part of a `String`.
- **Lifetimes.** A reference must never outlive the value it points to. Usually the compiler works this out (lifetime **elision**). In `longest_word(text: &str) -> Option<&str>`, it understands that the result borrows from `text`.

Create `src/lib.rs`. A **library crate** sits alongside the program; from Step 3 on, `main.rs` uses it as `klog::...`.

<!-- file: src/lib.rs -->
~~~rust
//! klog: a small append-only log of checksummed records, built while
//! learning Rust.

/// Returns the longest word in text, or None if there are no words. If
/// several words tie, the last one wins. The result borrows from text: no
/// characters are copied.
pub fn longest_word(text: &str) -> Option<&str> {
    text.split_whitespace().max_by_key(|word| word.len())
}

/// Appends suffix to name, in place. The caller lends name mutably.
pub fn add_suffix(name: &mut String, suffix: &str) {
    name.push_str(suffix);
}

/// Takes ownership of words and joins them into one new String.
pub fn join(words: Vec<String>, separator: &str) -> String {
    words.join(separator)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn longest_word_borrows_from_the_text() {
        let text = String::from("run the slowest job");
        assert_eq!(longest_word(&text), Some("slowest"));
        assert_eq!(longest_word("   "), None);
    }

    #[test]
    fn add_suffix_changes_the_callers_string() {
        let mut name = String::from("audit");
        add_suffix(&mut name, ".log");
        assert_eq!(name, "audit.log");
    }

    #[test]
    fn join_takes_ownership() {
        let words = vec![String::from("a"), String::from("b")];
        assert_eq!(join(words, "-"), "a-b");
        // `words` was moved into join: using it here would not compile.
    }
}
~~~

The three functions show the three ways to take a value:

| Signature | Meaning | The caller keeps the value? |
|---|---|---|
| `longest_word(text: &str)` | Borrows, read-only | Yes, unchanged |
| `add_suffix(name: &mut String, ...)` | Borrows, exclusively, to change it | Yes, changed |
| `join(words: Vec<String>, ...)` | Takes ownership | No: it's moved in, and gone afterwards |

`cargo test` now runs the library's three tests too.

**Break it: let the compiler teach you.** Try each of these in a scratch `main`, and read the error carefully. Rust's error messages are designed to teach.

1. **Use after move.** `let a = String::from("job"); let b = a; println!("{a} {b}");`

   ~~~text
   error[E0382]: borrow of moved value: `a`
     |                 -                                -             ^ value borrowed here after move
     |                 |                                |
     |                 |                                value moved here
     |                 move occurs because `a` has type `String`, which does not implement the `Copy` trait
   help: consider cloning the value if the performance cost is acceptable
   ~~~

   After `let b = a`, both would point at the same heap memory, and both would free it at the end: a **double free**, one of C's classic security bugs. Rust makes it impossible by allowing only one owner.

2. **Two writers at once.** `let first = &mut name; let second = &mut name;`, then use both:

   ~~~text
   error[E0499]: cannot borrow `name` as mutable more than once at a time
   ~~~

   This is a **data race ruled out at compile time**. Phase 1 needed `go test -race` to catch the equivalent bug at run time.

3. **A dangling reference.** Return `&s` where `s` is a local `String`:

   ~~~text
   error[E0515]: cannot return reference to local variable `s`
     |                                                                  ^^ returns a reference to data owned by the current function
   ~~~

   `s` is dropped when the function returns, so the reference would point at freed memory. In C that compiles and corrupts memory later; in Rust it doesn't compile at all.

**Explain it:** state the three ownership rules. Why is "many readers or one writer" enough to rule out data races? Why does `join` take `Vec<String>` while `longest_word` takes `&str`?

**Read.** *The Rust Programming Language*, Ch. 4 (*Understanding Ownership*) and Ch. 10.3 (*Validating References with Lifetimes*). OSTEP Ch. 13–14 (address spaces, the memory API). Carry this question in: what does a garbage collector do at run time that the borrow checker does at compile time?

<!-- run: cargo fmt --check && cargo clippy -q --all-targets -- -D warnings && cargo test -q -->

---

## Step 3: Errors as values

**The problem.** A log tool reads configuration and files, and both can be wrong. Rust has no exceptions: like Go, errors are **values** you return. But the type system makes them impossible to ignore by accident.

**New ideas.**

- **`Result<T, E>`** is either `Ok(value)` or `Err(error)`. You can't use the value without deciding what to do about the error.
- **An `enum` with data**: each variant can carry its own fields. `ParseError::UnknownUnit(String)` carries the bad unit. That's richer than Go's sentinel errors, and `match` checks you've handled every variant.
- **Traits** are Rust's interfaces, implemented explicitly. `impl fmt::Display for ParseError` defines how the error prints for humans; `impl std::error::Error` marks it as an error type. `#[derive(Debug, PartialEq, Eq)]` asks the compiler to generate debug printing and comparison automatically.
- **The `?` operator.** `let n = number.parse().map_err(...)?;` means "if this is `Err`, return it from the function now; otherwise unwrap the `Ok`". It's Go's `if err != nil { return err }` in one character.
- **Combinators**: `.ok_or_else(...)` turns `None` into an `Err`, `.map_err(...)` changes the error type, and `.checked_mul(60)` returns `None` on overflow instead of a wrong number.

Create `src/duration.rs`:

<!-- file: src/duration.rs -->
~~~rust
//! Parsing durations such as "250ms" and "2s": the same job as Go's
//! time.ParseDuration, written with Rust's Result.

use std::fmt;
use std::time::Duration;

/// Everything that can be wrong with a duration's text.
#[derive(Debug, PartialEq, Eq)]
pub enum ParseError {
    Empty,
    MissingUnit(String),
    UnknownUnit(String),
    BadNumber(String),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::Empty => write!(f, "duration is empty"),
            ParseError::MissingUnit(text) => {
                write!(f, "duration {text:?} has no unit (use ms, s or m)")
            }
            ParseError::UnknownUnit(unit) => write!(f, "unknown unit {unit:?} (use ms, s or m)"),
            ParseError::BadNumber(number) => write!(f, "{number:?} is not a whole number in range"),
        }
    }
}

impl std::error::Error for ParseError {}

/// Parses a whole number followed by a unit: ms, s or m.
pub fn parse(text: &str) -> Result<Duration, ParseError> {
    let text = text.trim();
    if text.is_empty() {
        return Err(ParseError::Empty);
    }
    let split = text
        .find(|c: char| !c.is_ascii_digit())
        .ok_or_else(|| ParseError::MissingUnit(text.to_string()))?;
    let (number, unit) = text.split_at(split);
    let n: u64 = number
        .parse()
        .map_err(|_| ParseError::BadNumber(number.to_string()))?;
    match unit {
        "ms" => Ok(Duration::from_millis(n)),
        "s" => Ok(Duration::from_secs(n)),
        "m" => n
            .checked_mul(60)
            .map(Duration::from_secs)
            .ok_or_else(|| ParseError::BadNumber(number.to_string())),
        other => Err(ParseError::UnknownUnit(other.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_durations() {
        assert_eq!(parse("250ms"), Ok(Duration::from_millis(250)));
        assert_eq!(parse(" 2s "), Ok(Duration::from_secs(2)));
        assert_eq!(parse("3m"), Ok(Duration::from_secs(180)));
    }

    #[test]
    fn invalid_durations() {
        assert_eq!(parse(""), Err(ParseError::Empty));
        assert_eq!(parse("250"), Err(ParseError::MissingUnit("250".into())));
        assert_eq!(parse("2h"), Err(ParseError::UnknownUnit("h".into())));
        assert_eq!(parse("ms"), Err(ParseError::BadNumber("".into())));
        assert_eq!(parse("-5s"), Err(ParseError::BadNumber("".into())));
    }

    #[test]
    fn overflow_is_an_error_not_a_wrong_answer() {
        let huge = format!("{}m", u64::MAX);
        assert!(matches!(parse(&huge), Err(ParseError::BadNumber(_))));
    }

    #[test]
    fn errors_explain_themselves() {
        assert_eq!(
            parse("2h").unwrap_err().to_string(),
            "unknown unit \"h\" (use ms, s or m)"
        );
    }
}
~~~

- `text.split_at(split)` returns two `&str` borrowed from `text`, so no characters are copied.
- `n.checked_mul(60)` matters: `u64::MAX` minutes would overflow, and in a release build plain `*` would silently wrap around to a small, wrong number. The test `overflow_is_an_error_not_a_wrong_answer` proves the guard works.
- `matches!(value, pattern)` is `true` if the value fits the pattern. It's handy in tests.

Register the module in `src/lib.rs`. Change:

<!-- edit: src/lib.rs -->
~~~rust
//! learning Rust.

/// Returns the longest word
~~~

to:

~~~rust
//! learning Rust.

pub mod duration;

/// Returns the longest word
~~~

`pub mod duration;` tells the compiler that the module lives in `src/duration.rs`, and makes it public to users of the crate.

Replace `src/main.rs` with a program that uses it:

<!-- file: src/main.rs -->
~~~rust
use std::error::Error;

fn main() -> Result<(), Box<dyn Error>> {
    let text = std::env::args()
        .nth(1)
        .unwrap_or_else(|| String::from("250ms"));
    let duration = klog::duration::parse(&text)?;
    println!("{text} is {} ms", duration.as_millis());
    Ok(())
}
~~~

`main` itself can return a `Result`. `Box<dyn Error>` means "any type that implements `Error`, stored on the heap", so `?` can return whatever error a call produces.

**Run it.**

~~~bash
cargo run -q -- 2s
cargo run -q -- 3m
cargo run -q -- 2h
~~~

~~~text
2s is 2000 ms
3m is 180000 ms
Error: UnknownUnit("h")
~~~

The last one exits with status 1. Notice `UnknownUnit("h")`: when `main` returns an error, Rust prints its **`Debug`** form, meant for programmers. The friendly **`Display`** form, `unknown unit "h" (use ms, s or m)`, is what a user should see. Step 5's command-line tool prints `Display` on purpose.

**Explain it:** what does `?` do, precisely? Why does `parse` use `checked_mul`? `Debug` vs `Display`: who is each one for?

**Read.** *The Rust Programming Language*, Ch. 6 (enums and `match`), Ch. 9 (error handling) and Ch. 10.2 (traits).

<!-- run: cargo fmt --check && cargo clippy -q --all-targets -- -D warnings && cargo test -q -->

---

## Step 4: Bytes and a record format

**The problem.** A file is just bytes. To store records in one, you need a **format**: where each record starts and ends, and a way to tell whether its bytes are still the ones you wrote. Disks, cables and memory occasionally flip bits, and a crash can leave a record half-written.

**New ideas.**

- **Framing with a length prefix.** Each record starts with its length, so a reader knows exactly where it ends.
- **Endianness.** A `u32` is 4 bytes, and they can be stored lowest byte first (**little-endian**, as x86 and ARM CPUs do) or highest first. A file format must pick one and say so. `to_le_bytes()` and `from_le_bytes()` convert explicitly.
- **A checksum** is a short number computed from data. If the data changes, the checksum almost certainly changes too. **CRC-32C** (Castagnoli) is the checksum used by many storage systems, iSCSI and ext4 metadata among them, and modern CPUs even have an instruction for it. You'll implement the classic table-driven version from scratch.
- A checksum **detects accidents, not attacks**. Someone who can rewrite the data can rewrite the checksum too. Phase 6's audit log adds hash chains and signatures for that.
- **`const fn`** runs at compile time: the 256-entry CRC table is built by the compiler, not at start-up.
- **Zero-copy decoding.** `decode` returns `&[u8]`, a slice *borrowed* from the buffer, instead of copying the payload. The borrow checker guarantees the buffer outlives the slice.

The format, byte by byte:

~~~text
offset  0..4   length    u32, little-endian
offset  4..8   checksum  u32, little-endian, CRC-32C of the payload
offset  8..    payload   `length` bytes
~~~

Create `src/crc.rs`:

<!-- file: src/crc.rs -->
~~~rust
//! CRC-32C (Castagnoli), the checksum used by many storage systems to
//! detect damaged bytes. A checksum can't repair damage or stop someone
//! who rewrites both the data and its checksum; it only detects accidents.

/// The Castagnoli polynomial, bit-reversed, as the table algorithm needs.
const POLYNOMIAL: u32 = 0x82F6_3B78;

/// A table of 256 precomputed values, built once at compile time, so the
/// checksum processes a whole byte per step instead of one bit.
const TABLE: [u32; 256] = build_table();

const fn build_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut crc = i as u32;
        let mut bit = 0;
        while bit < 8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ POLYNOMIAL
            } else {
                crc >> 1
            };
            bit += 1;
        }
        table[i] = crc;
        i += 1;
    }
    table
}

/// Returns the CRC-32C of data.
pub fn crc32c(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &byte in data {
        crc = TABLE[((crc ^ byte as u32) & 0xFF) as usize] ^ (crc >> 8);
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_check_value() {
        // Every CRC-32C implementation must give this for "123456789".
        assert_eq!(crc32c(b"123456789"), 0xE306_9283);
    }

    #[test]
    fn empty_input() {
        assert_eq!(crc32c(b""), 0);
    }

    #[test]
    fn one_changed_bit_changes_the_checksum() {
        let mut data = b"job 7 completed".to_vec();
        let before = crc32c(&data);
        data[4] ^= 0b0000_0001;
        assert_ne!(crc32c(&data), before);
    }
}
~~~

- `!0u32` is all 32 bits set to 1: CRC-32C starts there and inverts at the end. Those are details of the standard, and the test vector proves them right.
- `b"123456789"` is a **byte string**: `&[u8]`, not text. Every correct CRC-32C implementation returns `0xE3069283` for it. That's a **known-answer test**, the standard way to check that a checksum or cipher is implemented correctly.
- `data[4] ^= 0b0000_0001` flips one bit, using XOR.

Create `src/record.rs`:

<!-- file: src/record.rs -->
~~~rust
//! The on-disk record format. Each record is:
//!
//! ```text
//! length    4 bytes, little-endian: how many payload bytes follow the header
//! checksum  4 bytes, little-endian: CRC-32C of the payload
//! payload   `length` bytes
//! ```
//!
//! The length says where a record ends. The checksum says whether its bytes
//! are the ones that were written.

use std::fmt;

use crate::crc::crc32c;

pub const HEADER_LEN: usize = 8;
pub const MAX_PAYLOAD: usize = 1 << 20; // 1 MiB

#[derive(Debug, PartialEq, Eq)]
pub enum RecordError {
    /// The payload, or the length a header claims, is over MAX_PAYLOAD.
    TooLarge(usize),
    /// The buffer ends before the record does.
    Truncated { needed: usize, available: usize },
    /// The payload's checksum doesn't match the header's.
    Corrupt { expected: u32, actual: u32 },
}

impl fmt::Display for RecordError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RecordError::TooLarge(len) => {
                write!(
                    f,
                    "record of {len} bytes is over the {MAX_PAYLOAD}-byte limit"
                )
            }
            RecordError::Truncated { needed, available } => {
                write!(f, "record needs {needed} bytes but only {available} remain")
            }
            RecordError::Corrupt { expected, actual } => {
                write!(
                    f,
                    "checksum mismatch: header says {expected:#010x}, payload gives {actual:#010x}"
                )
            }
        }
    }
}

impl std::error::Error for RecordError {}

/// Encodes payload as one record: header, then payload.
pub fn encode(payload: &[u8]) -> Result<Vec<u8>, RecordError> {
    if payload.len() > MAX_PAYLOAD {
        return Err(RecordError::TooLarge(payload.len()));
    }
    let mut record = Vec::with_capacity(HEADER_LEN + payload.len());
    record.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    record.extend_from_slice(&crc32c(payload).to_le_bytes());
    record.extend_from_slice(payload);
    Ok(record)
}

/// Decodes the record at the start of buf. It returns the payload, borrowed
/// from buf without copying, and how many bytes the whole record used.
pub fn decode(buf: &[u8]) -> Result<(&[u8], usize), RecordError> {
    if buf.len() < HEADER_LEN {
        return Err(RecordError::Truncated {
            needed: HEADER_LEN,
            available: buf.len(),
        });
    }
    let length = read_u32(&buf[0..4]) as usize;
    if length > MAX_PAYLOAD {
        return Err(RecordError::TooLarge(length));
    }
    let expected = read_u32(&buf[4..8]);
    let end = HEADER_LEN + length;
    if buf.len() < end {
        return Err(RecordError::Truncated {
            needed: end,
            available: buf.len(),
        });
    }
    let payload = &buf[HEADER_LEN..end];
    let actual = crc32c(payload);
    if actual != expected {
        return Err(RecordError::Corrupt { expected, actual });
    }
    Ok((payload, end))
}

/// Reads a little-endian u32 from the first four bytes of bytes.
fn read_u32(bytes: &[u8]) -> u32 {
    u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let record = encode(b"job 7 completed").unwrap();
        assert_eq!(record.len(), HEADER_LEN + 15);
        assert_eq!(decode(&record), Ok((&b"job 7 completed"[..], record.len())));
    }

    #[test]
    fn header_layout_is_little_endian() {
        let record = encode(b"hi").unwrap();
        assert_eq!(&record[0..4], &[2, 0, 0, 0]);
    }

    #[test]
    fn empty_payload_is_allowed() {
        let record = encode(b"").unwrap();
        assert_eq!(decode(&record), Ok((&b""[..], HEADER_LEN)));
    }

    #[test]
    fn records_decode_one_after_another() {
        let mut buf = encode(b"first").unwrap();
        buf.extend(encode(b"second").unwrap());
        let (first, used) = decode(&buf).unwrap();
        let (second, _) = decode(&buf[used..]).unwrap();
        assert_eq!((first, second), (&b"first"[..], &b"second"[..]));
    }

    #[test]
    fn truncation_is_detected() {
        let record = encode(b"job 7 completed").unwrap();
        assert_eq!(
            decode(&record[..5]),
            Err(RecordError::Truncated {
                needed: 8,
                available: 5
            })
        );
        assert_eq!(
            decode(&record[..12]),
            Err(RecordError::Truncated {
                needed: 23,
                available: 12
            })
        );
    }

    #[test]
    fn a_flipped_bit_is_detected() {
        let mut record = encode(b"job 7 completed").unwrap();
        record[HEADER_LEN + 4] ^= 1;
        assert!(matches!(decode(&record), Err(RecordError::Corrupt { .. })));
    }

    #[test]
    fn a_garbage_length_is_rejected_before_reading() {
        let garbage = [0xFF; 16];
        assert_eq!(
            decode(&garbage),
            Err(RecordError::TooLarge(u32::MAX as usize))
        );
    }

    #[test]
    fn oversized_payloads_are_refused() {
        let big = vec![0u8; MAX_PAYLOAD + 1];
        assert_eq!(encode(&big), Err(RecordError::TooLarge(MAX_PAYLOAD + 1)));
    }
}
~~~

- `decode` checks the length against `MAX_PAYLOAD` **before** trusting it. A corrupted header could claim four gigabytes; the test `a_garbage_length_is_rejected_before_reading` proves it's refused. Never let input bytes size an allocation without a limit. That's Phase 1's `MaxBytesReader` lesson, in a file format.
- `&buf[HEADER_LEN..end]` takes a sub-slice. Indexing past the end would **panic** (Rust's crash for bugs), which is why every length is checked first.
- `{expected:#010x}` prints a number as `0x` plus 8 hex digits.

Register both modules, keeping them in alphabetical order (`cargo fmt` sorts them). Change:

<!-- edit: src/lib.rs -->
~~~rust
pub mod duration;
~~~

to:

~~~rust
pub mod crc;
pub mod duration;
pub mod record;
~~~

**Run it.** `cargo test` now runs 18 tests, including the known-answer test and the corruption tests.

**Break it.** In `crc.rs`, change the polynomial's last digit (`0x82F6_3B78` to `0x82F6_3B79`) and run `cargo test`. `known_check_value` fails, while the round-trip tests still **pass**: encode and decode both use the wrong CRC, so they agree with each other. Only a known answer from *outside* your code catches the bug. Restore it.

**Explain it:** why does every record start with its length? Why little-endian, stated explicitly? What can a CRC detect, and what can't it?

**Read.** *Database Internals* Ch. 3 (file formats), or the LevelDB or RocksDB write-ahead-log format documentation. OSTEP Ch. 44, *Data Integrity and Protection*. Carry this question in: what's the difference between detecting corruption and preventing it?

<!-- run: cargo fmt --check && cargo clippy -q --all-targets -- -D warnings && cargo test -q -->

---

## Step 5: A log file that survives crashes

**The problem.** Writing records to a file isn't enough. When `write` returns, the bytes may still be only in the operating system's **page cache** (memory), not on the disk. A power cut then loses them, even though your program reported success. And a crash in the middle of writing a record leaves a **torn write**: a half-written last record. The log must survive both.

**New ideas.**

- **`fsync`** (`sync_data` and `sync_all` in Rust) asks the operating system to push a file's data to the physical device and wait until it's there. **A write is only durable after a successful sync.** It's slow (milliseconds), which is why databases batch writes before syncing.
- **Append-only** files only ever grow at the end. So after a crash, **only the last record can be damaged by an unfinished write**. That's what makes recovery simple.
- **Recovery** reads records from the start. When it hits damage:
  - if the damage is the **last record** (too few bytes, or a full-length record with a bad checksum), it's a torn write: cut it off and carry on;
  - if valid-looking data **follows** the damage, it can't be a torn write. It's real corruption, and the log **refuses to open**. Silently throwing away records you can't prove were unfinished is how data disappears without anyone noticing.
- **`From` conversions**: `impl From<io::Error> for LogError` lets `?` turn an I/O error into a `LogError` automatically.
- **Slice patterns** in the CLI: `[command, path, words @ ..]` matches "a command, a path, and the rest".

Create `src/log.rs`:

<!-- file: src/log.rs -->
~~~rust
//! An append-only log file of checksummed records.
//!
//! Records are only ever added at the end. After a crash, the only record
//! that can be damaged by an unfinished write is the last one: a torn
//! write. Opening the log cuts a torn last record off and carries on. Damage
//! anywhere else can't be a torn write, so opening refuses to continue
//! rather than silently throwing data away.

use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;

use crate::record::{self, HEADER_LEN, RecordError};

#[derive(Debug)]
pub enum LogError {
    Io(io::Error),
    Record(RecordError),
    /// Damage that isn't at the end of the file.
    CorruptAt {
        offset: u64,
        cause: RecordError,
    },
}

impl fmt::Display for LogError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LogError::Io(err) => write!(f, "i/o error: {err}"),
            LogError::Record(err) => write!(f, "{err}"),
            LogError::CorruptAt { offset, cause } => {
                write!(f, "log is corrupt at byte {offset}: {cause}")
            }
        }
    }
}

impl std::error::Error for LogError {}

impl From<io::Error> for LogError {
    fn from(err: io::Error) -> Self {
        LogError::Io(err)
    }
}

impl From<RecordError> for LogError {
    fn from(err: RecordError) -> Self {
        LogError::Record(err)
    }
}

/// What opening the log found.
#[derive(Debug, PartialEq, Eq)]
pub struct Recovery {
    /// Complete, valid records in the log.
    pub records: usize,
    /// Bytes of a torn last record that were cut off.
    pub truncated_bytes: u64,
}

pub struct Log {
    file: File,
    end: u64,
}

impl Log {
    /// Opens the log at path, creating it if needed, and recovers from a
    /// torn last record.
    pub fn open(path: impl AsRef<Path>) -> Result<(Log, Recovery), LogError> {
        let mut file = OpenOptions::new()
            .read(true)
            .append(true)
            .create(true)
            .open(path)?;
        let mut data = Vec::new();
        file.read_to_end(&mut data)?;

        let scan = scan(&data)?;
        let truncated_bytes = (data.len() - scan.valid_len) as u64;
        if truncated_bytes > 0 {
            file.set_len(scan.valid_len as u64)?;
            file.sync_all()?;
        }
        let recovery = Recovery {
            records: scan.payloads.len(),
            truncated_bytes,
        };
        Ok((
            Log {
                file,
                end: scan.valid_len as u64,
            },
            recovery,
        ))
    }

    /// Appends payload as one record and waits until it's on disk. Returns
    /// the byte offset where the record starts.
    pub fn append(&mut self, payload: &[u8]) -> Result<u64, LogError> {
        let record = record::encode(payload)?;
        let offset = self.end;
        self.file.write_all(&record)?;
        self.file.sync_data()?; // durable before we report success
        self.end += record.len() as u64;
        Ok(offset)
    }
}

/// Reads every valid record in the log at path. A torn last record is
/// ignored, without changing the file; corruption elsewhere is an error.
pub fn read_all(path: impl AsRef<Path>) -> Result<Vec<Vec<u8>>, LogError> {
    let data = std::fs::read(path)?;
    let scan = scan(&data)?;
    Ok(scan.payloads.into_iter().map(|p| p.to_vec()).collect())
}

struct Scan<'a> {
    payloads: Vec<&'a [u8]>,
    valid_len: usize,
}

/// Decodes records from the start of data until the end, or until damage.
/// Damage is accepted only if it's a torn last record.
fn scan(data: &[u8]) -> Result<Scan<'_>, LogError> {
    let mut payloads = Vec::new();
    let mut offset = 0;
    while offset < data.len() {
        match record::decode(&data[offset..]) {
            Ok((payload, used)) => {
                payloads.push(payload);
                offset += used;
            }
            Err(cause) if is_torn_tail(&data[offset..], &cause) => break,
            Err(cause) => {
                return Err(LogError::CorruptAt {
                    offset: offset as u64,
                    cause,
                });
            }
        }
    }
    Ok(Scan {
        payloads,
        valid_len: offset,
    })
}

/// A torn write can only leave the last record incomplete: either too few
/// bytes, or a full-length record whose bytes didn't all reach the disk.
fn is_torn_tail(rest: &[u8], cause: &RecordError) -> bool {
    match cause {
        RecordError::Truncated { .. } => true,
        RecordError::Corrupt { .. } => {
            let length = u32::from_le_bytes([rest[0], rest[1], rest[2], rest[3]]) as usize;
            HEADER_LEN + length == rest.len()
        }
        RecordError::TooLarge(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// A fresh path in the system's temporary directory, unique per test.
    fn temp_path(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("klog-{}-{name}", std::process::id()));
        let _ = std::fs::remove_file(&path);
        path
    }

    #[test]
    fn append_then_read_back() {
        let path = temp_path("append");
        let (mut log, recovery) = Log::open(&path).unwrap();
        assert_eq!(
            recovery,
            Recovery {
                records: 0,
                truncated_bytes: 0
            }
        );

        assert_eq!(log.append(b"first").unwrap(), 0);
        assert_eq!(log.append(b"second").unwrap(), 13);
        assert_eq!(
            read_all(&path).unwrap(),
            vec![b"first".to_vec(), b"second".to_vec()]
        );
    }

    #[test]
    fn reopening_continues_at_the_end() {
        let path = temp_path("reopen");
        Log::open(&path).unwrap().0.append(b"one").unwrap();
        let (mut log, recovery) = Log::open(&path).unwrap();
        assert_eq!(recovery.records, 1);
        log.append(b"two").unwrap();
        assert_eq!(read_all(&path).unwrap().len(), 2);
    }

    #[test]
    fn a_torn_last_record_is_cut_off() {
        let path = temp_path("torn");
        Log::open(&path).unwrap().0.append(b"complete").unwrap();
        // Simulate a crash halfway through writing the second record.
        let half = &record::encode(b"never finished").unwrap()[..11];
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(half)
            .unwrap();

        let (mut log, recovery) = Log::open(&path).unwrap();
        assert_eq!(
            recovery,
            Recovery {
                records: 1,
                truncated_bytes: 11
            }
        );
        log.append(b"after recovery").unwrap();
        assert_eq!(
            read_all(&path).unwrap(),
            vec![b"complete".to_vec(), b"after recovery".to_vec()]
        );
    }

    #[test]
    fn a_damaged_last_record_of_full_length_counts_as_torn() {
        let path = temp_path("torn-bytes");
        let (mut log, _) = Log::open(&path).unwrap();
        log.append(b"good").unwrap();
        log.append(b"bad tail").unwrap();
        let mut data = std::fs::read(&path).unwrap();
        let last = data.len() - 1;
        data[last] ^= 0xFF;
        std::fs::write(&path, &data).unwrap();

        let (_, recovery) = Log::open(&path).unwrap();
        assert_eq!(
            recovery,
            Recovery {
                records: 1,
                truncated_bytes: 16
            }
        );
    }

    #[test]
    fn damage_before_the_end_refuses_to_open() {
        let path = temp_path("corrupt");
        let (mut log, _) = Log::open(&path).unwrap();
        log.append(b"first").unwrap();
        log.append(b"second").unwrap();
        let mut data = std::fs::read(&path).unwrap();
        data[HEADER_LEN] ^= 0xFF; // inside the first payload
        std::fs::write(&path, &data).unwrap();

        match Log::open(&path) {
            Err(LogError::CorruptAt {
                offset: 0,
                cause: RecordError::Corrupt { .. },
            }) => {}
            other => panic!(
                "expected corruption at byte 0, got {:?}",
                other.map(|(_, r)| r)
            ),
        }
    }
}
~~~

Read `open` and `scan` carefully:

- `OpenOptions` with `append(true)` makes every write go to the end of the file, whatever else happens.
- `scan` returns `Scan<'_>`, a struct holding **borrowed** payloads. The `'_` says it borrows from `data`, so `data` must outlive it.
- `is_torn_tail` is the recovery decision. A `Truncated` error is always the tail. A `Corrupt` record counts as torn only if it ends exactly at the end of the file. A `TooLarge` length is never a torn write: a half-written header shows up as `Truncated`.
- After cutting a torn tail, `set_len` shortens the file and `sync_all` makes the repair itself durable. Otherwise a second crash could bring the torn bytes back.

Register the module (keep the order). Change:

<!-- edit: src/lib.rs -->
~~~rust
pub mod duration;
pub mod record;
~~~

to:

~~~rust
pub mod duration;
pub mod log;
pub mod record;
~~~

Replace `src/main.rs` with the `klog` command-line tool:

<!-- file: src/main.rs -->
~~~rust
//! klog: append to, read and check a log file.
//!
//!   klog append FILE TEXT...
//!   klog cat FILE
//!   klog check FILE

use std::error::Error;
use std::process::ExitCode;

use klog::log::{Log, Recovery, read_all};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("klog: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> Result<(), Box<dyn Error>> {
    match args {
        [command, path, words @ ..] if command == "append" && !words.is_empty() => {
            let (mut log, recovery) = Log::open(path)?;
            report(&recovery);
            let offset = log.append(words.join(" ").as_bytes())?;
            println!("appended at byte {offset}");
        }
        [command, path] if command == "cat" => {
            for (n, payload) in read_all(path)?.iter().enumerate() {
                println!("{n}: {}", String::from_utf8_lossy(payload));
            }
        }
        [command, path] if command == "check" => {
            let (_, recovery) = Log::open(path)?;
            report(&recovery);
            println!("{} records, all checksums valid", recovery.records);
        }
        _ => {
            return Err("usage: klog append FILE TEXT... | klog cat FILE | klog check FILE".into());
        }
    }
    Ok(())
}

fn report(recovery: &Recovery) {
    if recovery.truncated_bytes > 0 {
        eprintln!(
            "recovered: cut a torn {}-byte record from the end",
            recovery.truncated_bytes
        );
    }
}
~~~

`ExitCode::FAILURE` exits with status 1 **after** printing the error with `Display` (`{err}`), the friendly form from Step 3.

**Run it.** Write two records, read them back, and look at the raw bytes:

~~~bash
cargo build -q
./target/debug/klog append audit.log job 1 created
./target/debug/klog append audit.log job 1 completed
./target/debug/klog cat audit.log
od -A d -t x1 audit.log | head -2
~~~

~~~text
appended at byte 0
appended at byte 21
0: job 1 created
1: job 1 completed
0000000 0d 00 00 00 c3 00 51 08 6a 6f 62 20 31 20 63 72
0000016 65 61 74 65 64 0f 00 00 00 af 70 20 4f 6a 6f 62
~~~

Read the dump against the format:
- `0d 00 00 00` is the length, 13, little-endian;
- `c3 00 51 08` is the checksum;
- `6a 6f 62 20 31 ...` is ASCII for "job 1 ...";
- the second record starts at byte 21 with `0f 00 00 00`, a length of 15.

Your file *is* the format.

**The torn-write experiment.** Simulate a crash during the second write by chopping 5 bytes off the end:

~~~bash
truncate -s -5 audit.log
./target/debug/klog cat audit.log
./target/debug/klog check audit.log
ls -l audit.log
~~~

~~~text
0: job 1 created
recovered: cut a torn 18-byte record from the end
1 records, all checksums valid
~~~

`cat` ignores the torn record without touching the file. `check` opens the log, which **repairs** it: the file is now 21 bytes, the one complete record.

**The corruption experiment.** Start again with two records, then overwrite one byte *inside the first record's payload*:

~~~bash
rm audit.log
./target/debug/klog append audit.log job 1 created
./target/debug/klog append audit.log job 1 completed
printf 'X' | dd of=audit.log bs=1 seek=10 conv=notrunc
./target/debug/klog append audit.log job 2 created
~~~

~~~text
klog: log is corrupt at byte 0: checksum mismatch: header says 0x085100c3, payload gives 0x69d13bc7
~~~

It exits with status 1, and the file is unchanged. A valid-looking record *follows* the damage, so this can't be a torn write, and `klog` refuses to guess. Every command now fails until a human looks at it, which is the right outcome for a log you're trusting with records.

### A limit you must know about

Repeat the corruption experiment on a log with **only one** record. `klog` cuts it off as "torn", even though that record was written and synced successfully earlier. From the bytes alone, a torn final write and later damage to a complete final record **look identical**. `klog` chooses to treat them the same.

Real storage engines face exactly this choice. RocksDB, for example, offers several recovery modes, from "tolerate a corrupted tail" to "refuse any inconsistency". Some systems add a separate commit marker, or record the last synced offset elsewhere, to tell the cases apart. The lesson: **know which failures your design can and can't distinguish, and write it down.**

**Break it.** In `append`, delete the `self.file.sync_data()?;` line. Every test still passes, because tests don't cut the power. Durability bugs are invisible to normal tests. Phase 3 kills processes mid-write to look for them, and power-loss testing needs special hardware or fault-injecting filesystems. Restore it.

**Explain it:** why is a write not durable until it's synced? Why can only the last record of an append-only file be torn? Why refuse to open after mid-file corruption, instead of skipping the bad record?

**Read.** OSTEP Ch. 39 (*Files and Directories*, including `fsync`) and Ch. 42 (*Crash Consistency: FSCK and Journaling*). This chapter matters most for Phase 3. Carry this question in: what exactly does the disk promise after `fsync` returns?

<!-- run: cargo fmt --check && cargo clippy -q --all-targets -- -D warnings && cargo test -q -->

---

## Step 6: Threads, safely

**The problem.** In Phase 3, many request handlers will want to write audit records at once. Two threads appending to one file can interleave their bytes and corrupt both records. Go relied on you to add a mutex, and `-race` to notice when you forgot. In Rust, **the compiler refuses to build a data race**.

**New ideas.**

- **`Send`**: a type that can be *moved* to another thread. **`Sync`**: a type that can be *shared* between threads by reference. The compiler works these out automatically, and checks them whenever you start a thread.
- `Rc<T>` is a reference-counted pointer for **one** thread, so it's not `Send`. **`Arc<T>`** is the atomic, thread-safe version.
- **`Mutex<T>`** wraps the data it protects: you can only reach the data by locking. You *can't* forget the lock, because without it there's no way to the data. Compare Phase 1's `Store`, where the mutex and the map sat side by side and discipline kept them together.
- A **channel** (`mpsc`: multiple producer, single consumer) moves values from many threads to one. Instead of sharing the log, each thread **sends** records to a single writer thread that **owns** it. This is *share by communicating*, the Go proverb, enforced by ownership.
- `thread::spawn(move || ...)` starts a thread. `move` makes the closure take ownership of what it uses, because the thread may outlive the function that started it.

**Break it first: two programs the compiler rejects.**

1. Send an `Rc` to another thread:

   ~~~text
   error[E0277]: `Rc<i32>` cannot be sent between threads safely
     = help: within `{closure@src/main.rs:1:99: 1:106}`, the trait `Send` is not implemented for `Rc<i32>`
   ~~~

2. Let a thread borrow a local counter it increments:

   ~~~text
   error[E0373]: closure may outlive the current function, but it borrows `count`, which is owned by the current function
   ~~~

   The thread might still be running after `count` is gone, and two threads might increment it at once. The fix the compiler pushes you towards, `Arc<Mutex<u64>>` or a channel, is the correct design. **A data race in safe Rust doesn't compile.**

Now the single-writer design. Create `src/appender.rs`:

<!-- file: src/appender.rs -->
~~~rust
//! Many threads, one writer. Threads send payloads through a channel to a
//! single thread that owns the Log, so the file only ever has one writer
//! and records can't interleave.

use std::sync::mpsc;
use std::thread::{self, JoinHandle};

use crate::log::{Log, LogError};

pub struct Appender {
    sender: mpsc::Sender<Vec<u8>>,
    writer: JoinHandle<Result<usize, LogError>>,
}

impl Appender {
    /// Moves log into a new writer thread.
    pub fn start(mut log: Log) -> Appender {
        let (sender, receiver) = mpsc::channel::<Vec<u8>>();
        let writer = thread::spawn(move || {
            let mut written = 0;
            for payload in receiver {
                log.append(&payload)?;
                written += 1;
            }
            Ok(written)
        });
        Appender { sender, writer }
    }

    /// A handle that any thread can use to send payloads.
    pub fn sender(&self) -> mpsc::Sender<Vec<u8>> {
        self.sender.clone()
    }

    /// Stops accepting payloads and waits for the writer to finish. Every
    /// other sender must be dropped first, or this waits for them.
    pub fn finish(self) -> Result<usize, LogError> {
        drop(self.sender);
        self.writer.join().expect("the writer thread panicked")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log::read_all;

    #[test]
    fn many_threads_one_intact_log() {
        let path = std::env::temp_dir().join(format!("klog-{}-appender", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let (log, _) = Log::open(&path).unwrap();
        let appender = Appender::start(log);

        let producers: Vec<_> = (0..4)
            .map(|id| {
                let sender = appender.sender();
                thread::spawn(move || {
                    for n in 0..25 {
                        sender
                            .send(format!("thread {id} record {n}").into_bytes())
                            .unwrap();
                    }
                })
            })
            .collect();
        for producer in producers {
            producer.join().unwrap();
        }

        assert_eq!(appender.finish().unwrap(), 100);
        let records = read_all(&path).unwrap();
        assert_eq!(records.len(), 100);
        assert!(records.iter().all(|r| r.starts_with(b"thread ")));
    }
}
~~~

- `Appender::start` **moves** the `Log` into the writer thread. After that, no other code can touch the file: ownership guarantees one writer.
- `for payload in receiver` loops until every `Sender` is dropped, then the loop ends and the thread returns.
- `sender()` hands out **clones** of the sender, so many threads can send at once. The channel keeps the order of each thread's messages.
- `finish` drops its own sender, then `join`s the writer thread to collect its result.

Register the module. Change:

<!-- edit: src/lib.rs -->
~~~rust
pub mod crc;
~~~

to:

~~~rust
pub mod appender;
pub mod crc;
~~~

**Run it.** `cargo test` runs all 24 tests. `many_threads_one_intact_log` has four threads each send 25 records, then checks that the log holds exactly 100 intact records.

**Break it: a deadlock.** In `finish`, delete the line `drop(self.sender);` and run `cargo test appender`. The output stops at `running 1 test`, and **never finishes**. The writer loops "until every sender is dropped", but `finish` still holds one sender while it waits for the writer: each waits for the other forever. That's a deadlock, and the compiler can't catch it, because it's a logic error, not a memory error. Rust prevents data races, but not every concurrency bug. Restore the line, and stop the hung test with Ctrl+C.

**Explain it:** what do `Send` and `Sync` mean? Why does `Mutex<T>` *contain* its data? How does the appender guarantee a single writer without a lock around the file?

**Read.** *The Rust Programming Language*, Ch. 16 (*Fearless Concurrency*); *Rust Atomics and Locks* (Bos, free online), Ch. 1–2. Carry this question in: which of Phase 1's and Phase 2's concurrency bugs would Rust have refused to compile, and which would it not?

<!-- run: cargo fmt --check && cargo clippy -q --all-targets -- -D warnings && cargo test -q -->

---

## Checkpoint

You're ready for Phase 3 when you can, without the guide:

1. State the ownership rules, and explain move, `&` and `&mut` with an example of each.
2. Read and fix the five compiler errors from this bridge without looking anything up.
3. Write a function returning `Result` with a custom error enum, and use `?` in its caller.
4. Draw the record format byte by byte, and decode a hex dump of it by hand.
5. Explain `fsync`, torn writes, and klog's recovery rule, including the case it can't tell apart.
6. Explain `Send`, `Sync`, `Arc`, `Mutex` and channels, and the deadlock from Step 6.

## If it goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `error[E0382]: borrow of moved value` | The value was moved earlier | Borrow (`&x`) instead, or `.clone()` if a copy is really needed |
| `error[E0499]` / `E0502` | Overlapping mutable and shared borrows | Shorten one borrow's life, often by finishing with it first |
| `error[E0106]: missing lifetime specifier` | A returned reference with an unclear source | Return an owned value, or take the source as a parameter |
| `cargo fmt --check` fails | Formatting differs | Run `cargo fmt` |
| clippy warnings | An idiom or a likely bug | Read the lint's explanation link; fix rather than silence |
| A test hangs | A channel or thread waiting on itself | Look for a sender or lock still held; see Step 6's break-it |
| `Permission denied` opening the log | A path in a protected folder | Use a path in your practice folder |

## Reading list

| When | Reading |
|---|---|
| Steps 1–3 | *The Rust Programming Language* Ch. 1–10 |
| Step 2 | OSTEP Ch. 13–14; CSAPP §9.1–9.9 (virtual memory) |
| Step 4 | *Database Internals* Ch. 3; OSTEP Ch. 44 |
| Step 5 | OSTEP Ch. 39 and 42 (the most important for Phase 3) |
| Step 6 | *The Rust Programming Language* Ch. 16; *Rust Atomics and Locks* Ch. 1–2 |
