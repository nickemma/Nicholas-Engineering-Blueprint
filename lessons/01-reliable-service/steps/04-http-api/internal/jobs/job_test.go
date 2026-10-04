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
