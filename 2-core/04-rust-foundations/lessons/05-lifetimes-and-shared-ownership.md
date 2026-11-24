# 05 Lifetimes and shared ownership

> About 5 hours · Work in the same `klog` package throughout the module.

## The problem

A function returns a slice from one of two inputs. A separate report needs to keep shared text after the original handle goes out of scope.

## The mental model

A reference borrows data. The lifetime in a signature relates that borrow to its inputs. `Box<T>` owns a value on the heap. `Rc<T>` counts owning handles on one thread and drops the value when the last handle goes away.

## The pattern

Use a borrow when the caller already keeps the bytes alive. Use an owning pointer when the value must outlive a temporary binding. Keep ownership and mutation decisions visible in the types.

## Build it

### Step 1. Tie a returned view to both inputs

The `'a` in `longer` gives callers a lifetime that fits both inputs. The function can choose either reference.

Create `src/sharing.rs`.

<!-- file: src/sharing.rs -->
~~~rust
use std::rc::Rc;

pub fn longer<'a>(first: &'a str, second: &'a str) -> &'a str {
    if first.len() >= second.len() {
        first
    } else {
        second
    }
}

pub fn shared_labels(label: String) -> (Rc<str>, Rc<str>) {
    let first: Rc<str> = Rc::from(label);
    let second = Rc::clone(&first);
    (first, second)
}

pub enum List {
    Empty,
    Node(u32, Box<List>),
}

impl List {
    pub fn prepend(self, value: u32) -> Self {
        Self::Node(value, Box::new(self))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn view_borrows_an_input() {
        let a = String::from("resize");
        let b = String::from("job");
        assert_eq!(longer(&a, &b), "resize");
    }

    #[test]
    fn cloning_rc_shares_one_allocation() {
        let (a, b) = shared_labels(String::from("thumbnail"));
        assert!(Rc::ptr_eq(&a, &b));
        assert_eq!(Rc::strong_count(&a), 2);
        drop(a);
        assert_eq!(b.as_ref(), "thumbnail");
        assert_eq!(Rc::strong_count(&b), 1);
    }

    #[test]
    fn a_box_makes_the_recursive_variant_fixed_size() {
        let list = List::Empty.prepend(3).prepend(7);
        let List::Node(head, tail) = list else {
            panic!("expected a node");
        };
        assert_eq!(head, 7);
        assert!(matches!(*tail, List::Node(3, _)));
    }
}
~~~

Add this to `src/lib.rs`.

<!-- append: src/lib.rs -->
~~~rust
pub mod sharing;
~~~

### Step 2. Return a reference the compiler cannot accept

Create `drills/dangling.rs`.

<!-- file: drills/dangling.rs -->
~~~rust
fn main() {
    println!("{}", make_label());
}

fn make_label() -> &'static str {
    let label = String::from("job");
    &label
}
~~~

~~~bash
bash drills/expect-error.sh drills/dangling.rs E0515
~~~

<!-- run: bash drills/expect-error.sh drills/dangling.rs E0515 -->

~~~text
error[E0515]: cannot return reference to local variable `label`
~~~

### Step 3. Draw the drop order

For the list, the enum holds a number and an owning pointer to its tail. For the labels, both handles point to shared text. Dropping one label decrements its count. Dropping the last releases the shared data.

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Change the rejected function to return an owned `String`. Then explain why giving a local reference the annotation `'static` cannot extend the life of its allocation.

## If it goes wrong

If the compiler says a value is borrowed for too short a time, draw which scope drops its owner. If a recursive enum has infinite size, add indirection at the recursive field.
