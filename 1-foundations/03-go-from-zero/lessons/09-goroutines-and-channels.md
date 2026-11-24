# 09 Goroutines and channels

> Module: Go from zero · Time: ~4 h · Builds on: 08

## The problem

Your machine has many CPUs (Foundations 01 counted them), and much of a server's time is spent waiting: for a disk, a database, another server. A program that does one thing at a time wastes both. Go was designed for doing many things at once: you start a **goroutine** with one word, and goroutines talk through **channels**. It's the reason Go runs so much of the internet's infrastructure, and the reason the control plane you'll build in the core is written in it.

## The mental model

~~~text
 main goroutine ──go f()──▶ a new goroutine runs f, at the same time
        │
        └── waits for it: sync.WaitGroup, or by receiving from a channel

 a channel is a pipe between goroutines:
   ch <- v     send: put v in   (an unbuffered channel waits until someone receives)
   v := <-ch   receive: take a value out (waits until someone sends)
   close(ch)   no more values; a receiver's  for v := range ch  loop then ends
~~~

A goroutine costs a few kilobytes, so a program can run hundreds of thousands. Go's **scheduler** spreads them over your CPUs; Core 01 looks at how.

## The pattern

**Share memory by communicating.** Instead of several goroutines changing the same variable, pass values through channels, so only one goroutine holds each value at a time. When they must share (the next lesson), protect it.

## Build it

### Step 1: Start goroutines, and wait for them

`go f()` starts `f` in a new goroutine and carries on at once, without waiting. To wait for several to finish, use a `sync.WaitGroup`: a counter you add to before starting each goroutine, that each one decrements when it's done, and that `Wait` blocks on until it's zero. Create `drills/goroutines/main.go`:

<!-- file: drills/goroutines/main.go -->
~~~go
// Lesson 09: goroutines and channels.
package main

import (
	"fmt"
	"sync"
)

func main() {
	// Wait for several goroutines to finish.
	var wg sync.WaitGroup
	results := make([]int, 5)
	for i := range 5 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i] = i * 10 // each goroutine writes only its own element
		}()
	}
	wg.Wait()
	fmt.Println("results:", results)
}
~~~

- `go func() { ... }()` starts an anonymous function as a goroutine. The trailing `()` calls it.
- `defer wg.Done()` runs `wg.Done()` when the function returns, however it returns. Use `defer` for anything that must happen on the way out: unlocking, closing a file.
- Each goroutine writes only `results[i]`, its own element, so no two touch the same memory. That's what makes this safe without anything more.

~~~bash
go run ./drills/goroutines
~~~

<!-- run: go vet ./drills/goroutines && go run -race ./drills/goroutines | grep -qx 'results: \[0 10 20 30 40\]' -->

~~~text
results: [0 10 20 30 40]
~~~

The five goroutines may have run in any order, but each filled its own slot, so the result is always the same.

### Step 2: A buffered channel

A channel made with `make(chan string, 2)` has a **buffer** of 2: up to two sends go straight in without anyone receiving yet. Add:

<!-- edit: drills/goroutines/main.go -->
~~~go
	fmt.Println("results:", results)
~~~

~~~go
	fmt.Println("results:", results)

	// A buffered channel holds values until someone receives them.
	jobs := make(chan string, 2)
	jobs <- "first"
	jobs <- "second"
	fmt.Println("buffered:", len(jobs), "of", cap(jobs))
	fmt.Println(<-jobs, <-jobs)
~~~

<!-- run: go vet ./drills/goroutines && go run ./drills/goroutines | grep -qx 'first second' -->

~~~text
buffered: 2 of 2
first second
~~~

Values come out in the order they went in. A third send here would wait forever, since the buffer is full and nothing else is running to receive: you'll see what Go does about that below.

### Step 3: A pipeline

Goroutines connected by channels make a **pipeline**: each stage receives from the one before and sends to the one after. Here, one goroutine generates numbers, another squares them, and `main` prints the squares.

**Starter.** Write `square(in <-chan int) <-chan int`: it makes an output channel, starts a goroutine that sends the square of every number it receives from `in` and closes the output when `in` runs out, and returns the output channel straight away.

<details>
<summary>Hint</summary>

`<-chan int` is a channel you can only receive from. Inside the goroutine: `defer close(out)`, then `for n := range in { out <- n * n }`. The `range` loop ends when `in` is closed.

</details>

<details>
<summary>The answer</summary>

Add `square` before `main`:

<!-- edit: drills/goroutines/main.go -->
~~~go
func main() {
	// Wait for several goroutines to finish.
~~~

~~~go
// square reads numbers from in, and sends their squares to the channel it returns.
func square(in <-chan int) <-chan int {
	out := make(chan int)
	go func() {
		defer close(out)
		for n := range in {
			out <- n * n
		}
	}()
	return out
}

func main() {
	// Wait for several goroutines to finish.
~~~

and the pipeline at the end of `main`:

<!-- edit: drills/goroutines/main.go -->
~~~go
	fmt.Println(<-jobs, <-jobs)
~~~

~~~go
	fmt.Println(<-jobs, <-jobs)

	// A pipeline: generate, then square, then print. close ends each stage.
	numbers := make(chan int)
	go func() {
		defer close(numbers)
		for i := 1; i <= 5; i++ {
			numbers <- i
		}
	}()
	for sq := range square(numbers) {
		fmt.Print(sq, " ")
	}
	fmt.Println()
~~~

</details>

<!-- run: go vet ./drills/goroutines && go run -race ./drills/goroutines | grep -qx '1 4 9 16 25 ' -->

~~~text
1 4 9 16 25 
~~~

Follow one number through: the generator sends 1 on `numbers` and waits until `square`'s goroutine receives it; that goroutine sends 1 on `out` and waits until `main` receives it. Each **unbuffered** send waits for its receiver, so the stages run in step, and nothing piles up. When the generator closes `numbers`, `square`'s loop ends and it closes `out`, which ends `main`'s loop. Closing is how a stage says "that's everything". Only the sender closes a channel, never the receiver.

## Break it

**`main` doesn't wait.** Create `drills/noexit/main.go`:

~~~go
package main

import "fmt"

func main() {
	go fmt.Println("hello from a goroutine")
	fmt.Println("main is done")
}
~~~

~~~text
main is done
~~~

The goroutine never printed. When `main` returns, the program ends, and every other goroutine with it, finished or not. That's why step 1 needed a `WaitGroup`.

**Nobody receives.** Create `drills/deadlock/main.go`:

~~~go
package main

import "fmt"

func main() {
	ch := make(chan int)
	ch <- 1 // nobody is receiving, so this waits forever
	fmt.Println(<-ch)
}
~~~

~~~text
fatal error: all goroutines are asleep - deadlock!

goroutine 1 [chan send]:
main.main()
	/home/ada/blueprint/gofromzero/drills/deadlock/main.go:7 +0x36
exit status 2
~~~

The send on line 7 waits for a receiver, and the receive is on the next line of the same goroutine, which can't get there. No goroutine can ever move again, and Go's runtime notices and stops the program, naming what each goroutine was stuck on: `[chan send]`. (It can only spot this when *every* goroutine is stuck. In a server with others still running, a stuck goroutine just waits forever, silently: a **goroutine leak**, which Core 01's gate checks for.)

Delete both afterwards: `rm -r drills/noexit drills/deadlock`.

## Check it

~~~bash
gofmt -l . && go vet ./... && go run -race ./drills/goroutines
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... -->

`-race` runs the program with Go's race detector, which you'll meet properly in the next lesson; it should print nothing extra. That proves you can start goroutines, wait for them, and connect them with channels that close cleanly. It doesn't handle waiting with a time limit, or several goroutines changing the same variable: both are next.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| Output from goroutines is missing | `main` returned before they finished | Wait for them with a `WaitGroup` or a channel |
| `all goroutines are asleep - deadlock!` | A send or receive that nothing can ever match | Check who sends, who receives, and who closes |
| `panic: send on closed channel` | Something sent after the channel was closed | Only the sender closes, and only once it has sent everything |
| A `for range ch` loop never ends | Nobody closed the channel | Close it when the sender is done (`defer close(ch)`) |
| `negative WaitGroup counter` | More `Done` calls than `Add` | Call `wg.Add(1)` once per goroutine, before starting it |
