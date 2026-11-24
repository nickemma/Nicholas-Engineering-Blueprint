// Lesson 01: garbage, and how often the collector runs to clear it.
package main

import (
	"fmt"
	"runtime"
	"time"
)

var keep [][]byte // a live set the program really uses: about 50 MiB

func main() {
	for range 50 {
		keep = append(keep, make([]byte, 1<<20))
	}
	start := time.Now()
	var sink []byte
	for i := 0; ; i++ {
		sink = make([]byte, 64<<10) // 64 KiB of garbage, every time
	}
	_ = sink
	took := time.Since(start)
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	fmt.Printf("allocated %d MiB in %v: %d collections, heap now %d MiB, %v paused in total\n",
		m.TotalAlloc>>20, took.Round(time.Millisecond), m.NumGC, m.HeapAlloc>>20,
		time.Duration(m.PauseTotalNs).Round(time.Microsecond))
}
