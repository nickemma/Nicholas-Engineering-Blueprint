# Self-check: Go from zero

## Explain it

Answer in your own words. Where you can, point at something you ran.

### 01 Values, types and variables

1. What's a zero value, and why does Go have them?
2. Why did adding 1 to `math.MaxInt64` give a negative number, and why did `math.MaxInt64 + 1` as a constant not even compile?
3. `len("café")` is 5. Why, and what does `for i, r := range` give you instead?

### 02 Control flow and functions

1. Why does Go refuse to compile a variable you never use?
2. What are the three shapes of `for`?
3. Why did removing `default` from the `switch` cause "missing return"?

### 03 Errors as values

1. Why does Go return errors instead of throwing exceptions? What does it cost, and what does it buy?
2. What does `%w` do in `fmt.Errorf`, and how does `errors.Is` use it?
3. What's the difference between an error and a panic? Give one of each from your runs.

### 04 Slices and maps

1. Draw a slice: what are its three parts?
2. Why did appending to `firstTwo` change `nums`? How did `nums[:2:2]` prevent it?
3. Why does Go randomise map order? How do you print a map in a fixed order?
4. Why can you read from a nil map but not write to it?

### 05 Structs, methods and pointers

1. What happens to a struct when you assign it to another variable?
2. When does a method need a pointer receiver?
3. What does "nil pointer dereference" mean?

### 06 Interfaces

1. How does a type satisfy an interface in Go? What's different from languages where you declare it?
2. Why is `io.Writer` so useful? Name three things you can write to with the same code.

### 07 Tests

1. What makes a test table-driven, and why do subtests help when one row fails?
2. What does test coverage tell you, and what doesn't it?

### 08 Packages, files and JSON

1. Why does `tasks.Save` write a temporary file and rename it, instead of writing `tasks.json` directly?
2. Why does `tasks` exit with 1 for an unknown task but 2 for `done abc`?
3. Why does the `json` struct tag exist?

### 09 Goroutines and channels

1. Why did "hello from a goroutine" never print?
2. What does an unbuffered channel do when you send and nobody receives? What did Go say?
3. Who should close a channel, and what does closing it tell the receiver?

### 10 `select`, timeouts and the race detector

1. What does `select` do when several channels are ready?
2. Why did the unprotected counter come out below 1,000, and differently each time?
3. What does `-race` find, and what can't it find?

### 11 Streaming a large log

1. Why does reading line by line need far less memory than reading the whole file? What did you measure?
2. What does "token too long" mean, and how did you fix it?
3. Why did passing `scanner.Bytes()` to the workers give wrong counts, when `scanner.Text()` didn't?
4. Why does each worker have its own `Stats` instead of sharing one with a mutex?

## From memory

Close the lessons. Without notes:

1. Write a function that parses a string into an `int` between 1 and 10, returning a wrapped error for text and a sentinel error for out-of-range numbers, with a table-driven test.
2. Write a program that counts the lines in a file given as an argument, streaming it, and exits 1 if the file can't be opened.
3. Start 10 goroutines that each send their number on a channel, then receive and sum all ten in `main`, without a deadlock and without `time.Sleep`.
4. Write a counter type that 1,000 goroutines can increment safely, and prove it with `-race`.
