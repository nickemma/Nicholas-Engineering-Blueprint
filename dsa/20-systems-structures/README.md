# 20. Systems data structures

Build two fixed-memory structures in Go and Python. Use a fresh workspace with Go 1.26 and Python 3.11 or later. The examples are single-threaded.

## Bounded ring buffer

Keep a head index and a count. The next insertion index is `(head + count) mod capacity`. Reject an insertion when the buffer is full so unread entries survive. Return a separate success value on pop so a stored zero or None can be distinguished from an empty buffer. Clear the vacated slot to release the old reference. Push and pop take constant time.

Trace a capacity-two ring through push, push, rejected push, pop, then push. The last push wraps to index zero. Compare the same indexing idea with the producer and consumer synchronization in the [Rust systems ring](../../2-core/05-rust-for-systems/README.md).

## Bloom filter

Hash each UTF-8 key into four positions in a fixed bit array. A zero bit rules out the key. If all four bits are set, check the underlying store for the exact answer. Collisions can set every bit for an absent key. Clearing those bits on deletion would also affect other keys, so this filter has no delete operation.

Four probes cost constant time after reading and hashing the key. Space is fixed at construction. Increasing the number of inserted keys fills more bits and increases false positives for a fixed filter size. See how Switchyard uses a filter to skip unnecessary reads in the [Rust storage engine](../../3-tracks/storage-engines/03-rust-storage-engine/README.md).

Create `go.mod`.

<!-- file: go.mod -->
~~~go
module blueprint/structures

go 1.26
~~~

Create `structures.go`.

<!-- file: structures.go -->
~~~go
package structures

import (
	"crypto/sha256"
	"encoding/binary"
)

// Ring is a fixed-capacity, single-threaded FIFO.
type Ring[T any] struct {
	items      []T
	head, size int
}

func NewRing[T any](capacity int) *Ring[T] {
	if capacity < 1 {
		panic("ring capacity must be positive")
	}
	return &Ring[T]{items: make([]T, capacity)}
}

func (r *Ring[T]) Push(item T) bool {
	if r.size == len(r.items) {
		return false
	}
	r.items[(r.head+r.size)%len(r.items)] = item
	r.size++
	return true
}

func (r *Ring[T]) Pop() (T, bool) {
	var zero T
	if r.size == 0 {
		return zero, false
	}
	item := r.items[r.head]
	r.items[r.head] = zero
	r.head = (r.head + 1) % len(r.items)
	r.size--
	return item, true
}

// Bloom uses four 32-bit portions of a SHA-256 digest as bit indices.
type Bloom struct {
	bits []byte
}

func NewBloom(bytes int) *Bloom {
	if bytes < 1 {
		panic("filter size must be positive")
	}
	return &Bloom{bits: make([]byte, bytes)}
}

func (b *Bloom) positions(key string) [4]uint64 {
	sum := sha256.Sum256([]byte(key))
	var positions [4]uint64
	for i := range positions {
		word := sum[i*4 : i*4+4]
		value := uint64(binary.BigEndian.Uint32(word))
		positions[i] = value % (8 * uint64(len(b.bits)))
	}
	return positions
}

func (b *Bloom) Add(key string) {
	for _, position := range b.positions(key) {
		b.bits[position/8] |= 1 << (position % 8)
	}
}

func (b *Bloom) MightContain(key string) bool {
	for _, position := range b.positions(key) {
		if b.bits[position/8]&(1<<(position%8)) == 0 {
			return false
		}
	}
	return true
}
~~~

Create `structures_test.go`.

<!-- file: structures_test.go -->
~~~go
package structures

import (
	"fmt"
	"testing"
)

func TestRingWraparound(t *testing.T) {
	r := NewRing[int](2)
	if _, ok := r.Pop(); ok {
		t.Fatal("empty ring returned an item")
	}
	if !r.Push(0) || !r.Push(1) || r.Push(99) {
		t.Fatal("ring did not enforce capacity")
	}
	for want := range 3 {
		got, ok := r.Pop()
		if !ok || got != want {
			t.Fatalf("pop = %d, %v, want %d, true", got, ok, want)
		}
		if want == 0 && !r.Push(2) {
			t.Fatal("ring did not reuse its first slot")
		}
	}
	if _, ok := r.Pop(); ok {
		t.Fatal("drained ring returned an item")
	}
}

func TestBloom(t *testing.T) {
	filter := NewBloom(1024)
	for i := range 1000 {
		filter.Add(fmt.Sprintf("present-%d", i))
	}
	for i := range 1000 {
		if !filter.MightContain(fmt.Sprintf("present-%d", i)) {
			t.Fatalf("missing inserted key %d", i)
		}
	}
	positives := 0
	for i := range 10000 {
		if filter.MightContain(fmt.Sprintf("absent-%d", i)) {
			positives++
		}
	}
	t.Logf("%d of 10000 absent keys tested positive", positives)
	if positives == 0 || positives > 500 {
		t.Fatalf("unexpected false-positive count %d for this fixture", positives)
	}
}
~~~

Create `structures.py`.

<!-- file: structures.py -->
~~~python
from hashlib import sha256


class Ring:
    def __init__(self, capacity: int):
        if capacity < 1:
            raise ValueError("ring capacity must be positive")
        self.items = [None] * capacity
        self.head = 0
        self.size = 0

    def push(self, item: object) -> bool:
        if self.size == len(self.items):
            return False
        self.items[(self.head + self.size) % len(self.items)] = item
        self.size += 1
        return True

    def pop(self) -> tuple[object, bool]:
        if self.size == 0:
            return None, False
        item = self.items[self.head]
        self.items[self.head] = None
        self.head = (self.head + 1) % len(self.items)
        self.size -= 1
        return item, True


class Bloom:
    def __init__(self, byte_count: int):
        if byte_count < 1:
            raise ValueError("filter size must be positive")
        self.bits = bytearray(byte_count)

    def positions(self, key: str):
        digest = sha256(key.encode("utf-8")).digest()
        for offset in range(0, 16, 4):
            word = int.from_bytes(digest[offset : offset + 4], "big")
            yield word % (8 * len(self.bits))

    def add(self, key: str) -> None:
        for position in self.positions(key):
            self.bits[position // 8] |= 1 << (position % 8)

    def might_contain(self, key: str) -> bool:
        return all(self.bits[position // 8] & (1 << (position % 8)) for position in self.positions(key))
~~~

Create `test_structures.py`.

<!-- file: test_structures.py -->
~~~python
import unittest

from structures import Bloom, Ring


class StructuresTest(unittest.TestCase):
    def test_ring_wraparound(self):
        ring = Ring(2)
        self.assertEqual(ring.pop(), (None, False))
        self.assertTrue(ring.push(None))
        self.assertTrue(ring.push(1))
        self.assertFalse(ring.push(99))
        self.assertEqual(ring.pop(), (None, True))
        self.assertTrue(ring.push(2))
        self.assertEqual(ring.pop(), (1, True))
        self.assertEqual(ring.pop(), (2, True))
        self.assertEqual(ring.pop(), (None, False))

    def test_bloom(self):
        bloom = Bloom(1024)
        for i in range(1000):
            bloom.add(f"present-{i}")
        self.assertTrue(all(bloom.might_contain(f"present-{i}") for i in range(1000)))
        positives = sum(bloom.might_contain(f"absent-{i}") for i in range(10000))
        print(f"{positives} of 10000 absent keys tested positive")
        self.assertGreater(positives, 0)
        self.assertLessEqual(positives, 500)
~~~

## Check it

~~~bash
go test -v ./...
python3 -m unittest -v
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -v ./... && python3 -m unittest -v -->

Both runs rejected a full-ring write and preserved FIFO order through wraparound. Each filter found every inserted key and returned 220 positives on 10,000 absent keys, or 2.2% for this fixture.

## Practice

Repeat with 512 and 2,048 bytes and predict which change reduces the observed false-positive rate. Then run the ring test with capacity one. State which invariants make both operations constant time.
