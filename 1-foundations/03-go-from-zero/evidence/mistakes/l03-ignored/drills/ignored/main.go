package main

import (
	"fmt"
	"strconv"
)

func main() {
	n, _ := strconv.Atoi("abc") // the error is thrown away
	fmt.Println("n is", n)

	nums := []int{1, 2, 3}
	i := 5
	fmt.Println(nums[i])
}
