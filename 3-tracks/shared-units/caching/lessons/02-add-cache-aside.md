# 02 Add cache-aside reads and invalidation

> Caching · Week 1

## The problem

Keeping the only copy of a job in Redis would make job status depend on the cache. A cached read should have a database fallback and a defined expiration.

## The mental model

~~~text
read  → Redis hit  → return cached job
      → miss/error → read PostgreSQL → try Redis SET with TTL → return job
write → commit PostgreSQL → try Redis DEL → return committed job
~~~

## The pattern

The application manages both stores. This is cache-aside. Give Redis keys a schema version and set the value and time to live together. After a database commit, invalidate the key so the next healthy read can load the new revision. An earlier read can still finish and fill an old value after deletion. A failed invalidation can also leave an old copy. The TTL limits how long an inserted copy is served. [Redis cache-aside guide](https://redis.io/docs/latest/develop/use-cases/cache-aside/go/)

## Build it

### Wrap the job store

Use a small interface around each store so you can count database reads in the tests. Give each cache operation a short deadline. On cache failures, log what failed and continue with the database result. Preserve a database error as an error.

Create `internal/cache/repository.go`.

<!-- file: internal/cache/repository.go -->
~~~go
package cache

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"switchyard/caching/internal/jobs"
)

const (
	cacheTimeout = 125 * time.Millisecond
	fillTimeout  = 1200 * time.Millisecond
)

type Origin interface {
	Load(context.Context, string) (jobs.Job, error)
	Save(context.Context, string, string) (jobs.Job, error)
}

type Cache interface {
	Get(context.Context, string) (jobs.Job, bool, error)
	Put(context.Context, jobs.Job, time.Duration) error
	Delete(context.Context, string) error
}

type Repository struct {
	origin Origin
	cache  Cache
	ttl    time.Duration
	logger *slog.Logger
}

func New(origin Origin, cache Cache, ttl time.Duration, logger *slog.Logger) *Repository {
	return &Repository{origin: origin, cache: cache, ttl: ttl, logger: logger}
}

func (r *Repository) lookup(ctx context.Context, id string) (jobs.Job, bool) {
	lookupCtx, cancel := context.WithTimeout(ctx, cacheTimeout)
	defer cancel()
	cached, hit, err := r.cache.Get(lookupCtx, id)
	if err != nil {
		r.logger.Warn("cache lookup failed", "error", err)
		return jobs.Job{}, false
	}
	return cached, hit
}

func (r *Repository) fill(ctx context.Context, id string) (jobs.Job, error) {
	job, err := r.origin.Load(ctx, id)
	if err != nil {
		return jobs.Job{}, err
	}
	writeCtx, cancel := context.WithTimeout(ctx, cacheTimeout)
	defer cancel()
	if err := r.cache.Put(writeCtx, job, r.ttl); err != nil {
		r.logger.Warn("cache fill failed", "error", err)
	}
	return job, nil
}

// Save commits the authoritative row before invalidating the cached copy.
func (r *Repository) Save(ctx context.Context, id, state string) (jobs.Job, error) {
	if !jobs.ValidID(id) || !jobs.ValidState(state) {
		return jobs.Job{}, errors.New("invalid job ID or state")
	}
	job, err := r.origin.Save(ctx, id, state)
	if err != nil {
		return jobs.Job{}, err
	}
	invalidate, cancel := context.WithTimeout(context.WithoutCancel(ctx), cacheTimeout)
	defer cancel()
	if err := r.cache.Delete(invalidate, id); err != nil {
		r.logger.Warn("job saved but cache invalidation failed", "error", err)
	}
	return job, nil
}
~~~

### Implement the sequential read path

Check the key first. If it misses, set a deadline for loading and filling the copy.

Create `internal/cache/read.go`.

<!-- file: internal/cache/read.go -->
~~~go
package cache

import (
	"context"
	"errors"

	"switchyard/caching/internal/jobs"
)

func (r *Repository) Load(ctx context.Context, id string) (jobs.Job, error) {
	if !jobs.ValidID(id) {
		return jobs.Job{}, errors.New("invalid job ID")
	}
	if cached, hit := r.lookup(ctx, id); hit {
		return cached, nil
	}
	if err := ctx.Err(); err != nil {
		return jobs.Job{}, err
	}

	fillCtx, cancel := context.WithTimeout(ctx, fillTimeout)
	defer cancel()
	return r.fill(fillCtx, id)
}
~~~

### Implement the Redis adapter

A missing key is a normal miss. Reject a malformed copy and let the wrapper load from PostgreSQL. Disable client retries so a stalled cache gets out of the request path within its own deadline.

Create `internal/cache/redis.go`.

<!-- file: internal/cache/redis.go -->
~~~go
package cache

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
	"switchyard/caching/internal/jobs"
)

type Redis struct {
	Client *redis.Client
}

func OpenRedis(url string) (*redis.Client, error) {
	opts, err := redis.ParseURL(url)
	if err != nil {
		return nil, err
	}
	opts.ContextTimeoutEnabled = true
	opts.DialTimeout = cacheTimeout
	opts.ReadTimeout = cacheTimeout
	opts.WriteTimeout = cacheTimeout
	opts.PoolTimeout = cacheTimeout
	opts.MaxRetries = -1
	return redis.NewClient(opts), nil
}

func key(id string) string { return "switchyard:job:v1:" + id }

func (r Redis) Get(ctx context.Context, id string) (jobs.Job, bool, error) {
	body, err := r.Client.Get(ctx, key(id)).Bytes()
	if errors.Is(err, redis.Nil) {
		return jobs.Job{}, false, nil
	}
	if err != nil {
		return jobs.Job{}, false, err
	}
	var job jobs.Job
	if len(body) > 1024 || json.Unmarshal(body, &job) != nil ||
		job.ID != id || job.Revision < 1 || !jobs.ValidState(job.State) {
		return jobs.Job{}, false, errors.New("invalid cached job")
	}
	return job, true, nil
}

func (r Redis) Put(ctx context.Context, job jobs.Job, ttl time.Duration) error {
	if ttl <= 0 {
		return errors.New("cache TTL must be positive")
	}
	body, err := json.Marshal(job)
	if err != nil {
		return err
	}
	return r.Client.Set(ctx, key(job.ID), body, ttl).Err()
}

func (r Redis) Delete(ctx context.Context, id string) error {
	return r.Client.Del(ctx, key(id)).Err()
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->

The live gate checks one database read across a cold read and a warm read, then checks that a write deletes the key and the next read sees revision 2. If the warm read reaches PostgreSQL, inspect the key prefix, TTL, and fill warning.
