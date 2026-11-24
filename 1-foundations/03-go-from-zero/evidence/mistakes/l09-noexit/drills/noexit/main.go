package main

import "fmt"

func main() {
	go fmt.Println("hello from a goroutine")
	fmt.Println("main is done")
}
