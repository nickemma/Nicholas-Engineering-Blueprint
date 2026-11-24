# 10 `select`, timeouts and the race detector

> Module: Go from zero · Time: ~4 h · Builds on: 09

## The problem

Two things go wrong as soon as goroutines meet the real world. First, waiting: a server that waits forever for a slow database stops answering everyone, so every wait needs a deadline. Second, sharing: when two goroutines change the same variable at once, updates get lost, quietly, and only sometimes. That second bug, a **data race**, is among the hardest to find by testing, because it can pass a thousand runs and fail the next. Go ships a tool that finds it for you.

## The mental model

~~~text
 select waits on several channels at once, and takes whichever is ready first:

   select {
   case v := <-answer:            ◀── the answer arrived first
   case <-time.After(100ms):      ◀── or the clock ran out first
   }

 a data race: two goroutines, one variable, at least one writing, no coordination

   goroutine A: read n (41) ─────────── write n = 42
   goroutine B:      read n (41) ──────────────────── write n = 42      one increment lost
~~~

`n++` looks like one step, but the CPU does three: read, add, write. Two goroutines can interleave them.

## The pattern

**Every wait has a deadline. Every shared variable has an owner or a lock.** A **mutex** ("mutual exclusion") lets one goroutine at a time into the code that touches shared data. And run your tests with `-race`, always.

## Build it

### Step 1: Waiting for whichever comes first

`slow` stands in for a call to another server: it answers on a channel after a delay. Create `drills/race/main.go`:

<!-- file: drills/race/main.go -->
~~~go
// Lesson 10: select, timeouts and the race detector.
package main

import (
	"fmt"
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

func main() {
	// select waits for whichever channel is ready first.
	select {
	case a := <-slow(10*time.Millisecond, "fast server"):
		fmt.Println("got:", a)
	case b := <-slow(500*time.Millisecond, "slow server"):
		fmt.Println("got:", b)
	}
}
~~~

- `time.Duration` is how Go measures time; `10*time.Millisecond` reads as it says.
- The channel has a buffer of 1, so the goroutine can always send and finish, even if nobody is still waiting for its answer. With an unbuffered channel, the loser's goroutine would wait forever: a leak.
- `select` waits until one of its cases can go ahead, and runs that one. If several are ready at the same moment, it picks one at random.

~~~bash
go run ./drills/race
~~~

<!-- run: go vet ./drills/race && go run ./drills/race | grep -qx 'got: fast server' -->

~~~text
got: fast server
~~~

### Step 2: A timeout

A timeout is just another channel: `time.After(d)` returns a channel that receives a value after `d`. Put it in a `select`:

<!-- edit: drills/race/main.go -->
~~~go
	case b := <-slow(500*time.Millisecond, "slow server"):
		fmt.Println("got:", b)
	}
~~~

~~~go
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
~~~

<!-- run: go vet ./drills/race && go run ./drills/race | grep -qx 'timed out after 100ms' -->

~~~text
got: fast server
timed out after 100ms
~~~

The program didn't wait the full 500 ms: after 100 ms it gave up and moved on. In Core 01 you'll pass deadlines through a whole service with `context`; underneath, it's this.

### Step 3: A counter many goroutines share

Now 1,000 goroutines each add 1 to the same counter. The counter protects itself with a `sync.Mutex`: `Lock` lets one goroutine in and makes any other wait; `Unlock` lets the next one in. Add `sync` to the imports:

<!-- edit: drills/race/main.go -->
~~~go
import (
	"fmt"
	"time"
)
~~~

~~~go
import (
	"fmt"
	"sync"
	"time"
)
~~~

**Starter.** Add a `Counter` type with a mutex and a count, and an `Inc` method that locks, adds one, and unlocks. Then, at the end of `main`, start 1,000 goroutines that each call `c.Inc()` once, wait for them all, and print the count.

<details>
<summary>Hint</summary>

`type Counter struct { mu sync.Mutex; n int }`. `Inc` needs a pointer receiver (lesson 05), or it would lock a copy of the mutex. Inside: `c.mu.Lock()`, then `defer c.mu.Unlock()`, then `c.n++`. Wait for the goroutines as in lesson 09.

</details>

<details>
<summary>The answer</summary>

<!-- edit: drills/race/main.go -->
~~~go
	return ch
}
~~~

~~~go
	return ch
}

// Counter is safe to use from many goroutines at once.
type Counter struct {
	mu sync.Mutex
	n  int
}

func (c *Counter) Inc() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.n++
}
~~~

<!-- edit: drills/race/main.go -->
~~~go
	case <-time.After(100 * time.Millisecond):
		fmt.Println("timed out after 100ms")
	}
~~~

~~~go
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
~~~

</details>

Run it with the **race detector**, `-race`, which watches every memory access while the program runs:

~~~bash
go run -race ./drills/race
~~~

<!-- run: go vet ./drills/race && go run -race ./drills/race | grep -qx 'counter: 1000' -->

~~~text
got: fast server
timed out after 100ms
counter: 1000
~~~

Exactly 1,000, and the race detector found nothing to report.

## Break it

Delete the two lines in `Inc` that lock and unlock, leaving only `c.n++`. Run it three times, without `-race`:

~~~bash
for i in 1 2 3; do go run ./drills/race | tail -1; done
~~~

~~~text
counter: 995
counter: 997
counter: 998
~~~

Wrong, and wrong by a different amount each time. Nothing crashed and nothing warned: the lost increments are the interleaving in the diagram above. On a quieter machine, or with fewer goroutines, it may come out right most times, which is exactly what makes races dangerous: your tests pass, and production loses data.

Now with `-race`:

~~~bash
go run -race ./drills/race
~~~

~~~text
got: fast server
timed out after 100ms
==================
WARNING: DATA RACE
Read at 0x00c000210008 by goroutine 20:
  main.(*Counter).Inc()
      /home/ada/blueprint/gofromzero/drills/race/main.go:27 +0x87
  main.main.func1()
      /home/ada/blueprint/gofromzero/drills/race/main.go:54 +0x82

Previous write at 0x00c000210008 by goroutine 15:
  main.(*Counter).Inc()
      /home/ada/blueprint/gofromzero/drills/race/main.go:27 +0xa4
  main.main.func1()
      /home/ada/blueprint/gofromzero/drills/race/main.go:54 +0x82

Goroutine 20 (running) created at:
  main.main()
      /home/ada/blueprint/gofromzero/drills/race/main.go:52 +0x531

Goroutine 15 (finished) created at:
  main.main()
      /home/ada/blueprint/gofromzero/drills/race/main.go:52 +0x531
~~~

The full output has a second report like it, then ends with:

~~~text
counter: 774
Found 2 data race(s)
exit status 66
~~~

 Read it: one goroutine **read** `c.n` at line 27, while another had **written** it at the same line, with nothing ordering the two. It names the exact line, and which goroutines, created where. Put the two lines back and the report disappears.

The race detector only sees races that actually happen while it's watching, so it can't prove there are none. That's why the gate runs your tests with `-race`, and why later modules run whole systems with it.

## Check it

~~~bash
gofmt -l . && go vet ./... && go run -race ./drills/race && go test -race ./...
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... && go test -race -count=1 ./... -->

That proves your waits have deadlines and your shared counter is safe, as far as the race detector can see. It doesn't prove your program is free of every concurrency bug: a deadlock, or two locks taken in opposite orders, aren't races. Core 01 has a lesson on a race a mutex can't fix.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `-race requires cgo` | No C compiler | `sudo apt install -y build-essential` (Foundations 01 installed it) |
| `WARNING: DATA RACE` | Two goroutines touch one variable, one writing, unsynchronised | Protect it with a mutex, or give it one owner and use channels |
| The program hangs on `Lock` | It was locked and never unlocked | `defer mu.Unlock()` right after `Lock()` |
| `passes lock by value` from `go vet` | A method with a value receiver copies the mutex | Use a pointer receiver |
| A `select` waits forever | No case can ever go ahead, and there's no timeout | Add a `time.After` case |
