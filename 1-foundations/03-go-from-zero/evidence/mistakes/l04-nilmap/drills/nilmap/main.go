package main

import "fmt"

func main() {
	var counts map[string]int // declared, but never made
	fmt.Println("reading is fine:", counts["a"])
	counts["a"]++
}
