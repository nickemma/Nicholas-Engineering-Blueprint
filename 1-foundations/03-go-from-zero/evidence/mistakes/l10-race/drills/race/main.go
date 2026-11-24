// Lesson 10: select, timeouts and the race detector.
package main

import (
	"fmt"
	"sync"
	"time"
)

// slow sends its answer after a delay.
func slow(d time.Duration, answer string) <-chan string {
	ch := make(chan string, 1)
	go func() {
		time.Sleep(d)
		ch <- answer
	}()
	return ch
}

// Counter is safe to use from many goroutines at once.
type Counter struct {
	mu sync.Mutex
	n  int
}

func (c *Counter) Inc() {
	c.n++
}

func main() {
	// select waits for whichever channel is ready first.
	select {
	case a := <-slow(10*time.Millisecond, "fast server"):
		fmt.Println("got:", a)
	case b := <-slow(500*time.Millisecond, "slow server"):
		fmt.Println("got:", b)
	}

	// A timeout is just another channel.
	select {
	case a := <-slow(500*time.Millisecond, "too late"):
		fmt.Println("got:", a)
	case <-time.After(100 * time.Millisecond):
		fmt.Println("timed out after 100ms")
	}

	// 1,000 goroutines each add one, protected by a mutex.
	var c Counter
	var wg sync.WaitGroup
	for range 1000 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c.Inc()
		}()
	}
	wg.Wait()
	fmt.Println("counter:", c.n)
}
