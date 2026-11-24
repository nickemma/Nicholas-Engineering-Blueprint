// Lesson 01: values, types and variables.
package main

import (
	"fmt"
	"math"
	"unsafe"
)

func main() {
	// Declaring variables.
	var name string = "Ada"
	age := 36
	height := 1.65
	fmt.Println(name, age, height)
	fmt.Printf("%v is a %T, %v is a %T, %v is a %T\n", name, name, age, age, height, height)

	// Zero values: every variable starts with one.
	var count int
	var ratio float64
	var ok bool
	var label string
	fmt.Printf("zero values: %d %v %v %q\n", count, ratio, ok, label)

	// How much memory each type takes.
	fmt.Println("bytes: int", unsafe.Sizeof(count), "float64", unsafe.Sizeof(ratio),
		"bool", unsafe.Sizeof(ok), "string", unsafe.Sizeof(label))

	// Integers have limits, and wrap around without warning.
	var big int64 = math.MaxInt64
	fmt.Println("largest int64:", big)
	big++
	fmt.Println("one more:     ", big)

	// Converting between types is always explicit.
	total := 7
	share := total / 2.0 + height
	fmt.Println("share:", share, "rounded down:", total/2)

	// A string is a sequence of bytes, not characters.
	word := "café"
	fmt.Println("bytes:", len(word), "first byte:", word[0], "as a letter:", string(word[0]))
	for i, r := range word {
		fmt.Printf("byte %d: %c\n", i, r)
	}
}
