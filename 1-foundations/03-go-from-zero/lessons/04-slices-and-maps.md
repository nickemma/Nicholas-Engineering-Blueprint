# 04 Slices and maps

> Module: Go from zero · Time: ~4 h · Builds on: 03

## The problem

Almost every program holds collections: the lines of a log, the tasks in a list, how often each status code appeared. Go gives you two everyday collections, **slices** (an ordered list) and **maps** (look up a value by a key). They're easy to use and they have two famous traps. Slices can share memory, so changing one changes another. Maps come back in a different order every time. Both have caused real production bugs, and both make sense once you can picture the memory.

## The mental model

~~~text
 a slice is a small header pointing into an array:

   s := []int{1, 2, 3, 4}

   s ──▶ ┌─────────┬──────┬──────┐        backing array
         │ pointer │ len 4│ cap 4│ ─────▶ [ 1 | 2 | 3 | 4 ]
         └─────────┴──────┴──────┘
   firstTwo := s[:2]   ──▶ same pointer, len 2, cap 4   (shares the array!)
~~~

- **length** is how many elements the slice shows; **capacity** is how many fit in the array from where it starts.
- Copying a slice copies the header (24 bytes), not the elements. Two slices can show the same array.
- A **map** is a hash table: Go turns each key into a number and uses it to find a slot. Lookups are fast; the order of the slots means nothing.

## The pattern

**Know who owns the backing array.** When a function receives a slice, it can change the caller's elements. When you take a part of a slice and `append` to it, you may overwrite someone else's data. Make a copy, or cap the capacity, when in doubt.

## Build it

### Step 1: Arrays copy, slices share

An **array** has a fixed length that's part of its type: `[3]int` is three ints, no more. Assigning an array copies every element. A **slice**, `[]int`, has no length in its type; assigning it copies only the header. Create `drills/slices/main.go`:

<!-- file: drills/slices/main.go -->
~~~go
// Lesson 04: slices and maps.
package main

import "fmt"

func main() {
	// An array has a fixed length, and assigning it copies every element.
	a := [3]int{1, 2, 3}
	b := a
	b[0] = 99
	fmt.Println("arrays:", a, b)

	// A slice is a view of an array: assigning it copies the view, not the data.
	s := []int{1, 2, 3}
	t := s
	t[0] = 99
	fmt.Println("slices:", s, t)
}
~~~

~~~bash
go run ./drills/slices
~~~

<!-- run: go vet ./drills/slices && go run ./drills/slices | grep -qx 'slices: \[99 2 3\] \[99 2 3\]' -->

~~~text
arrays: [1 2 3] [99 2 3]
slices: [99 2 3] [99 2 3]
~~~

Changing `b` left `a` alone: two arrays. Changing `t` changed `s` too: one array, two views of it. You'll use slices almost always; arrays mostly appear inside them.

### Step 2: How `append` grows a slice

`append` adds to the end of a slice and returns the result. When the array is full, it allocates a bigger one, copies everything across, and returns a slice pointing there. Add at the end of `main`:

<!-- edit: drills/slices/main.go -->
~~~go
	fmt.Println("slices:", s, t)
~~~

~~~go
	fmt.Println("slices:", s, t)

	// append grows the backing array by allocating a bigger one when it's full.
	var grow []int
	for i := range 10 {
		grow = append(grow, i)
		fmt.Printf("len %2d cap %2d\n", len(grow), cap(grow))
	}
~~~

<!-- run: go vet ./drills/slices && go run ./drills/slices | grep -qx 'len 10 cap 16' -->

~~~text
len  1 cap  4
len  2 cap  4
len  3 cap  4
len  4 cap  4
len  5 cap  8
len  6 cap  8
len  7 cap  8
len  8 cap  8
len  9 cap 16
len 10 cap 16
~~~

`for i := range 10` counts from 0 to 9. `%2d` pads a number to two characters, so the columns line up.

`var grow []int` starts as a **nil slice**: length 0, no array at all, and `append` works on it. The capacity jumps 4, 8, 16: each time the array fills up, Go allocates one twice the size and copies the old elements over, so appending stays fast on average. The exact sizes depend on the Go version. Always use the slice `append` returns, `grow = append(grow, i)`: after a growth, the old header points to the old, abandoned array.

### Step 3: When `append` overwrites someone else's data

Here's the trap. Add:

<!-- edit: drills/slices/main.go -->
~~~go
		fmt.Printf("len %2d cap %2d\n", len(grow), cap(grow))
	}
~~~

~~~go
		fmt.Printf("len %2d cap %2d\n", len(grow), cap(grow))
	}

	// Two slices sharing one backing array: append can overwrite the other's data.
	nums := []int{1, 2, 3, 4}
	firstTwo := nums[:2]
	firstTwo = append(firstTwo, 99)
	fmt.Println("nums after appending to firstTwo:", nums)
~~~

<!-- run: go vet ./drills/slices && go run ./drills/slices | grep -qx 'nums after appending to firstTwo: \[1 2 99 4\]' -->

~~~text
nums after appending to firstTwo: [1 2 99 4]
~~~

`nums[:2]` is a slice of the first two elements, but its capacity is still 4: the array has room after it. So `append` didn't allocate; it wrote `99` into the next slot, which was `nums[2]`. Nothing warned you, and the `3` is gone.

The fix is to cap the capacity, with a **full slice expression**, `nums[low:high:max]`:

<!-- edit: drills/slices/main.go -->
~~~go
	fmt.Println("nums after appending to firstTwo:", nums)
~~~

~~~go
	fmt.Println("nums after appending to firstTwo:", nums)

	// A full slice expression caps the view, so append must copy.
	nums = []int{1, 2, 3, 4}
	safe := nums[:2:2]
	safe = append(safe, 99)
	fmt.Println("nums after appending to safe:    ", nums, "safe:", safe)
~~~

<!-- run: go vet ./drills/slices && go run ./drills/slices | grep -qx 'nums after appending to safe:     \[1 2 3 4\] safe: \[1 2 99\]' -->

~~~text
nums after appending to safe:     [1 2 3 4] safe: [1 2 99]
~~~

`nums[:2:2]` has length 2 and capacity 2, so `append` must allocate a new array. `nums` is untouched.

### Step 4: Maps

A **map** stores values by key: `map[string]int` maps strings to ints. Count the words in a sentence. Bring in the `strings` package:

<!-- edit: drills/slices/main.go -->
~~~go
import "fmt"
~~~

~~~go
import (
	"fmt"
	"strings"
)
~~~

and add:

<!-- edit: drills/slices/main.go -->
~~~go
	fmt.Println("nums after appending to safe:    ", nums, "safe:", safe)
~~~

~~~go
	fmt.Println("nums after appending to safe:    ", nums, "safe:", safe)

	// Maps: count words.
	counts := map[string]int{}
	for _, w := range strings.Fields("the cat saw the other cat and the dog") {
		counts[w]++
	}
	fmt.Println("the:", counts["the"], "cow:", counts["cow"])
	if _, found := counts["cow"]; !found {
		fmt.Println("no cow")
	}
~~~

<!-- run: go vet ./drills/slices && go run ./drills/slices | grep -qx 'the: 3 cow: 0' -->

~~~text
the: 3 cow: 0
no cow
~~~

- `map[string]int{}` makes an empty map, ready to use.
- `strings.Fields` splits text at spaces into a slice of words.
- `counts[w]++` works even the first time a word appears: reading a missing key gives the zero value, 0, and `++` stores 1.
- So `counts["cow"]` is 0 whether "cow" is absent or was counted zero times. To tell them apart, use the **comma-ok** form: `v, found := counts["cow"]`. `found` is `false` for a missing key. (`!` means "not".)

### Step 5: Map order is random

Ask for the words three times, then in a fixed order. Bring in `maps` and `slices`:

<!-- edit: drills/slices/main.go -->
~~~go
	"fmt"
	"strings"
~~~

~~~go
	"fmt"
	"maps"
	"slices"
	"strings"
~~~

<!-- edit: drills/slices/main.go -->
~~~go
	if _, found := counts["cow"]; !found {
		fmt.Println("no cow")
	}
~~~

~~~go
	if _, found := counts["cow"]; !found {
		fmt.Println("no cow")
	}

	// A map's order is deliberately random; sort the keys for a stable order.
	for range 3 {
		for k := range counts {
			fmt.Print(k, " ")
		}
		fmt.Println()
	}
	for _, k := range slices.Sorted(maps.Keys(counts)) {
		fmt.Print(k, "=", counts[k], " ")
	}
	fmt.Println()
~~~

<!-- run: go vet ./drills/slices && go run ./drills/slices | tail -1 | grep -qx 'and=1 cat=2 dog=1 other=1 saw=1 the=3 ' -->

~~~text
the cat saw other and dog 
other and dog the cat saw 
the cat saw other and dog 
and=1 cat=2 dog=1 other=1 saw=1 the=3 
~~~

The same map, looped over three times, came out in two different orders, and yours will differ again. Go randomises where each loop over a map starts, on purpose: early versions had a stable-looking order, and programs came to depend on it, then broke when the implementation changed. Now you can't depend on it. When order matters (output a person reads, a test), sort the keys: `maps.Keys` gives the keys, and `slices.Sorted` returns them in order.

## Break it

Create `drills/nilmap/main.go`:

~~~go
package main

import "fmt"

func main() {
	var counts map[string]int // declared, but never made
	fmt.Println("reading is fine:", counts["a"])
	counts["a"]++
}
~~~

~~~bash
go run ./drills/nilmap
~~~

~~~text
reading is fine: 0
panic: assignment to entry in nil map

goroutine 1 [running]:
main.main()
	/home/ada/blueprint/gofromzero/drills/nilmap/main.go:8 +0xa5
exit status 2
~~~

`var counts map[string]int` declares a map variable whose zero value is `nil`: no hash table exists yet. Reading from it is allowed and gives zero values; writing panics. Make the map first, with `map[string]int{}` or `make(map[string]int)`. (Unlike a map, a nil *slice* is fine to `append` to.) Delete it after: `rm -r drills/nilmap`.

## Check it

~~~bash
gofmt -l . && go vet ./... && go run ./drills/slices
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... -->

Your first three map lines may come out in any order; the rest should match. That proves you can predict when slices share memory and when maps need sorting. It doesn't cover slices of structs or maps of slices, which you'll build in the task engine (lesson 08).

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| A slice changed when you only touched another one | They share a backing array | Copy (`slices.Clone(s)`) or cap it (`s[:n:n]`) |
| `append` seems to do nothing | You didn't keep its result | `s = append(s, x)` |
| `panic: assignment to entry in nil map` | The map was declared but never made | `m := map[K]V{}` or `make(map[K]V)` |
| A test passes, then fails on the next run | It depends on map order | Sort the keys before comparing or printing |
| `invalid argument: index 5 out of bounds [0:3]` at compile time | An array index Go can check while compiling | Use an index within the array's length |
