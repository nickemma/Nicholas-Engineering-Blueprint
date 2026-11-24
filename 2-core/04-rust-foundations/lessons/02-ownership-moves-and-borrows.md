# 02 Ownership, moves, and borrows

> About 6 hours · Work in the same `klog` package throughout the module.

## The problem

A log decoder will pass bytes to its caller. Both sides need to agree on who owns the buffer and when it can change.

## The mental model

```text
String owner [pointer | length | capacity] -> heap bytes
&str borrow [pointer | length]            -> a range of those bytes
```
A move transfers the owning handle. The buffer can stay where it is. When the last owner of an owned value is dropped, its resources are released. A `Copy` type such as `u64` can leave a usable copy behind.

## The pattern

Take `&T` to read, `&mut T` to mutate exclusively, and `T` when the caller should give up ownership. A borrow has to end before the underlying data can be moved or changed in a way that invalidates it.

## Build it

### Step 1. Add a library target and borrow some text

Create `src/lib.rs`.

<!-- file: src/lib.rs -->
~~~rust
pub mod ownership;
~~~

Create `src/ownership.rs`.

<!-- file: src/ownership.rs -->
~~~rust
pub fn first_word(text: &str) -> Option<&str> {
    text.split_whitespace().next()
}

pub fn add_separator(line: &mut String) {
    line.push_str(" | ");
}

pub fn into_bytes(line: String) -> Vec<u8> {
    line.into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_borrow_points_into_the_original_text() {
        let input = String::from("resize cover");
        let word = first_word(&input).unwrap();
        assert_eq!(word, "resize");
        assert_eq!(word.as_ptr(), input.as_ptr());
    }

    #[test]
    fn mutation_then_transfer() {
        let mut input = String::from("job");
        add_separator(&mut input);
        let bytes = into_bytes(input);
        assert_eq!(bytes, b"job | ");
    }
}
~~~

### Step 2. Move an owner and read the diagnostic

Create `drills/moved.rs`.

<!-- file: drills/moved.rs -->
~~~rust
fn main() {
    let first = String::from("job");
    let second = first;
    println!("{first} {second}");
}
~~~

~~~bash
bash drills/expect-error.sh drills/moved.rs E0382
~~~

<!-- run: bash drills/expect-error.sh drills/moved.rs E0382 -->

~~~text
error[E0382]: borrow of moved value: `first`
~~~

### Step 3. Try growing a buffer while a borrowed slice is still needed

A grow operation can allocate a larger buffer and move its contents. The compiler rejects the next example because the live slice would have to remain usable after the mutation.

Create `drills/alias.rs`.

<!-- file: drills/alias.rs -->
~~~rust
fn main() {
    let mut bytes = vec![1, 2, 3];
    let view = &bytes[..2];
    bytes.push(4);
    println!("{view:?}");
}
~~~

~~~bash
bash drills/expect-error.sh drills/alias.rs E0502
~~~

<!-- run: bash drills/expect-error.sh drills/alias.rs E0502 -->

~~~text
error[E0502]: cannot borrow `bytes` as mutable because it is also borrowed as immutable
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Move the use of `view` above the `push` and compile again. Draw which value owns the allocation after `into_bytes` returns.

## If it goes wrong

If a borrow keeps a mutable operation from compiling, find where the borrowed view is last used. Read the diagnostic before adding a copy.
