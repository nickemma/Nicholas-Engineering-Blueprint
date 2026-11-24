# 08 Packages, files and JSON

> Module: Go from zero · Time: ~5 h · Builds on: 07

## The problem

Everything so far has lived in memory and vanished when the program ended. A to-do list that forgets your tasks is useless. Real programs read and write files, take commands and options from the command line, report failure with the right exit code, and are split into packages so the logic can be tested without the command-line parts. This lesson builds your first complete tool, `tasks`, with all of that.

## The mental model

~~~text
 gofromzero/
   tasks/            package tasks: the logic, no printing, fully tested
     tasks.go          Task, Add, Complete, Load, Save
     tasks_test.go
   cmd/tasks/        package main: the command line
     main.go           reads the arguments, calls package tasks, prints, picks the exit code

 tasks.json  ◀── Save writes JSON ──── []Task ──── Load reads JSON ──▶
~~~

Logic in a package, input and output in a thin `main`. The package can be tested on its own and reused; `main` stays so small that there's little to get wrong.

## The pattern

**Save by writing a new file and renaming it.** You saw in Foundations 02 that a rename is a single, all-or-nothing operation. Writing a temporary file and renaming it over the old one means a crash leaves either the old list or the new list, never half of one.

## Build it

### Step 1: The logic, as plain functions

Create `tasks/tasks.go`:

<!-- file: tasks/tasks.go -->
~~~go
// Package tasks keeps a list of tasks in a JSON file.
package tasks

import (
	"errors"
	"fmt"
)

// Task is one thing to do.
type Task struct {
	ID    int    `json:"id"`
	Title string `json:"title"`
	Done  bool   `json:"done"`
}

// ErrNotFound means no task has the ID asked for.
var ErrNotFound = errors.New("no such task")

// Add appends a new task, numbered one more than the highest ID so far.
func Add(list []Task, title string) ([]Task, Task) {
	next := 1
	for _, t := range list {
		if t.ID >= next {
			next = t.ID + 1
		}
	}
	t := Task{ID: next, Title: title}
	return append(list, t), t
}

// Complete marks the task with this ID as done and returns it.
func Complete(list []Task, id int) (Task, error) {
	for i := range list {
		if list[i].ID == id {
			list[i].Done = true
			return list[i], nil
		}
	}
	return Task{}, fmt.Errorf("task %d: %w", id, ErrNotFound)
}
~~~

- The text in backquotes after each field, `` `json:"id"` ``, is a **struct tag**. The `encoding/json` package (step 2) reads it to name the field `id` in the file, instead of `ID`.
- `Add` returns the new slice, because `append` may have moved it to a new array (lesson 04), and the new task, so the caller can print its number.
- `Complete` loops with `for i := range list` and changes `list[i]`, the element itself. `for _, t := range list` would hand it a copy of each task, and changing that copy would do nothing (lesson 05).

Test it. Create `tasks/tasks_test.go`:

<!-- file: tasks/tasks_test.go -->
~~~go
package tasks

import (
	"errors"
	"testing"
)

func TestAddNumbersFromTheHighestID(t *testing.T) {
	tests := []struct {
		name string
		list []Task
		want int
	}{
		{"empty list", nil, 1},
		{"one task", []Task{{ID: 1}}, 2},
		{"a gap after deletion", []Task{{ID: 1}, {ID: 5}}, 6},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, got := Add(tt.list, "x")
			if got.ID != tt.want {
				t.Errorf("Add gave ID %d, want %d", got.ID, tt.want)
			}
		})
	}
}

func TestCompleteMarksTheTask(t *testing.T) {
	list := []Task{{ID: 1, Title: "a"}, {ID: 2, Title: "b"}}
	got, err := Complete(list, 2)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Done || !list[1].Done || list[0].Done {
		t.Errorf("after Complete(2): %+v", list)
	}
}

func TestCompleteUnknownID(t *testing.T) {
	_, err := Complete([]Task{{ID: 1}}, 9)
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("err = %v, want ErrNotFound", err)
	}
}
~~~

<!-- run: gofmt -l tasks | (! grep .) && go vet ./tasks && go test -count=1 ./tasks -->

~~~bash
go test ./tasks
~~~

`t.Fatal(err)` fails the test and stops it at once: there's no point checking the task if `Complete` failed. The middle test checks that `list[1]` changed, and that `list[0]` didn't.

### Step 2: Saving and loading JSON

**JSON** is the text format most programs use to exchange data: `{"id": 1, "title": "write the gate", "done": true}`. `encoding/json` turns Go values into JSON (**marshalling**) and back (**unmarshalling**). Add the packages you'll need:

<!-- edit: tasks/tasks.go -->
~~~go
import (
	"errors"
	"fmt"
)
~~~

~~~go
import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)
~~~

**Starter.** After `ErrNotFound`, write two functions:

- `Load(path string) ([]Task, error)` reads the file and unmarshals it. A file that doesn't exist yet isn't an error: it's an empty list.
- `Save(path string, list []Task) error` marshals the list and writes it **safely**: into a new temporary file in the same folder, then renamed over `path`.

<details>
<summary>Hint</summary>

`os.ReadFile(path)` returns the whole file; `errors.Is(err, os.ErrNotExist)` spots a missing one. `json.Unmarshal(data, &list)` fills `list` (pass a pointer, so it can). For saving: `json.MarshalIndent(list, "", "  ")`, then `os.CreateTemp(filepath.Dir(path), ".tasks-*.json")`, write, close, and `os.Rename(tmp.Name(), path)`. If anything fails before the rename, remove the temporary file.

</details>

<details>
<summary>The answer</summary>

<!-- edit: tasks/tasks.go -->
~~~go
var ErrNotFound = errors.New("no such task")
~~~

~~~go
var ErrNotFound = errors.New("no such task")

// Load reads the tasks saved in path. A file that doesn't exist yet is an empty list.
func Load(path string) ([]Task, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var list []Task
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	return list, nil
}

// Save writes the tasks to path. It writes a temporary file and renames it over
// the old one, so a crash part-way through never leaves a half-written list.
func Save(path string, list []Task) error {
	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tasks-*.json")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), path)
}
~~~

</details>

- `os.CreateTemp` makes a new file with a unique name (the `*` is replaced by random characters) in the same folder as `path`. It must be the same folder: a rename can only be all-or-nothing within one file system.
- `tmp.Close()` matters: data you've written may still be in memory until the file is closed, and closing reports any final write error.

Test the round trip, and the missing file. Add `path/filepath` to the test's imports:

<!-- edit: tasks/tasks_test.go -->
~~~go
import (
	"errors"
	"testing"
)
~~~

~~~go
import (
	"errors"
	"path/filepath"
	"testing"
)
~~~

<!-- append: tasks/tasks_test.go -->
~~~go
func TestSaveThenLoad(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tasks.json")
	want := []Task{{ID: 1, Title: "write it", Done: true}, {ID: 2, Title: "test it"}}
	if err := Save(path, want); err != nil {
		t.Fatal(err)
	}
	got, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("Load = %+v, want %+v", got, want)
	}
}

func TestLoadMissingFileIsEmpty(t *testing.T) {
	got, err := Load(filepath.Join(t.TempDir(), "none.json"))
	if err != nil || len(got) != 0 {
		t.Errorf("Load = %v, %v; want an empty list and no error", got, err)
	}
}
~~~

<!-- run: gofmt -l tasks | (! grep .) && go vet ./tasks && go test -count=1 ./tasks -->

`t.TempDir()` gives each test a fresh, empty folder, deleted afterwards, so tests never touch your real files or each other's.

~~~bash
go test -v ./tasks
~~~

~~~text
=== RUN   TestAddNumbersFromTheHighestID
=== RUN   TestAddNumbersFromTheHighestID/empty_list
=== RUN   TestAddNumbersFromTheHighestID/one_task
=== RUN   TestAddNumbersFromTheHighestID/a_gap_after_deletion
--- PASS: TestAddNumbersFromTheHighestID (0.00s)
    --- PASS: TestAddNumbersFromTheHighestID/empty_list (0.00s)
    --- PASS: TestAddNumbersFromTheHighestID/one_task (0.00s)
    --- PASS: TestAddNumbersFromTheHighestID/a_gap_after_deletion (0.00s)
=== RUN   TestCompleteMarksTheTask
--- PASS: TestCompleteMarksTheTask (0.00s)
=== RUN   TestCompleteUnknownID
--- PASS: TestCompleteUnknownID (0.00s)
=== RUN   TestSaveThenLoad
--- PASS: TestSaveThenLoad (0.00s)
=== RUN   TestLoadMissingFileIsEmpty
--- PASS: TestLoadMissingFileIsEmpty (0.00s)
PASS
ok  	gofromzero/tasks	0.006s
~~~

### Step 3: The command

The command reads its arguments, calls the package, prints, and chooses the exit code: 0 for success, 1 when the work failed (an unknown task), 2 when the command was used wrongly, the same conventions you met in Foundations 02.

**Starter.** Create `cmd/tasks/main.go`. `run(args []string) int` does the work and returns the exit code, so `main` is a single line. It supports `add TITLE`, `list` and `done ID`, and a `-file PATH` flag, defaulting to `tasks.json`. Messages for the person go to standard error. Output must match exactly:

~~~text
added 1: write the gate
1 [x] write the gate
2 [ ] test it both ways
done 1: write the gate
no tasks
~~~

<details>
<summary>Hint</summary>

`flag.NewFlagSet("tasks", flag.ContinueOnError)` makes a parser whose `Parse(args)` returns an error instead of exiting; `fs.String("file", "tasks.json", "...")` defines the flag and returns a pointer to its value, and `fs.Args()` gives what's left after the flags. `switch args[0]` picks the command. `strconv.Atoi` turns the ID into a number (lesson 03). `fmt.Fprintln(os.Stderr, ...)` prints to standard error.

</details>

<details>
<summary>The answer</summary>

<!-- file: cmd/tasks/main.go -->
~~~go
// Command tasks keeps a to-do list in a JSON file.
//
//	tasks [-file PATH] add TITLE
//	tasks [-file PATH] list
//	tasks [-file PATH] done ID
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"

	"gofromzero/tasks"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

// run does the work and returns the exit code: 0 success, 1 failure, 2 wrong usage.
func run(args []string) int {
	flags := flag.NewFlagSet("tasks", flag.ContinueOnError)
	file := flags.String("file", "tasks.json", "where the tasks are kept")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	args = flags.Args()
	if len(args) == 0 {
		return usage()
	}

	list, err := tasks.Load(*file)
	if err != nil {
		fmt.Fprintln(os.Stderr, "tasks:", err)
		return 1
	}

	switch args[0] {
	case "add":
		if len(args) != 2 {
			return usage()
		}
		var t tasks.Task
		list, t = tasks.Add(list, args[1])
		if err := tasks.Save(*file, list); err != nil {
			fmt.Fprintln(os.Stderr, "tasks:", err)
			return 1
		}
		fmt.Printf("added %d: %s\n", t.ID, t.Title)
	case "list":
		if len(list) == 0 {
			fmt.Println("no tasks")
		}
		for _, t := range list {
			mark := " "
			if t.Done {
				mark = "x"
			}
			fmt.Printf("%d [%s] %s\n", t.ID, mark, t.Title)
		}
	case "done":
		if len(args) != 2 {
			return usage()
		}
		id, err := strconv.Atoi(args[1])
		if err != nil {
			fmt.Fprintf(os.Stderr, "tasks: %q isn't a task number\n", args[1])
			return 2
		}
		t, err := tasks.Complete(list, id)
		if errors.Is(err, tasks.ErrNotFound) {
			fmt.Fprintf(os.Stderr, "tasks: no task %d\n", id)
			return 1
		}
		if err := tasks.Save(*file, list); err != nil {
			fmt.Fprintln(os.Stderr, "tasks:", err)
			return 1
		}
		fmt.Printf("done %d: %s\n", t.ID, t.Title)
	default:
		return usage()
	}
	return 0
}

func usage() int {
	fmt.Fprintln(os.Stderr, "usage: tasks [-file PATH] add TITLE | list | done ID")
	return 2
}
~~~

</details>

- `import "gofromzero/tasks"` brings in your own package by its module path. Its exported names are used with the package name in front: `tasks.Load`, `tasks.ErrNotFound`.
- `os.Args` holds the program's command-line words; `os.Args[1:]` skips the first, the program's own name.
- `os.Exit(code)` ends the program with that exit code. Keeping it in `main` and putting everything else in `run` means `run` could be tested too.

### Step 4: Using it

Build it into a folder of its own, and try a session:

~~~bash
mkdir -p ~/try && go build -o ~/try/tasks ./cmd/tasks && cd ~/try
./tasks list && ./tasks add "write the gate" && ./tasks add "test it both ways" && ./tasks done 1 && ./tasks list && cat tasks.json
~~~

<!-- run: go build -o tasksbin ./cmd/tasks && mkdir -p try && cd try && [ "$(../tasksbin list)" = "no tasks" ] && ../tasksbin add "write the gate" >/dev/null && ../tasksbin add "test it both ways" >/dev/null && [ "$(../tasksbin done 1)" = "done 1: write the gate" ] && [ "$(../tasksbin list)" = "$(printf '1 [x] write the gate\n2 [ ] test it both ways')" ] && cd .. && rm -r try tasksbin -->

~~~text
no tasks
added 1: write the gate
added 2: test it both ways
done 1: write the gate
1 [x] write the gate
2 [ ] test it both ways
[
  {
    "id": 1,
    "title": "write the gate",
    "done": true
  },
  {
    "id": 2,
    "title": "test it both ways",
    "done": false
  }
]
~~~

Each `./tasks` is a separate process: the list survived between them because it's in `tasks.json`, with the names from the struct tags.

Now the failures, each with its exit code:

~~~bash
./tasks done 9; echo "exit status: $?"
./tasks done abc; echo "exit status: $?"
./tasks; echo "exit status: $?"
~~~

~~~text
tasks: no task 9
exit status: 1
tasks: "abc" isn't a task number
exit status: 2
usage: tasks [-file PATH] add TITLE | list | done ID
exit status: 2
~~~

And a second list, in another file:

~~~bash
./tasks -file other.json add "elsewhere" && ./tasks -file other.json list && ./tasks list
~~~

~~~text
added 1: elsewhere
1 [ ] elsewhere
1 [x] write the gate
2 [ ] test it both ways
~~~

Go back to your module afterwards: `cd ~/blueprint/gofromzero`.

## Break it

Give it a file that isn't valid JSON:

~~~bash
cd ~/try && echo "{" > broken.json && ./tasks -file broken.json list; echo "exit status: $?"
~~~

~~~text
tasks: reading broken.json: unexpected end of JSON input
exit status: 1
~~~

It refuses, says which file and why, and exits with 1, instead of treating a damaged list as an empty one and then overwriting it with a fresh one on the next `add`. That would lose every task. Failing loudly here protects the data.

## Check it

~~~bash
cd ~/blueprint/gofromzero && gofmt -l . && go vet ./... && go test ./...
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... && go test -count=1 ./... -->

That proves the logic is tested, the list survives between runs, and every failure has a message and the right exit code. It doesn't protect against two `tasks` commands running at the same moment: both could load the old list, and the second save would overwrite the first's change. Preventing that takes a lock or a database, which arrives in Core 01 and Core 03.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `package gofromzero/tasks is not in std` | The `module` line in `go.mod` isn't `gofromzero` | Import paths start with the module path from `go.mod` |
| The JSON has `"ID"` instead of `"id"` | Missing or misspelled struct tags | `` `json:"id"` ``, with backquotes |
| Fields missing from the JSON | They start with a lower-case letter | `encoding/json` only sees exported (capitalised) fields |
| `json: Unmarshal(non-pointer []tasks.Task)` | You passed the slice, not its address | `json.Unmarshal(data, &list)` |
| `done` reports success but the file doesn't change | `Complete` changed a copy | Loop with `for i := range list` and change `list[i]` |
