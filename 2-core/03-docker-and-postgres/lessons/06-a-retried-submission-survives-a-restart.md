# 06 A retried submission survives a restart

> About 5 hours · Builds on [05 Complete a job in one transaction](05-complete-a-job-in-one-transaction.md).

## The problem

PostgreSQL commits a new job. The connection to the client drops before it gets `201 Created`. The client retries after Switchyard restarts. Core 01's in-memory keys disappeared with the old process, so Switchyard could create a second job.

## The mental model

~~~text
POST /jobs keyed A
          |
          v
BEGIN -> check A -> check capacity -> insert job -> save result for A -> COMMIT
                                                                     |
retry after restart -> look up A -> compare fingerprint -> return the saved result
~~~

Keep the original submission result because the live job may already have changed state. The fingerprint covers the method, route, and exact body bytes, as it did in Core 01.

## The pattern

Make the database commit the durable point of acceptance. Serialize submissions around the capacity check. Look for a retry first so a full queue can still replay a committed result. Workers now find queued rows in PostgreSQL, so a crash between commit and delivery to a worker leaves discoverable work.

## Build it

### Step 1. Give each key one row

The primary key prevents duplicates. Store the fingerprint, job ID, original job snapshot, and expiry with each key. The HTTP response is reconstructed from the snapshot using the same response encoder and location builder.
Create `db/migrations/004_submission_keys.sql`:

<!-- file: db/migrations/004_submission_keys.sql -->
~~~sql
CREATE TABLE submission_keys (
    key text PRIMARY KEY CHECK (octet_length(key) BETWEEN 1 AND 255),
    fingerprint bytea NOT NULL CHECK (octet_length(fingerprint) = 32),
    job_id bigint NOT NULL REFERENCES jobs (id),
    response jsonb NOT NULL,
    expires_at timestamptz NOT NULL
);

CREATE INDEX submission_keys_expiry ON submission_keys (expires_at);
CREATE INDEX jobs_unfinished_id ON jobs (id) WHERE state IN ('queued', 'running');
~~~

Edit `db/migrate.sql`:

<!-- edit: db/migrate.sql -->
~~~sql
    \ir migrations/003_job_effects.sql
    INSERT INTO schema_migrations (version) VALUES (3);
\endif
COMMIT;
~~~

~~~sql
    \ir migrations/003_job_effects.sql
    INSERT INTO schema_migrations (version) VALUES (3);
\endif
SELECT NOT EXISTS (
    SELECT 1 FROM schema_migrations WHERE version = 4
) AS apply_004 \gset
\if :apply_004
    \ir migrations/004_submission_keys.sql
    INSERT INTO schema_migrations (version) VALUES (4);
\endif
COMMIT;
~~~

Apply migration 004 with `migrate`.

<!-- run: if [[ -n "${SWITCHYARD_TEST_DATABASE_URL:-}" ]]; then psql "$SWITCHYARD_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f db/migrate.sql; fi -->

### Step 2. Admit and record a submission in one transaction

The transaction takes an advisory lock before checking capacity. Every database submission uses that same lock, including requests without keys and gRPC submissions. The queued and running rows both count toward the database backend's outstanding-work limit. A finishing or cancelled job frees a slot. Requeuing a running job leaves the count unchanged.

The lock is deliberately coarse for this lab. It gives the count and insert a simple order and makes contention measurable. Waits still use the API request context. A rollback releases the lock, removes the tentative job, and leaves no success record.
Edit `internal/pgstore/store.go`:

<!-- edit: internal/pgstore/store.go -->
~~~go
		return jobs.Job{}, err
	}
	defer conn.Release()
	return scanJob(conn.QueryRow(ctx, `
		INSERT INTO jobs (description, duration_ns, state, failure_reason, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING `+columns, job.Description, int64(job.Duration), job.State,
~~~

~~~go
		return jobs.Job{}, err
	}
	defer conn.Release()
	return insertJob(ctx, conn, job)
}

// A connection and a transaction both know how to query one row.
type rowQuerier interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func insertJob(ctx context.Context, db rowQuerier, job jobs.Job) (jobs.Job, error) {
	return scanJob(db.QueryRow(ctx, `
		INSERT INTO jobs (description, duration_ns, state, failure_reason, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		RETURNING `+columns, job.Description, int64(job.Duration), job.State,
~~~

Create `internal/pgstore/submission.go`:

<!-- file: internal/pgstore/submission.go -->
~~~go
package pgstore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"switchyard/internal/jobs"
)

type Submitter struct {
	store    *Store
	capacity int
	ttl      time.Duration
}

func NewSubmitter(store *Store, capacity int, ttl time.Duration) *Submitter {
	return &Submitter{store: store, capacity: capacity, ttl: ttl}
}

func (s *Submitter) Submit(ctx context.Context, job jobs.Job, key string, fingerprint [32]byte) (jobs.Job, bool, error) {
	conn, err := s.store.acquire(ctx)
	if err != nil {
		return jobs.Job{}, false, err
	}
	defer conn.Release()

	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return jobs.Job{}, false, err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), time.Second)
		defer cancel()
		_ = tx.Rollback(cleanup)
	}()

	// All submissions take this lock so the count and insert can't race.
	// Transaction locks release on commit or rollback.
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(30302)"); err != nil {
		return jobs.Job{}, false, err
	}
	if key != "" {
		if _, err := tx.Exec(ctx, "DELETE FROM submission_keys WHERE key = $1 AND expires_at <= $2", key, job.CreatedAt); err != nil {
			return jobs.Job{}, false, err
		}
		var savedHash, response []byte
		err := tx.QueryRow(ctx, "SELECT fingerprint, response FROM submission_keys WHERE key = $1", key).
			Scan(&savedHash, &response)
		switch {
		case err == nil:
			if !bytes.Equal(savedHash, fingerprint[:]) {
				return jobs.Job{}, false, jobs.ErrKeyMismatch
			}
			var original jobs.Job
			if err := json.Unmarshal(response, &original); err != nil {
				return jobs.Job{}, false, err
			}
			return original, true, nil
		case !errors.Is(err, pgx.ErrNoRows):
			return jobs.Job{}, false, err
		}
	}

	var full bool
	if err := tx.QueryRow(ctx, "SELECT count(*) >= $1 FROM jobs WHERE state IN ('queued', 'running')", s.capacity).Scan(&full); err != nil {
		return jobs.Job{}, false, err
	}
	if full {
		return jobs.Job{}, false, jobs.ErrDispatchFailed
	}

	created, err := insertJob(ctx, tx, job)
	if err != nil {
		return jobs.Job{}, false, err
	}
	if key != "" {
		response, err := json.Marshal(created)
		if err != nil {
			return jobs.Job{}, false, err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO submission_keys (key, fingerprint, job_id, response, expires_at)
			VALUES ($1, $2, $3, $4, $5)`, key, fingerprint[:], created.ID, response, job.CreatedAt.Add(s.ttl)); err != nil {
			return jobs.Job{}, false, fmt.Errorf("record submission key: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return jobs.Job{}, false, fmt.Errorf("commit submission: %w", err)
	}
	return created, false, nil
}

func (s *Submitter) Sweep(ctx context.Context) (int64, error) {
	conn, err := s.store.acquire(ctx)
	if err != nil {
		return 0, err
	}
	defer conn.Release()
	tag, err := conn.Exec(ctx, "DELETE FROM submission_keys WHERE expires_at <= now()")
	return tag.RowsAffected(), err
}

func (s *Store) FirstQueued(ctx context.Context) (jobs.ID, bool, error) {
	conn, err := s.acquire(ctx)
	if err != nil {
		return 0, false, err
	}
	defer conn.Release()
	var id jobs.ID
	err = conn.QueryRow(ctx, "SELECT id FROM jobs WHERE state = 'queued' ORDER BY id LIMIT 1").Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	return id, err == nil, err
}

func (s *Store) QueuedCount(ctx context.Context) (int, error) {
	conn, err := s.acquire(ctx)
	if err != nil {
		return 0, err
	}
	defer conn.Release()
	var count int
	err = conn.QueryRow(ctx, "SELECT count(*) FROM jobs WHERE state = 'queued'").Scan(&count)
	return count, err
}
~~~

Edit `internal/jobs/service.go`:

<!-- edit: internal/jobs/service.go -->
~~~go
	CompleteWithEffect(ctx context.Context, id ID, now time.Time) (Job, error)
}

// Simulate is the default work: wait for the job's duration, or stop early
// if ctx is cancelled or its deadline passes.
func Simulate(ctx context.Context, job Job) error {
~~~

~~~go
	CompleteWithEffect(ctx context.Context, id ID, now time.Time) (Job, error)
}

// Submission commits admission and any retry key with the new job.
type Submission interface {
	Submit(ctx context.Context, job Job, key string, fingerprint [32]byte) (Job, bool, error)
}

var ErrKeyMismatch = errors.New("Idempotency-Key was already used for a different request")

// Simulate is the default work: wait for the job's duration, or stop early
// if ctx is cancelled or its deadline passes.
func Simulate(ctx context.Context, job Job) error {
~~~

<!-- edit: internal/jobs/service.go -->
~~~go
	dispatch   Dispatcher
	effects    Effects
	completion Completion
	now        func() time.Time
}
~~~

~~~go
	dispatch   Dispatcher
	effects    Effects
	completion Completion
	submission Submission
	now        func() time.Time
}
~~~

<!-- edit: internal/jobs/service.go -->
~~~go
	return func(s *Service) { s.completion = c }
}

// Create stores a queued job and dispatches it. Storing and dispatching are
// two separate steps, so they can't be made atomic here: if dispatch fails,
// Create marks the stored job failed. If the process crashes between the two
// steps, the job stays queued forever. The transactional outbox (the Event
// streams unit) removes that gap.
func (s *Service) Create(ctx context.Context, description string, duration time.Duration) (Job, error) {
	d, err := NewDescription(description)
	if err != nil {
		return Job{}, err
	}
	job, err := New(d, duration, s.now())
	if err != nil {
		return Job{}, err
	}
	job, err = s.repo.Create(ctx, job)
	if err != nil || s.dispatch == nil {
~~~

~~~go
	return func(s *Service) { s.completion = c }
}

// WithSubmission selects a durable admission and submission backend.
func WithSubmission(s Submission) Option {
	return func(svc *Service) { svc.submission = s }
}

func (s *Service) SubmitKeyed(ctx context.Context, description string, duration time.Duration, key string, fingerprint [32]byte) (Job, bool, error) {
	job, err := s.newJob(description, duration)
	if err != nil {
		return Job{}, false, err
	}
	return s.submission.Submit(ctx, job, key, fingerprint)
}

func (s *Service) newJob(description string, duration time.Duration) (Job, error) {
	d, err := NewDescription(description)
	if err != nil {
		return Job{}, err
	}
	return New(d, duration, s.now())
}

// Create stores a queued job and dispatches it. Storing and dispatching are
// two separate steps, so they can't be made atomic here: if dispatch fails,
// Create marks the stored job failed. If the process crashes between the two
// steps, the job stays queued forever. The transactional outbox (the Event
// streams unit) removes that gap.
func (s *Service) Create(ctx context.Context, description string, duration time.Duration) (Job, error) {
	job, err := s.newJob(description, duration)
	if err != nil {
		return Job{}, err
	}
	if s.submission != nil {
		stored, _, err := s.submission.Submit(ctx, job, "", [32]byte{})
		return stored, err
	}
	job, err = s.repo.Create(ctx, job)
	if err != nil || s.dispatch == nil {
~~~

### Step 3. Carry the HTTP key to the transaction

Share the bounded body read and fingerprint with the memory middleware. In PostgreSQL mode the handler supplies the key directly to the submission use case. A same-key request with different valid input returns HTTP 422. A replay returns the original 201 and Location and adds `Idempotent-Replayed: true`.
Edit `internal/idempotency/idempotency.go`:

<!-- edit: internal/idempotency/idempotency.go -->
~~~go
			next.ServeHTTP(w, r)
			return
		}
		if len(key) > maxKeyLength {
			writeError(w, http.StatusBadRequest, fmt.Sprintf("%s must be at most %d characters", HeaderKey, maxKeyLength))
			return
		}

		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
		if err != nil {
			writeError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("request body must not exceed %d bytes", maxBodyBytes))
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))

		cached, err := store.Begin(key, fingerprint(r, body))
		switch {
		case errors.Is(err, ErrMismatch):
			writeError(w, http.StatusUnprocessableEntity, err.Error())
~~~

~~~go
			next.ServeHTTP(w, r)
			return
		}
		sum, ok := ReadKey(w, r, key, maxBodyBytes)
		if !ok {
			return
		}

		cached, err := store.Begin(key, sum)
		switch {
		case errors.Is(err, ErrMismatch):
			writeError(w, http.StatusUnprocessableEntity, err.Error())
~~~

<!-- edit: internal/idempotency/idempotency.go -->
~~~go
			})
		}
	})
}

func fingerprint(r *http.Request, body []byte) [32]byte {
~~~

~~~go
			})
		}
	})
}

// ReadKey validates the key, hashes the bounded request, and restores its body for decoding.
func ReadKey(w http.ResponseWriter, r *http.Request, key string, maxBodyBytes int64) ([32]byte, bool) {
	if len(key) > maxKeyLength {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("%s must be at most %d bytes", HeaderKey, maxKeyLength))
		return [32]byte{}, false
	}

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("request body must not exceed %d bytes", maxBodyBytes))
		return [32]byte{}, false
	}
	r.Body = io.NopCloser(bytes.NewReader(body))
	return fingerprint(r, body), true
}

func fingerprint(r *http.Request, body []byte) [32]byte {
~~~

Edit `internal/httpapi/handler.go`:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	CountEffects(ctx context.Context, job jobs.ID) (int, error)
}

type handlers struct {
	jobs    JobService
	effects EffectCounter
	logger  *slog.Logger
}

type config struct {
	logger         *slog.Logger
	metrics        *Metrics
	requestTimeout time.Duration
~~~

~~~go
	CountEffects(ctx context.Context, job jobs.ID) (int, error)
}

type KeyedSubmitter interface {
	SubmitKeyed(ctx context.Context, description string, duration time.Duration, key string, fingerprint [32]byte) (jobs.Job, bool, error)
}

type handlers struct {
	keyed   KeyedSubmitter
	jobs    JobService
	effects EffectCounter
	logger  *slog.Logger
}

type config struct {
	keyed          KeyedSubmitter
	logger         *slog.Logger
	metrics        *Metrics
	requestTimeout time.Duration
~~~

<!-- edit: internal/httpapi/handler.go -->
~~~go
// WithIdempotency honours Idempotency-Key on POST /jobs, using store.
func WithIdempotency(store *idempotency.Store) Option {
	return func(c *config) { c.idempotency = store }
}

// WithEffects serves GET /effects/{id}, so a check can count each job's
~~~

~~~go
// WithIdempotency honours Idempotency-Key on POST /jobs, using store.
func WithIdempotency(store *idempotency.Store) Option {
	return func(c *config) { c.idempotency = store }
}

func WithDurableIdempotency(submitter KeyedSubmitter) Option {
	return func(c *config) { c.keyed = submitter }
}

// WithEffects serves GET /effects/{id}, so a check can count each job's
~~~

<!-- edit: internal/httpapi/handler.go -->
~~~go
	for _, opt := range opts {
		opt(&cfg)
	}
	h := &handlers{jobs: service, effects: cfg.effects, logger: cfg.logger}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", h.health)
	mux.HandleFunc("GET /greet", h.greet)
	var create http.Handler = http.HandlerFunc(h.createJob)
	if cfg.idempotency != nil {
		create = idempotency.Middleware(cfg.idempotency, maxBodyBytes, create)
	}
	mux.Handle("POST /jobs", create)
~~~

~~~go
	for _, opt := range opts {
		opt(&cfg)
	}
	h := &handlers{jobs: service, effects: cfg.effects, logger: cfg.logger, keyed: cfg.keyed}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", h.health)
	mux.HandleFunc("GET /greet", h.greet)
	var create http.Handler = http.HandlerFunc(h.createJob)
	if cfg.idempotency != nil && cfg.keyed == nil {
		create = idempotency.Middleware(cfg.idempotency, maxBodyBytes, create)
	}
	mux.Handle("POST /jobs", create)
~~~

<!-- edit: internal/httpapi/handler.go -->
~~~go
}

func (h *handlers) createJob(w http.ResponseWriter, r *http.Request) {
	var req createJobRequest
	if err := decodeJSON(w, r, &req); err != nil {
		h.writeRequestError(w, err)
		return
	}

	job, err := h.jobs.Create(r.Context(), req.Description, time.Duration(req.DurationMS)*time.Millisecond)
	if errors.Is(err, jobs.ErrDispatchFailed) {
		// Overloaded: tell the caller to come back, rather than queueing
		// without limit. The job is recorded as failed.
~~~

~~~go
}

func (h *handlers) createJob(w http.ResponseWriter, r *http.Request) {
	var key string
	var sum [32]byte
	if h.keyed != nil {
		key = r.Header.Get(idempotency.HeaderKey)
	}
	if key != "" {
		var ok bool
		sum, ok = idempotency.ReadKey(w, r, key, maxBodyBytes)
		if !ok {
			return
		}
	}

	var req createJobRequest
	if err := decodeJSON(w, r, &req); err != nil {
		h.writeRequestError(w, err)
		return
	}

	duration := time.Duration(req.DurationMS) * time.Millisecond
	var job jobs.Job
	var err error
	if key == "" {
		job, err = h.jobs.Create(r.Context(), req.Description, duration)
	} else {
		var replayed bool
		job, replayed, err = h.keyed.SubmitKeyed(r.Context(), req.Description, duration, key, sum)
		if replayed {
			w.Header().Set(idempotency.HeaderReplayed, "true")
		}
	}
	if errors.Is(err, jobs.ErrKeyMismatch) {
		writeError(w, http.StatusUnprocessableEntity, err.Error())
		return
	}
	if errors.Is(err, jobs.ErrDispatchFailed) {
		// Overloaded: tell the caller to come back, rather than queueing
		// without limit. The job is recorded as failed.
~~~

### Step 4. Let workers find committed rows

In database mode, the coordinator polls the oldest queued ID. Workers can read the same ID, so the existing expected-state update still decides which worker starts it. In this lesson the lease registry stays in memory. Lesson 07 handles a process that dies after a worker starts a job.
Edit `internal/coord/coord.go`:

<!-- edit: internal/coord/coord.go -->
~~~go
	HandedBack int
}

type Coordinator struct {
	jobs    Jobs
	pending <-chan jobs.ID
	ttl     time.Duration
~~~

~~~go
	HandedBack int
}

// QueuedJobs finds the first durable job available to try.
type QueuedJobs interface {
	FirstQueued(ctx context.Context) (jobs.ID, bool, error)
}

type Coordinator struct {
	queued  QueuedJobs
	jobs    Jobs
	pending <-chan jobs.ID
	ttl     time.Duration
~~~

<!-- edit: internal/coord/coord.go -->
~~~go
	}
}

// Register adds a worker and gives it an ID.
func (c *Coordinator) Register(name string) Registration {
	c.mu.Lock()
~~~

~~~go
	}
}

// UseDurableQueue selects durable discovery before workers start.
func (c *Coordinator) UseDurableQueue(queue QueuedJobs) {
	c.queued = queue
}

// Register adds a worker and gives it an ID.
func (c *Coordinator) Register(name string) Registration {
	c.mu.Lock()
~~~

<!-- edit: internal/coord/coord.go -->
~~~go
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	for {
		id, ok := c.takeHandedBack()
		if !ok {
			select {
			case id = <-c.pending:
			case <-c.wake:
				continue
			case <-timer.C:
~~~

~~~go
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	var poll <-chan time.Time
	if c.queued != nil {
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()
		poll = ticker.C
	}
	for {
		id, ok := c.takeHandedBack()
		if !ok && c.queued != nil {
			var err error
			query, cancel := context.WithTimeout(ctx, c.ttl)
			id, ok, err = c.queued.FirstQueued(query)
			cancel()
			if err != nil {
				return Lease{}, false, err
			}
		}
		if !ok {
			select {
			case id = <-c.pending:
			case <-poll:
				continue
			case <-c.wake:
				continue
			case <-timer.C:
~~~

<!-- edit: internal/coord/coord.go -->
~~~go
				return Lease{}, false, ctx.Err()
			}
		}
		job, err := c.jobs.Start(context.WithoutCancel(ctx), id)
		if err != nil {
			// Cancelled while it waited: there's nothing to run.
			continue
		}
		c.mu.Lock()
		c.tokenSeq++
~~~

~~~go
				return Lease{}, false, ctx.Err()
			}
		}
		start, cancel := context.WithTimeout(context.WithoutCancel(ctx), c.ttl)
		job, err := c.jobs.Start(start, id)
		cancel()
		if errors.Is(err, jobs.ErrInvalidTransition) || errors.Is(err, jobs.ErrNotFound) {
			continue // a cancellation or another worker already won
		}
		if err != nil {
			return Lease{}, false, err
		}
		c.mu.Lock()
		c.tokenSeq++
~~~

Edit `internal/grpcapi/workers.go`:

<!-- edit: internal/grpcapi/workers.go -->
~~~go
// tells a worker "don't retry this": the job isn't yours to finish.
func workerStatus(err error) error {
	switch {
	case errors.Is(err, coord.ErrUnknownWorker):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, coord.ErrLeaseLost), errors.Is(err, jobs.ErrInvalidTransition):
~~~

~~~go
// tells a worker "don't retry this": the job isn't yours to finish.
func workerStatus(err error) error {
	switch {
	case errors.Is(err, jobs.ErrStoreBusy):
		return status.Error(codes.Unavailable, "job storage is busy")
	case errors.Is(err, coord.ErrUnknownWorker):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, coord.ErrLeaseLost), errors.Is(err, jobs.ErrInvalidTransition):
~~~

Edit `cmd/switchyard/main.go`:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
~~~

~~~go
	"fmt"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"os"
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
	var repo jobs.Repository
	var pool *pgxpool.Pool
	var completion jobs.Completion
	effects := ledger.New()
	var effectCounter httpapi.EffectCounter = effects
	if cfg.DatabaseURL == "" {
~~~

~~~go
	var repo jobs.Repository
	var pool *pgxpool.Pool
	var completion jobs.Completion
	var store *pgstore.Store
	var submitter *pgstore.Submitter
	effects := ledger.New()
	var effectCounter httpapi.EffectCounter = effects
	if cfg.DatabaseURL == "" {
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
			return err
		}
		defer pool.Close()
		store := pgstore.New(pool, cfg.DatabaseAcquireTimeout)
		repo, completion, effectCounter = store, store, store
	}
	pending := queue.New(cfg.QueueCapacity)
	service := jobs.NewService(repo, jobs.WithDispatcher(pending),
		jobs.WithEffects(effects), jobs.WithCompletion(completion))
	coordinator := coord.New(service, pending.Next(), cfg.LeaseTTL, time.Now, logger)
	keys := idempotency.NewStore(cfg.IdempotencyTTL, time.Now)

	metrics := httpapi.NewMetrics()
	gauge := func(name, help string, value func() float64) prometheus.Collector {
~~~

~~~go
			return err
		}
		defer pool.Close()
		store = pgstore.New(pool, cfg.DatabaseAcquireTimeout)
		submitter = pgstore.NewSubmitter(store, cfg.QueueCapacity, cfg.IdempotencyTTL)
		repo, completion, effectCounter = store, store, store
	}
	pending := queue.New(cfg.QueueCapacity)
	options := []jobs.Option{jobs.WithDispatcher(pending), jobs.WithEffects(effects), jobs.WithCompletion(completion)}
	if submitter != nil {
		options = append(options, jobs.WithSubmission(submitter))
	}
	service := jobs.NewService(repo, options...)
	coordinator := coord.New(service, pending.Next(), cfg.LeaseTTL, time.Now, logger)
	keys := idempotency.NewStore(cfg.IdempotencyTTL, time.Now)
	keyOption := httpapi.WithIdempotency(keys)
	if store != nil {
		coordinator.UseDurableQueue(store)
		keyOption = httpapi.WithDurableIdempotency(service)
	}
	queueDepth := func() float64 {
		if store == nil {
			return float64(pending.Len())
		}
		query, cancel := context.WithTimeout(ctx, cfg.RequestTimeout)
		defer cancel()
		n, err := store.QueuedCount(query)
		if err != nil {
			return math.NaN()
		}
		return float64(n)
	}

	metrics := httpapi.NewMetrics()
	gauge := func(name, help string, value func() float64) prometheus.Collector {
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
	}
	metrics.MustRegister(
		collectors.NewGoCollector(), // go_goroutines, go_memstats_*, ...
		gauge("jobs_queue_depth", "Jobs waiting for a worker.", func() float64 { return float64(pending.Len()) }),
		gauge("idempotency_keys", "Idempotency keys currently remembered.", func() float64 { return float64(keys.Len()) }),
		gauge("workers", "Workers that have called in within the lease TTL.", func() float64 { return float64(coordinator.Stats().Workers) }),
		gauge("leases", "Jobs held by a worker right now.", func() float64 { return float64(coordinator.Stats().Leases) }),
		prometheus.NewCounterFunc(prometheus.CounterOpts{
~~~

~~~go
	}
	metrics.MustRegister(
		collectors.NewGoCollector(), // go_goroutines, go_memstats_*, ...
		gauge("jobs_queue_depth", "Jobs waiting for a worker.", queueDepth),
		gauge("workers", "Workers that have called in within the lease TTL.", func() float64 { return float64(coordinator.Stats().Workers) }),
		gauge("leases", "Jobs held by a worker right now.", func() float64 { return float64(coordinator.Stats().Leases) }),
		prometheus.NewCounterFunc(prometheus.CounterOpts{
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
		}, func() float64 { return float64(coordinator.Stats().HandedBack) }),
	)
	if pool == nil {
		metrics.MustRegister(prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "effects_applied_total",
			Help: "Job effects recorded in the ledger.",
~~~

~~~go
		}, func() float64 { return float64(coordinator.Stats().HandedBack) }),
	)
	if pool == nil {
		metrics.MustRegister(gauge("idempotency_keys", "Idempotency keys currently remembered.", func() float64 {
			return float64(keys.Len())
		}))
		metrics.MustRegister(prometheus.NewCounterFunc(prometheus.CounterOpts{
			Name: "effects_applied_total",
			Help: "Job effects recorded in the ledger.",
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
		httpapi.WithIdempotency(keys),
		httpapi.WithEffects(effectCounter),
	)
	server := &http.Server{
~~~

~~~go
		httpapi.WithLogger(logger),
		httpapi.WithMetrics(metrics),
		httpapi.WithRequestTimeout(cfg.RequestTimeout),
		keyOption,
		httpapi.WithEffects(effectCounter),
	)
	server := &http.Server{
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
			case <-loops.Done():
				return
			case <-ticker.C:
				if removed := keys.Sweep(); removed > 0 {
					logger.Info("swept idempotency keys", "removed", removed)
				}
			}
		}
~~~

~~~go
			case <-loops.Done():
				return
			case <-ticker.C:
				if submitter == nil {
					keys.Sweep()
					continue
				}
				sweep, cancel := context.WithTimeout(loops, cfg.RequestTimeout)
				_, err := submitter.Sweep(sweep)
				cancel()
				if err != nil && loops.Err() == nil {
					logger.Warn("could not sweep submission keys", "error", err)
				}
			}
		}
~~~

<!-- edit: cmd/switchyard/main.go -->
~~~go
	// 3. Stop the background loops, and wait for them.
	stopLoops()
	background.Wait()
	logger.Info("stopped", "jobs_left_in_queue", pending.Len(), "leases_held", coordinator.Stats().Leases)
	return nil
}
~~~

~~~go
	// 3. Stop the background loops, and wait for them.
	stopLoops()
	background.Wait()
	logger.Info("stopped", "jobs_left_in_queue", queueDepth(), "leases_held", coordinator.Stats().Leases)
	return nil
}
~~~

### Step 5. Race two submissions and force a rollback

The integration test races the same request twice, then cancels the job and opens a new pool. It checks the original response, refusal of a changed fingerprint, replay at capacity, and rollback when the key violates a database constraint.
Create `internal/pgstore/submission_test.go`:

<!-- file: internal/pgstore/submission_test.go -->
~~~go
package pgstore_test

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"switchyard/internal/jobs"
	"switchyard/internal/pgstore"
)

func TestDurableSubmission(t *testing.T) {
	url := os.Getenv("SWITCHYARD_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set SWITCHYARD_TEST_DATABASE_URL to a migrated disposable database")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	open := func() *pgxpool.Pool {
		pool, err := pgxpool.New(ctx, url)
		if err != nil {
			t.Fatal(err)
		}
		return pool
	}
	now := time.Now().UTC()
	key := fmt.Sprintf("submission-test-%d", now.UnixNano())
	request, err := jobs.New("durable submission", 0, now)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("first request"))
	pool := open()
	defer func() { pool.Close() }()
	store := pgstore.New(pool, time.Second)
	submitter := pgstore.NewSubmitter(store, 10000, time.Hour)

	type result struct {
		job      jobs.Job
		replayed bool
		err      error
	}
	done := make(chan result, 2)
	start := make(chan struct{})
	for range 2 {
		go func() {
			<-start
			job, replayed, err := submitter.Submit(ctx, request, key, sum)
			done <- result{job, replayed, err}
		}()
	}
	close(start)
	first, second := <-done, <-done
	if first.err != nil || second.err != nil || first.job.ID != second.job.ID || first.replayed == second.replayed {
		t.Fatalf("want one creation and one replay: %+v / %+v", first, second)
	}
	t.Log("two concurrent submissions created one job")

	service := jobs.NewService(store)
	if _, err := service.Cancel(ctx, first.job.ID); err != nil {
		t.Fatal(err)
	}
	pool.Close()
	pool = open()
	// A full queue must still allow replay of an already committed result.
	submitter = pgstore.NewSubmitter(pgstore.New(pool, time.Second), 0, time.Hour)
	original, replayed, err := submitter.Submit(ctx, request, key, sum)
	if err != nil || !replayed || original.ID != first.job.ID || original.State != jobs.StateQueued {
		t.Fatalf("replay got %+v, replayed=%v, error=%v", original, replayed, err)
	}
	t.Log("a new pool replayed the original queued response after cancellation")
	if _, _, err := submitter.Submit(ctx, request, key, sha256.Sum256([]byte("different request"))); !errors.Is(err, jobs.ErrKeyMismatch) {
		t.Fatalf("changed fingerprint: got %v", err)
	}
	if _, _, err := submitter.Submit(ctx, request, key+"-full", sum); !errors.Is(err, jobs.ErrDispatchFailed) {
		t.Fatalf("full admission: got %v", err)
	}

	bad, err := jobs.NewDescription(key + "-rollback")
	if err != nil {
		t.Fatal(err)
	}
	request.Description = bad
	submitter = pgstore.NewSubmitter(pgstore.New(pool, time.Second), 10000, time.Hour)
	_, _, err = submitter.Submit(ctx, request, strings.Repeat("x", 256), sum)
	var constraint *pgconn.PgError
	if !errors.As(err, &constraint) || constraint.Code != "23514" {
		t.Fatalf("want an injected key constraint failure, got %v", err)
	}
	var count int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM jobs WHERE description = $1", bad).Scan(&count); err != nil || count != 0 {
		t.Fatalf("job leaked from failed submission: count=%d, error=%v", count, err)
	}
	t.Log("a rejected key rolled back its job insert")
}
~~~

~~~bash
go test -race -v -count=1 -run '^TestDurableSubmission$' ./internal/pgstore
~~~

~~~text
=== RUN   TestDurableSubmission
    submission_test.go:65: two concurrent submissions created one job
    submission_test.go:79: a new pool replayed the original queued response after cancellation
    submission_test.go:102: a rejected key rolled back its job insert
--- PASS: TestDurableSubmission (0.12s)
PASS
ok  	switchyard/internal/pgstore	1.155s
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->

## Check it

Start Switchyard in PostgreSQL mode and send this request. Stop the API, start it with the same database, and run the same command again:

~~~bash
curl -isS -H 'Content-Type: application/json' -H 'Idempotency-Key: resize-demo' \
  -d '{"description":"resize","duration_ms":0}' http://127.0.0.1:8080/jobs
~~~

The replay should have the same job ID and body and include the replay header. Change the description while keeping the key and check that the API returns 422.

~~~text
first request: HTTP 201, state queued
after the API was killed: HTTP 201, Idempotent-Replayed: true, same Location and body
changed payload: HTTP 422
~~~

## If it goes wrong

- If a keyed request reports a missing relation, apply migration 004 in the database used by the control plane.
- If a replay returns the current state, check that it reads the original snapshot from `submission_keys`.
- If a first request times out, retry with the same key and exact payload. The deadline can expire before or after the commit.
