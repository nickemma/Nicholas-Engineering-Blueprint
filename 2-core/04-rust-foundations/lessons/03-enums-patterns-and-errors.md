# 03 Enums, patterns, and errors

> About 5 hours · Work in the same `klog` package throughout the module.

## The problem

A duration may be empty, use a unit you do not support, or contain a number too large to multiply.

## The mental model

`Result<T, E>` carries either `Ok(T)` or `Err(E)`. Each variant of an enum can have a different payload. Pattern matching exposes the payload where it is valid.

## The pattern

Give callers a typed error enum. Use `Display` for the message a user reads and `?` to return an error early. Check arithmetic whose result can overflow.

## Build it

### Step 1. Define the custom error and parser

The parser accepts whole milliseconds, seconds, or minutes. `split_at` borrows the piece on each side. `checked_mul` reports overflow with `None`, which becomes a parse error.

Create `src/duration.rs`.

<!-- file: src/duration.rs -->
~~~rust
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

### Step 2. Expose the module and exercise it

The executable parses one argument. It prints a result on success and returns a failure exit code on malformed input.

Add this to `src/lib.rs`.

<!-- append: src/lib.rs -->
~~~rust
pub mod duration;
~~~

Create `src/bin/parse-duration.rs`.

<!-- file: src/bin/parse-duration.rs -->
~~~rust
use std::process::ExitCode;

fn main() -> ExitCode {
    let input = std::env::args().nth(1).unwrap_or_default();
    match klog::duration::parse(&input) {
        Ok(value) => {
            println!("{} ms", value.as_millis());
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("{err}");
            ExitCode::FAILURE
        }
    }
}
~~~

~~~bash
cargo run --quiet --bin parse-duration -- 3m
~~~

<!-- run: cargo run --quiet --bin parse-duration -- 3m -->

~~~bash
! cargo run --quiet --bin parse-duration -- 2h
~~~

<!-- run: ! cargo run --quiet --bin parse-duration -- 2h -->

~~~text
180000 ms
unknown unit "h" (use ms, s or m)
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Write the branches a caller could use to handle an empty value differently from an unknown unit. Explain what would happen if the minutes conversion used unchecked multiplication in a release build.

## If it goes wrong

If Clippy points at an unchecked conversion, identify the possible input range and use a checked operation. If the error displays its enum variant instead of the user-facing text, check the format placeholder.
