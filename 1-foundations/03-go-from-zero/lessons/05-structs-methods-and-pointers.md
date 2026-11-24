# 05 Structs, methods and pointers

> Module: Go from zero · Time: ~4 h · Builds on: 04

## The problem

A task in a to-do list isn't one value: it has a number, a title, and whether it's done. You need to keep those together, pass them around as one thing, and write functions that belong to them. And you need to know, every time you pass one to a function, whether the function gets *your* task or a copy of it. Get that wrong and a "mark as done" silently does nothing, which is exactly the bug at the end of this lesson.

## The mental model

~~~text
 t := Task{ID: 1, Title: "learn structs"}

 t  ┌──────┬────────────────────┬───────┐
    │ ID 1 │ Title "learn ..."  │ false │   one block of memory, fields side by side
    └──────┴────────────────────┴───────┘
      ▲
 p := &t    p holds t's address: p ──▶ t      (*p is t itself)

 u := t     u is a second block, a copy of every field
~~~

A **struct** groups named fields into one value. Assigning it, or passing it to a function, **copies the whole struct**. A **pointer** holds the address of a value instead, so whoever has the pointer works on the original.

## The pattern

**Copy small values; share through pointers on purpose.** Pass a struct by value when the function only reads it. Pass a pointer when the function must change it, and say so in its name.

## Build it

### Step 1: A struct, and copying it

Create `drills/structs/main.go`:

<!-- file: drills/structs/main.go -->
~~~go
// Lesson 05: structs, methods and pointers.
package main

import "fmt"

// Task is one thing to do.
type Task struct {
	ID    int
	Title string
	Done  bool
}

func main() {
	t := Task{ID: 1, Title: "learn structs"}
	fmt.Printf("%+v\n", t)

	u := t // a copy of every field
	u.Title = "a copy"
	fmt.Println(t.Title, "/", u.Title)
}
~~~

- `type Task struct { ... }` defines a new type with three fields. Names starting with a capital letter (`Task`, `ID`) are **exported**: other packages can see them. You'll need that in lesson 08.
- `Task{ID: 1, Title: "learn structs"}` is a **struct literal**; `Done`, not mentioned, gets its zero value, `false`.
- `%+v` prints a struct with its field names.

~~~bash
go run ./drills/structs
~~~

<!-- run: go vet ./drills/structs && go run ./drills/structs | grep -qx 'learn structs / a copy' -->

~~~text
{ID:1 Title:learn structs Done:false}
learn structs / a copy
~~~

Changing `u.Title` left `t` alone: `u := t` copied every field.

### Step 2: A pointer

`&t` is the **address** of `t`, a value of type `*Task` ("pointer to Task"). Add:

<!-- edit: drills/structs/main.go -->
~~~go
	fmt.Println(t.Title, "/", u.Title)
~~~

~~~go
	fmt.Println(t.Title, "/", u.Title)

	p := &t // the address of t
	p.Title = "changed through a pointer"
	fmt.Println(t.Title)
~~~

<!-- run: go vet ./drills/structs && go run ./drills/structs | grep -qx 'changed through a pointer' -->

~~~text
changed through a pointer
~~~

`p.Title` reaches through the pointer to `t`'s field (it's short for `(*p).Title`). There's still only one `Task`; `p` is another way to get at it.

### Step 3: Methods, and which receiver to use

A **method** is a function attached to a type. The type it's attached to comes before the name, as the **receiver**: `func (t Task) Describe() string`. Whether the receiver is a value (`t Task`) or a pointer (`t *Task`) decides whether the method gets a copy or the original.

**Starter.** Add three methods after the `Task` type:

- `Describe() string` returns the task as `1 [ ] learn structs`, or with `x` when done. It only reads, so give it a value receiver.
- `FinishCopy()`, with a **value** receiver, sets `Done` to `true`.
- `Finish()`, with a **pointer** receiver, sets `Done` to `true`.

Then, at the end of `main`, call `t.FinishCopy()` and print `t.Describe()`, then call `t.Finish()` and print it again. Predict both lines before you run it.

<details>
<summary>Hint</summary>

`fmt.Sprintf` formats like `Printf` but returns the string instead of printing it. Inside a method, the receiver is an ordinary variable: `t.Done = true`.

</details>

<details>
<summary>The answer</summary>

<!-- edit: drills/structs/main.go -->
~~~go
	Done  bool
}
~~~

~~~go
	Done  bool
}

// Describe has a value receiver: it gets a copy of the Task.
func (t Task) Describe() string {
	mark := " "
	if t.Done {
		mark = "x"
	}
	return fmt.Sprintf("%d [%s] %s", t.ID, mark, t.Title)
}

// FinishCopy changes a copy, so the caller's Task is untouched.
func (t Task) FinishCopy() {
	t.Done = true
}

// Finish has a pointer receiver: it changes the caller's Task.
func (t *Task) Finish() {
	t.Done = true
}
~~~

<!-- edit: drills/structs/main.go -->
~~~go
	p.Title = "changed through a pointer"
	fmt.Println(t.Title)
~~~

~~~go
	p.Title = "changed through a pointer"
	fmt.Println(t.Title)

	t.FinishCopy()
	fmt.Println("after FinishCopy:", t.Describe())
	t.Finish()
	fmt.Println("after Finish:    ", t.Describe())
~~~

</details>

<!-- run: go vet ./drills/structs && go run ./drills/structs | grep -qx 'after Finish:     1 \[x\] changed through a pointer' -->

~~~text
after FinishCopy: 1 [ ] changed through a pointer
after Finish:     1 [x] changed through a pointer
~~~

`FinishCopy` compiled, ran, and did nothing you can see: it set `Done` on its own copy, which was thrown away when it returned. `Finish` changed `t`. Notice that you called `t.Finish()`, not `(&t).Finish()`: Go takes the address for you when a method needs a pointer.

A rule of thumb: if any method of a type needs a pointer receiver, give them all pointer receivers, so a reader never has to wonder. (The drill mixes them on purpose, to show the difference.)

## Break it

Create `drills/nilptr/main.go`:

~~~go
package main

import "fmt"

type Task struct {
	ID    int
	Title string
}

func main() {
	var p *Task // a pointer to nothing yet
	fmt.Println(p == nil)
	fmt.Println(p.Title)
}
~~~

~~~bash
go run ./drills/nilptr
~~~

~~~text
true
panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x1 addr=0x8 pc=0x499e91]

goroutine 1 [running]:
main.main()
	/home/ada/blueprint/gofromzero/drills/nilptr/main.go:13 +0x51
exit status 2
~~~

A pointer's zero value is `nil`: it points to nothing. Following it ("dereferencing") asks the CPU to read address 0x8 (the `Title` field sits 8 bytes in, after `ID`, counted from address 0). The kernel answers with a **segmentation violation** signal, `SIGSEGV` (signals were in Foundations 02), and Go's runtime turns it into this panic. Check `if p == nil` before using a pointer that might not be set. Delete it after: `rm -r drills/nilptr`.

## Check it

~~~bash
gofmt -l . && go vet ./... && go run ./drills/structs
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... -->

That proves you can predict whether a function changes your value or a copy. It doesn't tell you where Go stores values (on the stack or the heap), which matters for speed: Core 01 looks at that with Go's escape analysis.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| A method "does nothing" | It has a value receiver and changes the copy | Use a pointer receiver: `func (t *Task)` |
| `p.Title undefined (type **Task has no field or method Title)` | A pointer to a pointer | Use `&t` once; don't take the address of a pointer |
| `nil pointer dereference` | Following a pointer that was never set | Check `p != nil`, or make sure it's set first |
| `unknown field Name in struct literal` | A typo, or a field that doesn't exist | Check the field names in the `type` declaration |
| `cannot refer to unexported field` | Using a lower-case field from another package | Capitalise it if other packages need it |
