"""Lesson 01: when Python frees an object."""

import gc
import sys


class Noisy:
    """Says when it's freed."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.partner: Noisy | None = None

    def __del__(self) -> None:
        print(f"   freed {self.name}")


def counting() -> None:
    print("== reference counting")
    a = Noisy("a")
    print(f"refcount of a: {sys.getrefcount(a)}")
    b = a
    print(f"after b = a: {sys.getrefcount(a)}")
    del b
    print(f"after del b: {sys.getrefcount(a)}")
    print("del a:")
    del a
    print("(freed at once: the count reached zero)")


def cycles() -> None:
    print("== a cycle")
    x, y = Noisy("x"), Noisy("y")
    x.partner, y.partner = y, x  # each keeps the other alive
    print("del x, y:")
    del x, y
    print("(nothing freed: each still has a reference from the other)")
    print("gc.collect():")
    found = gc.collect()
    print(f"(the cycle collector found {found} unreachable objects)")
    gc.enable()


if __name__ == "__main__":
    counting()
    cycles()
