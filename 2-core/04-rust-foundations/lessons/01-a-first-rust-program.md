# 01 A first Rust program

> About 5 hours · Work in the same `klog` package throughout the module.

## The problem

You have a sample of request durations. Report how many are slow, then calculate a mean. An empty sample needs its own outcome.

## The mental model

A Cargo package describes its targets in `Cargo.toml`. The first target is the executable at `src/main.rs`. An array owns a fixed number of values. A slice borrows a view with a length.

## The pattern

Use functions with explicit input and output types. An `Option<T>` is either `Some(T)` or `None`, and a `match` has to cover each case.

## Build it

### Step 1. Check the compiler and create the package

With the stable Rust toolchain installed, run `rustc --version` and `cargo --version`. This module needs Rust 1.89 or newer for the file locking used later. Start in an empty directory with a `src` subdirectory. The replay creates directories for the marked files.

Create `Cargo.toml`.

<!-- file: Cargo.toml -->
~~~toml
[package]
name = "klog"
version = "0.1.0"
edition = "2024"
rust-version = "1.89"
default-run = "klog"
~~~

### Step 2. Bind a value and call a function

A `let` binding is immutable by default. Use `let mut` for the count that changes inside the loop. The `u64` values hold whole milliseconds and `f64` is the floating-point result. The `as` casts make the conversion visible. Very large whole values can round when converted to a float.

Create `src/main.rs`.

<!-- file: src/main.rs -->
~~~rust
fn mean(values: &[u64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let mut sum = 0.0;
    for &value in values {
        sum += value as f64;
    }
    Some(sum / values.len() as f64)
}

fn main() {
    let samples = [12, 15, 11, 250, 14];
    let mut slow = 0;
    for ms in samples {
        if ms > 100 {
            slow += 1;
        }
    }
    println!("{} requests, {slow} slow", samples.len());
    match mean(&samples) {
        Some(value) => println!("mean: {value:.1} ms"),
        None => println!("no requests"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mean_handles_empty_input() {
        assert_eq!(mean(&[]), None);
    }

    #[test]
    fn mean_handles_a_nonempty_slice() {
        assert_eq!(mean(&[12, 18]), Some(15.0));
    }
}
~~~

~~~bash
cargo run --quiet
~~~

<!-- run: cargo run --quiet -->

~~~text
5 requests, 1 slow
mean: 60.4 ms
~~~

### Step 3. Prove that the compiler checks the missing case

A separate source file intentionally leaves out the `None` arm. Keep these compiler drills outside `src` so Cargo can still build the package.

Create `drills/non_exhaustive.rs`.

<!-- file: drills/non_exhaustive.rs -->
~~~rust
fn main() {
    let value: Option<u64> = None;
    match value {
        Some(ms) => println!("{ms}"),
    }
}
~~~

Create `drills/expect-error.sh`.

<!-- file: drills/expect-error.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if rustc --edition=2024 --emit=metadata --out-dir "$work" "$1" > "$work/error" 2>&1; then
  printf 'expected the compiler to reject %s\n' "$1" >&2
  exit 1
fi
grep -F "error[$2]" "$work/error"
~~~

~~~bash
bash drills/expect-error.sh drills/non_exhaustive.rs E0004
~~~

<!-- run: bash drills/expect-error.sh drills/non_exhaustive.rs E0004 -->

~~~text
error[E0004]: non-exhaustive patterns: `None` not covered
~~~

### Step 4. Run formatting, lint, and tests

`cargo test` compiles the test module marked with `#[cfg(test)]`. `cargo fmt` applies the formatter. Clippy checks the code for common mistakes.

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Replace the sample with an empty `[u64; 0]`. Predict what the executable prints before running it. Then restore the sample.

## If it goes wrong

If Cargo says it cannot find the manifest, run from the directory containing `Cargo.toml`. If the compiler names an unmatched case, add an arm for that variant.
