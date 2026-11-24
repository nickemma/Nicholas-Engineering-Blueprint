# 04 Measure expiry and Redis failure

> Caching · Week 1

## The problem

A cache can look correct while quietly serving a stale key or burning most of the request deadline when it stalls. Measure both cases directly.

## The mental model

~~~text
Redis expires a copy → next read gets a later database revision
Redis stops replying → cache deadline expires → PostgreSQL still serves reads and writes
~~~

## The pattern

Read TTL from Redis and observe the key disappear. Inject a stall long enough for cache operation deadlines to fire. Check that the read goes to PostgreSQL and that the database write remains committed when invalidation fails. Treat the pauses and database read counts as lab measurements. [Redis expiration](https://redis.io/docs/latest/commands/expire/)

## Build it

### Exercise the repository from a CLI

Each command gets a deadline. Use `init` to create the job table, then use `get` and `set` to inspect a job. The concurrent check runs readers in one process.

Create `cmd/jobs/main.go`.

<!-- file: cmd/jobs/main.go -->
~~~go
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"log/slog"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"switchyard/caching/internal/cache"
	"switchyard/caching/internal/jobs"
)

func run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("choose init, get ID, or set ID STATE")
	}
	dsn := os.Getenv("CACHE_DATABASE_URL")
	if dsn == "" {
		return errors.New("CACHE_DATABASE_URL is required")
	}
	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	origin := jobs.Postgres{DB: db}
	if args[0] == "init" && len(args) == 1 {
		return origin.Init(ctx)
	}
	if !(args[0] == "get" && len(args) == 2 || args[0] == "set" && len(args) == 3) {
		return errors.New("choose init, get ID, or set ID STATE")
	}
	client, err := cache.OpenRedis(os.Getenv("CACHE_REDIS_URL"))
	if err != nil {
		return err
	}
	defer client.Close()
	repo := cache.New(origin, cache.Redis{Client: client}, 5*time.Second, slog.Default())
	var job jobs.Job
	if args[0] == "get" {
		job, err = repo.Load(ctx, args[1])
	} else {
		job, err = repo.Save(ctx, args[1], args[2])
	}
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(job)
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	if err := run(ctx, os.Args[1:]); err != nil {
		log.Fatal(err)
	}
}
~~~

### Count PostgreSQL reads and inject a Redis stall

Wrap the real PostgreSQL adapter with the same read counter from lesson 03. Check PTTL before waiting for expiry. For the stall, issue `CLIENT PAUSE` from a separate test connection and check that the cache path logs its timeouts.

Create `internal/cache/live_test.go`.

<!-- file: internal/cache/live_test.go -->
~~~go
package cache

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"switchyard/caching/internal/jobs"
)

func TestLive(t *testing.T) {
	if os.Getenv("CACHE_TEST_LIVE") != "1" {
		t.Skip("the live gate provisions Redis and PostgreSQL")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, os.Getenv("CACHE_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	pg := jobs.Postgres{DB: pool}
	if err := pg.Init(ctx); err != nil {
		t.Fatal(err)
	}
	url := os.Getenv("CACHE_REDIS_URL")
	client, err := OpenRedis(url)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	redisCache := Redis{Client: client}
	newRepo := func(ttl time.Duration, logger *slog.Logger) (*Repository, *originProbe) {
		probe := &originProbe{Origin: pg, read: pg.Load}
		return New(probe, redisCache, ttl, logger), probe
	}
	seed := func(t *testing.T, origin Origin, id, state string) jobs.Job {
		t.Helper()
		job, err := origin.Save(ctx, id, state)
		if err != nil {
			t.Fatal(err)
		}
		return job
	}
	checkRead := func(t *testing.T, origin Origin, want jobs.Job) {
		t.Helper()
		if got, err := origin.Load(ctx, want.ID); err != nil || got != want {
			t.Fatalf("read = %+v, %v; want %+v", got, err, want)
		}
	}

	t.Run("warm_and_invalidate", func(t *testing.T) {
		repo, probe := newRepo(10*time.Second, slog.Default())
		id := rand.Text()
		initial := seed(t, pg, id, "queued")
		checkRead(t, repo, initial)
		checkRead(t, repo, initial)
		if got := probe.reads.Load(); got != 1 {
			t.Fatalf("two reads made %d database reads; want 1", got)
		}
		t.Log("cold read and warm read: one PostgreSQL read total")

		changed := seed(t, repo, id, "running")
		if _, hit, err := redisCache.Get(ctx, id); hit || err != nil {
			t.Fatalf("cache after write: hit=%t, err=%v", hit, err)
		}
		checkRead(t, repo, changed)
		if changed.Revision != 2 || probe.reads.Load() != 2 {
			t.Fatal("committed revision 2 did not reload from PostgreSQL")
		}
		t.Log("write invalidation: revision 2 loaded from PostgreSQL")
	})

	t.Run("expiry", func(t *testing.T) {
		const ttl = 500 * time.Millisecond
		repo, probe := newRepo(ttl, slog.Default())
		id := rand.Text()
		initial := seed(t, pg, id, "queued")
		checkRead(t, repo, initial)

		remaining, err := client.PTTL(ctx, key(id)).Result()
		if err != nil || remaining <= 0 || remaining > ttl {
			t.Fatalf("Redis PTTL = %s, %v; want positive TTL up to %s", remaining, err, ttl)
		}

		// Bypass the invalidation path to isolate the effect of expiry.
		changed := seed(t, pg, id, "done")
		for deadline := time.Now().Add(2 * time.Second); ; {
			_, hit, err := redisCache.Get(ctx, id)
			if err != nil {
				t.Fatal(err)
			}
			if !hit {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("Redis key did not expire")
			}
			time.Sleep(10 * time.Millisecond)
		}
		missingID := "missing-" + rand.Text()
		if _, err := repo.Load(ctx, missingID); !errors.Is(err, pgx.ErrNoRows) {
			t.Fatalf("missing job returned %v", err)
		}
		if _, hit, err := redisCache.Get(ctx, missingID); err != nil || hit {
			t.Fatalf("missing job was cached: hit=%t, err=%v", hit, err)
		}
		checkRead(t, repo, changed)
		if probe.reads.Load() != 3 {
			t.Fatalf("database reads = %d, want 3", probe.reads.Load())
		}
		t.Log("expiration: the stored copy expired and the next read loaded revision 2")
	})

	t.Run("concurrent_misses", func(t *testing.T) {
		const requests = 32
		repo, probe := newRepo(10*time.Second, slog.Default())
		want := seed(t, pg, rand.Text(), "queued")
		start := make(chan struct{})
		results := make(chan error, requests)
		for range requests {
			go func() {
				<-start
				got, err := repo.Load(ctx, want.ID)
				if err == nil && got != want {
					err = errors.New("read returned the wrong job")
				}
				results <- err
			}()
		}
		close(start)
		for range requests {
			if err := <-results; err != nil {
				t.Fatal(err)
			}
		}
		if got := probe.reads.Load(); got != 1 {
			t.Fatalf("burst made %d PostgreSQL reads; want 1", got)
		}
		t.Logf("live cold burst: %d readers, one PostgreSQL read", requests)
	})

	t.Run("redis_paused", func(t *testing.T) {
		var warnings bytes.Buffer
		logger := slog.New(slog.NewTextHandler(&warnings, nil))
		repo, probe := newRepo(5*time.Second, logger)
		initial := seed(t, pg, rand.Text(), "queued")
		checkRead(t, repo, initial)

		opts, err := redis.ParseURL(url)
		if err != nil {
			t.Fatal(err)
		}
		control := redis.NewClient(opts)
		defer control.Close()
		if err := control.Do(ctx, "CLIENT", "PAUSE", 2000, "ALL").Err(); err != nil {
			t.Fatal(err)
		}
		start := time.Now()
		checkRead(t, repo, initial)
		changed := seed(t, repo, initial.ID, "done")
		checkRead(t, pg, changed)
		elapsed := time.Since(start)
		if probe.reads.Load() != 2 || changed.Revision != 2 || elapsed >= 1500*time.Millisecond {
			t.Fatalf("fallback: reads=%d revision=%d elapsed=%s", probe.reads.Load(), changed.Revision, elapsed)
		}
		if log := warnings.String(); !strings.Contains(log, "cache lookup failed") ||
			!strings.Contains(log, "cache invalidation failed") {
			t.Fatalf("did not observe the cache failures: %s", log)
		}
		t.Logf("Redis paused for 2s: fallback read and committed write in %s", elapsed.Round(time.Millisecond))
	})
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->

`TestLive` skips when the lab is absent. The [live gate](../gate/README.md) runs it with two disposable services. If the stall case stops at a database error, check the database connection and deadline separately from the Redis warning.
