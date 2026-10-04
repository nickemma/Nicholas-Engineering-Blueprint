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
