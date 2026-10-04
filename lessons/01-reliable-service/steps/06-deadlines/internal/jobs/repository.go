package jobs

import (
	"context"
	"errors"
)

var (
	ErrNotFound = errors.New("job not found")
	ErrConflict = errors.New("job was changed by another request")
)

// Repository is the port the domain needs for storage. The domain defines
// it; storage packages implement it. Phase 1 uses an in-memory store and
// Phase 3 adds PostgreSQL without changing this interface.
type Repository interface {
	// Create stores a new job, assigns its ID, and returns the stored job.
	Create(ctx context.Context, job Job) (Job, error)

	// Get returns the job with this ID, or ErrNotFound.
	Get(ctx context.Context, id ID) (Job, error)

	// Update replaces the stored job only if its current state is still
	// expected. Otherwise it returns ErrConflict and changes nothing. This
	// compare-and-swap stops two requests from both acting on the same
	// old state.
	Update(ctx context.Context, job Job, expected State) error
}
