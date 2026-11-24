// Lesson 02: control flow and functions.
package main

import "fmt"

// classify says how busy a server is from its load and its number of CPUs.
func classify(load float64, cpus int) string {
	switch perCPU := load / float64(cpus); {
	case perCPU < 0.7:
		return "fine"
	case perCPU < 1.0:
		return "busy"
	case perCPU >= 1.0:
		return "overloaded"
	}
}

// divmod returns the quotient and the remainder.
func divmod(a, b int) (int, int) {
	return a / b, a % b
}

func main() {
	for _, load := range []float64{0.5, 3.2, 7.9, 12} {
		fmt.Printf("load %.1f on 4 CPUs: %s\n", load, classify(load, 4))
	}

	q, r := divmod(17, 5)
	fmt.Println("17 / 5 =", q, "remainder", r)

	// The three shapes of for.
	sum := 0
	for i := 1; i <= 10; i++ {
		sum += i
	}
	n := 1
	for n < 100 {
		n *= 2
	}
	tries := 0
	for {
		tries++
		if tries == 3 {
			break
		}
	}
	fmt.Println("sum:", sum, "first power of two over 100:", n, "tries:", tries)

	// if with a short statement: x exists only inside the if.
	if x := sum % 7; x == 0 {
		fmt.Println(sum, "divides by 7")
	} else {
		fmt.Println(sum, "leaves", x, "when divided by 7")
	}
}
