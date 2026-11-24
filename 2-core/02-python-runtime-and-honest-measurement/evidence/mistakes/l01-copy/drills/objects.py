"""Lesson 01: what a Python name, value and list really are."""

import sys
import tracemalloc


def names() -> None:
    print("== names are references")
    a = [1, 2]
    b = a  # a second name for the same list, not a copy
    b.append(3)
    print(f"a = {a}, b = {b}, same object: {a is b}, id(a) == id(b): {id(a) == id(b)}")
    c = a  # a new list holding the same items
    print(f"c = {c}, c == a: {c == a}, c is a: {c is a}")


def sizes() -> None:
    print("== everything is an object")
    for value in (0, 1, 2**30, 2**64, 1.5, True, "", "a", None):
        print(f"{value!r:>22}  {type(value).__name__:>8}  {sys.getsizeof(value):>3} bytes")
    print(f"a list of 1,000 items: {sys.getsizeof([0] * 1000)} bytes (8 bytes per item: a pointer)")


def million() -> None:
    print("== a million integers")
    tracemalloc.start()
    numbers = list(range(1_000_000))
    current, _ = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    each = current / len(numbers)
    print(f"list(range(1_000_000)) holds {current / 1e6:.1f} MB ({each:.0f} bytes each)")


def small_ints() -> None:
    print("== small integers are shared")
    x, y = int("256"), int("256")
    print(f"256 is 256: {x is y}")
    x, y = int("257"), int("257")
    print(f"257 is 257: {x is y}  (compare numbers with ==, never with is)")


if __name__ == "__main__":
    names()
    sizes()
    million()
    small_ints()
