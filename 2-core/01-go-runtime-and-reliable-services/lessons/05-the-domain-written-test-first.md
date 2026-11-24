# 05 The domain, written test-first

> Module: Go runtime and reliable services · Time: ~5 h · Builds on: 04

## The problem

Switchyard's real work is jobs: a client submits one, it waits in a queue, a worker runs it, and it ends completed or failed. Jobs come with rules: a description must be 1 to 200 characters, a duration must be in range, and a job can go from `queued` to `running` but never from `completed` back to `running`. If those rules live in HTTP handlers, every other way in (a gRPC call in lesson 15, a worker in lesson 16) has to copy them, and copies drift. The rules belong in one place that knows nothing about HTTP or storage: the **domain**.

## The mental model

~~~mermaid
stateDiagram-v2
    [*] --> queued
    queued --> running: Start
    running --> completed: Complete
    running --> failed: Fail
~~~

A **state machine**: the states a job can be in, and the moves allowed between them. Anything not drawn is illegal. Written as **data**, a map from each state to the states it may move to, the rules fit in one table that a test can check row by row.

## The pattern

**Entities, value objects, and rules as data.** These ideas come from domain-driven design (DDD):

- An **entity** has an identity that stays the same while its data changes. Job 7 is still job 7 after it completes.
- A **value object** is defined only by its value, and is always valid. `Description` is one: the only way to get one is `NewDescription`, which validates it, so any function that receives a `Description` knows it's valid without checking again.
- Errors are values (Go from zero lesson 03): `ErrInvalidTransition` is a **sentinel** that callers test with `errors.Is`, even when it's wrapped with detail.
- Time comes in as a parameter, `now time.Time`, never from `time.Now()` inside the domain. A function that reads the clock itself can't be tested for exact timestamps.

## Build it

### Step 1: The tests, first

Write down the rules as tests before any code exists. Create `internal/jobs/job_test.go`:

<!-- file: internal/jobs/job_test.go -->
~~~go
package jobs

import (
	"errors"
	"strings"
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)

func TestNewDescription(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		want    Description
		wantErr error
	}{
		{"plain", "resize images", "resize images", nil},
		{"trims spaces", "  resize  ", "resize", nil},
		{"empty", "", "", ErrInvalidDescription},
		{"only spaces", "   ", "", ErrInvalidDescription},
		{"200 characters", strings.Repeat("a", 200), Description(strings.Repeat("a", 200)), nil},
		{"201 characters", strings.Repeat("a", 201), "", ErrInvalidDescription},
		{"counts characters, not bytes", strings.Repeat("é", 200), Description(strings.Repeat("é", 200)), nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NewDescription(tt.raw)
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("error = %v, want %v", err, tt.wantErr)
			}
			if got != tt.want {
				t.Fatalf("description = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestNewJobIsQueued(t *testing.T) {
	job, err := New("resize", time.Second, t0)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if job.State != StateQueued {
		t.Fatalf("state = %s, want %s", job.State, StateQueued)
	}
	if !job.CreatedAt.Equal(t0) || !job.UpdatedAt.Equal(t0) {
		t.Fatalf("timestamps = %v/%v, want %v", job.CreatedAt, job.UpdatedAt, t0)
	}
}

func TestNewJobRejectsBadDuration(t *testing.T) {
	for _, d := range []time.Duration{-time.Millisecond, MaxDuration + time.Millisecond} {
		if _, err := New("resize", d, t0); !errors.Is(err, ErrInvalidDuration) {
			t.Errorf("New(duration=%v) error = %v, want %v", d, err, ErrInvalidDuration)
		}
	}
}

func TestTransitions(t *testing.T) {
	tests := []struct {
		from  State
		to    State
		legal bool
	}{
		{StateQueued, StateRunning, true},
		{StateQueued, StateCompleted, false},
		{StateQueued, StateFailed, false},
		{StateRunning, StateCompleted, true},
		{StateRunning, StateFailed, true},
		{StateRunning, StateQueued, false},
		{StateCompleted, StateRunning, false},
		{StateCompleted, StateFailed, false},
		{StateFailed, StateRunning, false},
	}
	for _, tt := range tests {
		t.Run(string(tt.from)+"->"+string(tt.to), func(t *testing.T) {
			job := Job{State: tt.from}
			if got := job.CanTransitionTo(tt.to); got != tt.legal {
				t.Fatalf("CanTransitionTo = %v, want %v", got, tt.legal)
			}
		})
	}
}

func TestLifecycle(t *testing.T) {
	job, _ := New("resize", 0, t0)
	later := t0.Add(time.Minute)

	if err := job.Start(later); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := job.Complete(later); err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if job.State != StateCompleted || !job.UpdatedAt.Equal(later) {
		t.Fatalf("job = %+v, want completed at %v", job, later)
	}
	if err := job.Complete(later); !errors.Is(err, ErrInvalidTransition) {
		t.Fatalf("second Complete error = %v, want %v", err, ErrInvalidTransition)
	}
}

func TestFailRecordsReason(t *testing.T) {
	job, _ := New("resize", 0, t0)
	_ = job.Start(t0)
	if err := job.Fail("deadline exceeded", t0); err != nil {
		t.Fatalf("Fail: %v", err)
	}
	if job.State != StateFailed || job.FailureReason != "deadline exceeded" {
		t.Fatalf("job = %+v, want failed with reason", job)
	}
}
~~~

What these pin down: the trimming rule; both sides of the 200-character boundary; characters, not bytes; every legal *and* illegal transition; that a second `Complete` is refused; and that a failure records its reason. Run them:

~~~bash
go test ./internal/jobs
~~~

<!-- run: ! go test ./internal/jobs > /dev/null 2>&1 -->

~~~text
# switchyard/internal/jobs [switchyard/internal/jobs.test]
internal/jobs/job_test.go:16:11: undefined: Description
internal/jobs/job_test.go:21:21: undefined: ErrInvalidDescription
internal/jobs/job_test.go:22:30: undefined: ErrInvalidDescription
internal/jobs/job_test.go:23:48: undefined: Description
internal/jobs/job_test.go:24:52: undefined: ErrInvalidDescription
internal/jobs/job_test.go:25:63: undefined: Description
internal/jobs/job_test.go:29:16: undefined: NewDescription
internal/jobs/job_test.go:41:14: undefined: New
internal/jobs/job_test.go:45:18: undefined: StateQueued
internal/jobs/job_test.go:46:46: undefined: StateQueued
internal/jobs/job_test.go:46:46: too many errors
FAIL	switchyard/internal/jobs [build failed]
FAIL
~~~

Red: the tests describe code that doesn't exist yet, so they don't even compile.

### Step 2: The domain

Create `internal/jobs/job.go`:

<!-- file: internal/jobs/job.go -->
~~~go
// Package jobs is the domain: what a job is, which states it can be in, and
// which changes between states are allowed. It knows nothing about HTTP or
// storage.
package jobs

import (
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

// ID identifies a job. It is its own type so an ID can't be confused with
// any other integer.
type ID int64

// State is where a job is in its lifecycle.
type State string

const (
	StateQueued    State = "queued"
	StateRunning   State = "running"
	StateCompleted State = "completed"
	StateFailed    State = "failed"
)

const (
	MaxDescriptionLength = 200
	MaxDuration          = 5 * time.Second
)

var (
	ErrInvalidDescription = errors.New("description must be between 1 and 200 characters")
	ErrInvalidDuration    = errors.New("duration must be between 0 and 5s")
	ErrInvalidTransition  = errors.New("invalid state transition")
)

// Description is a value object: a string that is known to be valid,
// because the only way to make one is NewDescription.
type Description string

func NewDescription(raw string) (Description, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || utf8.RuneCountInString(trimmed) > MaxDescriptionLength {
		return "", ErrInvalidDescription
	}
	return Description(trimmed), nil
}

// Job is an entity: it has an identity that stays the same while its state
// changes.
type Job struct {
	ID            ID
	Description   Description
	Duration      time.Duration
	State         State
	FailureReason string
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// New returns a queued job. The repository assigns its ID.
func New(description Description, duration time.Duration, now time.Time) (Job, error) {
	if duration < 0 || duration > MaxDuration {
		return Job{}, ErrInvalidDuration
	}
	return Job{
		Description: description,
		Duration:    duration,
		State:       StateQueued,
		CreatedAt:   now,
		UpdatedAt:   now,
	}, nil
}

// allowed lists every legal state change. Anything not listed is refused.
var allowed = map[State][]State{
	StateQueued:  {StateRunning},
	StateRunning: {StateCompleted, StateFailed},
}

func (j Job) CanTransitionTo(next State) bool {
	for _, state := range allowed[j.State] {
		if state == next {
			return true
		}
	}
	return false
}

func (j *Job) transition(next State, now time.Time) error {
	if !j.CanTransitionTo(next) {
		return fmt.Errorf("%w: %s to %s", ErrInvalidTransition, j.State, next)
	}
	j.State = next
	j.UpdatedAt = now
	return nil
}

func (j *Job) Start(now time.Time) error {
	return j.transition(StateRunning, now)
}

func (j *Job) Complete(now time.Time) error {
	return j.transition(StateCompleted, now)
}

func (j *Job) Fail(reason string, now time.Time) error {
	if err := j.transition(StateFailed, now); err != nil {
		return err
	}
	j.FailureReason = reason
	return nil
}
~~~

- `type ID int64` and `type State string` are new types: an `ID` can't be passed by accident where another `int64` is expected, and a `State` constant can't be confused with any string.
- `allowed` is the state machine as data. `allowed[StateCompleted]` isn't in the map, so it gives an empty slice: nothing leaves `completed`. "Final states are final" falls out of the table with no special code.
- `transition` is lowercase, so only this package can call it. Callers use `Start`, `Complete` and `Fail`, which name intentions instead of raw states.
- `CanTransitionTo` has a value receiver: it only reads. `Start` and the others have pointer receivers: they change the job (Go from zero lesson 05).
- `New` takes a `Description`, not a string. Passing `"resize"` works because an untyped string constant converts to `Description`; a `string` variable wouldn't compile without `NewDescription`.

~~~bash
go test -v ./internal/jobs 2>&1 | grep -E "^(--- |ok|FAIL)|->"
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... && go test -race -count=1 ./... -->

~~~text
--- PASS: TestNewDescription (0.00s)
--- PASS: TestNewJobIsQueued (0.00s)
--- PASS: TestNewJobRejectsBadDuration (0.00s)
=== RUN   TestTransitions/queued->running
=== RUN   TestTransitions/queued->completed
=== RUN   TestTransitions/queued->failed
=== RUN   TestTransitions/running->completed
=== RUN   TestTransitions/running->failed
=== RUN   TestTransitions/running->queued
=== RUN   TestTransitions/completed->running
=== RUN   TestTransitions/completed->failed
=== RUN   TestTransitions/failed->running
--- PASS: TestTransitions (0.00s)
    --- PASS: TestTransitions/queued->running (0.00s)
    --- PASS: TestTransitions/queued->completed (0.00s)
    --- PASS: TestTransitions/queued->failed (0.00s)
    --- PASS: TestTransitions/running->completed (0.00s)
    --- PASS: TestTransitions/running->failed (0.00s)
    --- PASS: TestTransitions/running->queued (0.00s)
    --- PASS: TestTransitions/completed->running (0.00s)
    --- PASS: TestTransitions/completed->failed (0.00s)
    --- PASS: TestTransitions/failed->running (0.00s)
--- PASS: TestLifecycle (0.00s)
--- PASS: TestFailRecordsReason (0.00s)
ok  	switchyard/internal/jobs	0.006s
~~~

Green. Each subtest is named after its row, such as `TestTransitions/queued->running`, so a failure names the exact rule.

## Break it

**Change one rule.** Add `StateCompleted: {StateRunning},` to `allowed`, and predict which tests fail before you run them:

~~~bash
go test ./internal/jobs
~~~

~~~text
--- FAIL: TestTransitions (0.00s)
    --- FAIL: TestTransitions/completed->running (0.00s)
        job_test.go:81: CanTransitionTo = true, want false
FAIL
FAIL	switchyard/internal/jobs	0.004s
FAIL
~~~

One line of data changed the rules, and the table caught it by name: `completed->running`. `TestLifecycle` still passed: it walks one path and never tries that move. A test only checks the moves it makes, which is why every rule gets its own row. Take the line out.

**Count bytes.** Change `utf8.RuneCountInString(trimmed)` to `len(trimmed)`, and delete the `"unicode/utf8"` import, which is now unused (Go won't compile a file with an unused import). Run the tests:

~~~text
--- FAIL: TestNewDescription (0.00s)
    --- FAIL: TestNewDescription/counts_characters,_not_bytes (0.00s)
        job_test.go:31: error = description must be between 1 and 200 characters, want <nil>
FAIL
FAIL	switchyard/internal/jobs	0.004s
FAIL
~~~

200 `é`s are 400 bytes. Put both back.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -race ./...
~~~

Then answer: why do the domain's methods take `now` instead of calling `time.Now()`? What does a `Description` type buy you over a plain `string`? And, test-first, add a rule: a description may not contain a newline. Write the row in `TestNewDescription`, see it fail, then make it pass.

That proves the rules hold for one job at a time. It says nothing about where jobs are kept, or what happens when two requests change the same job at once: that's the next two lessons.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `undefined: Description` and similar | The tests ran before `job.go` existed | Expected in step 1: that's red |
| `cannot use desc (variable of type string) as Description` | Passing a plain string variable to `New` | Make one with `NewDescription` first |
| A transition test passes that shouldn't | The row's `legal` value is wrong, or `allowed` has an extra entry | Read the table against the diagram |
| `invalid state transition: completed to running` from your own code | Calling `Start` on a finished job | Expected: the domain refused it |
