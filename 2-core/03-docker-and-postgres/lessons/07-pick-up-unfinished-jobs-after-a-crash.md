# 07 Pick up unfinished jobs after a crash

> About 6 hours · Builds on [06 A retried submission survives a restart](06-a-retried-submission-survives-a-restart.md).

## The problem

The database knows a job is running. The control plane dies, and the new process has an empty lease map. A worker might still hold the old job. Switchyard must make the job eligible again and refuse a report made under the old lease.

## The mental model

~~~text
old process:  queued -> running [token 2] -> process killed
database:                 running
new process:  startup changes running -> queued
new worker:   queued -> running [token 4] -> completed + one effect
old worker:   report [token 2] -> refused
~~~

A fencing token identifies one grant. PostgreSQL sequences can skip values and keep advancing across control-plane restarts. Store the counter in PostgreSQL and keep the active lease registry in the process. After a restart the registry is rebuilt by new grants.

## The pattern

Recover from durable state before opening the listeners. This lab runs **one active control-plane process per database**. Stop the old process before starting its replacement. A deployment that allows overlapping control planes needs a shared ownership protocol.

A worker may execute the same job twice if the first owner was interrupted. The transaction from lesson 05 still commits one recorded database effect.

## Build it

### Step 1. Recover unfinished work before listening

Leave already queued and terminal jobs where they are. Move interrupted running rows back to queued. The admission limit from lesson 06 counts both states, so recovery preserves that limit. Allocate a startup generation from the same sequence used for worker lease tokens.
Create `db/migrations/005_lease_tokens.sql`:

<!-- file: db/migrations/005_lease_tokens.sql -->
~~~sql
CREATE SEQUENCE switchyard_fence AS bigint NO CYCLE;
~~~

Edit `db/migrate.sql`:

<!-- edit: db/migrate.sql -->
~~~sql
    \ir migrations/004_submission_keys.sql
    INSERT INTO schema_migrations (version) VALUES (4);
\endif
COMMIT;
~~~

~~~sql
    \ir migrations/004_submission_keys.sql
    INSERT INTO schema_migrations (version) VALUES (4);
\endif
SELECT NOT EXISTS (
    SELECT 1 FROM schema_migrations WHERE version = 5
) AS apply_005 \gset
\if :apply_005
    \ir migrations/005_lease_tokens.sql
    INSERT INTO schema_migrations (version) VALUES (5);
\endif
COMMIT;
~~~

Create `internal/pgstore/recovery.go`:

<!-- file: internal/pgstore/recovery.go -->
~~~go
package pgstore

import (
	"context"
)

// RecoverInterrupted runs before the single PostgreSQL-backed control plane starts.
func (s *Store) RecoverInterrupted(ctx context.Context) (int64, int64, error) {
	conn, err := s.acquire(ctx)
	if err != nil {
		return 0, 0, err
	}
	defer conn.Release()

	var epoch int64
	if err := conn.QueryRow(ctx, "SELECT nextval('switchyard_fence')").Scan(&epoch); err != nil {
		return 0, 0, err
	}
	tag, err := conn.Exec(ctx, "UPDATE jobs SET state = 'queued', updated_at = now() WHERE state = 'running'")
	return epoch, tag.RowsAffected(), err
}

func (s *Store) NextLeaseToken(ctx context.Context) (int64, error) {
	conn, err := s.acquire(ctx)
	if err != nil {
		return 0, err
	}
	defer conn.Release()

	var token int64
	err = conn.QueryRow(ctx, "SELECT nextval('switchyard_fence')").Scan(&token)
	return token, err
}
~~~

Apply migration 005 with `migrate`.

<!-- run: if [[ -n "${SWITCHYARD_TEST_DATABASE_URL:-}" ]]; then psql "$SWITCHYARD_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f db/migrate.sql; fi -->

### Step 2. Issue and check fence tokens

Allocate a token before trying to start a durable job. Two workers can race to start the same queued row. The expected-state check gives one worker ownership and the other discards its unused token. If a heartbeat or requeue fails because PostgreSQL is briefly unavailable, retain the lease for another reconciliation pass. An expired lease cannot be renewed or used to finish a job.
Edit `internal/coord/coord.go`:

<!-- edit: internal/coord/coord.go -->
~~~go
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

~~~go
// QueuedJobs finds the first durable job available to try.
type QueuedJobs interface {
	FirstQueued(ctx context.Context) (jobs.ID, bool, error)
	NextLeaseToken(ctx context.Context) (int64, error)
}

type Coordinator struct {
	queued  QueuedJobs
	epoch   int64
	jobs    Jobs
	pending <-chan jobs.ID
	ttl     time.Duration
~~~

<!-- edit: internal/coord/coord.go -->
~~~go
}

// UseDurableQueue selects durable discovery before workers start.
func (c *Coordinator) UseDurableQueue(queue QueuedJobs) {
	c.queued = queue
}

// Register adds a worker and gives it an ID.
~~~

~~~go
}

// UseDurableQueue selects durable discovery before workers start.
func (c *Coordinator) UseDurableQueue(queue QueuedJobs, epoch int64) {
	c.queued = queue
	c.epoch = epoch
}

// Register adds a worker and gives it an ID.
~~~

<!-- edit: internal/coord/coord.go -->
~~~go
	defer c.mu.Unlock()
	c.workerSeq++
	id := fmt.Sprintf("%s-%d", name, c.workerSeq)
	c.workers[id] = c.now()
	return Registration{WorkerID: id, LeaseTTL: c.ttl, Heartbeat: c.ttl / 3}
}
~~~

~~~go
	defer c.mu.Unlock()
	c.workerSeq++
	id := fmt.Sprintf("%s-%d", name, c.workerSeq)
	if c.epoch != 0 {
		id = fmt.Sprintf("%s-%d-%d", name, c.epoch, c.workerSeq)
	}
	c.workers[id] = c.now()
	return Registration{WorkerID: id, LeaseTTL: c.ttl, Heartbeat: c.ttl / 3}
}
~~~

<!-- edit: internal/coord/coord.go -->
~~~go
			}
		}
		start, cancel := context.WithTimeout(context.WithoutCancel(ctx), c.ttl)
		job, err := c.jobs.Start(start, id)
		cancel()
		if errors.Is(err, jobs.ErrInvalidTransition) || errors.Is(err, jobs.ErrNotFound) {
~~~

~~~go
			}
		}
		start, cancel := context.WithTimeout(context.WithoutCancel(ctx), c.ttl)
		var token int64
		if c.queued != nil {
			var err error
			token, err = c.queued.NextLeaseToken(start)
			if err != nil {
				cancel()
				return Lease{}, false, err
			}
		}
		job, err := c.jobs.Start(start, id)
		cancel()
		if errors.Is(err, jobs.ErrInvalidTransition) || errors.Is(err, jobs.ErrNotFound) {
~~~

<!-- edit: internal/coord/coord.go -->
~~~go
			return Lease{}, false, err
		}
		c.mu.Lock()
		c.tokenSeq++
		lease := Lease{Job: job, Token: c.tokenSeq, WorkerID: worker, Expires: c.now().Add(c.ttl)}
		c.leases[id] = lease
		c.mu.Unlock()
		return lease, true, nil
~~~

~~~go
			return Lease{}, false, err
		}
		c.mu.Lock()
		if c.queued == nil {
			c.tokenSeq++
			token = c.tokenSeq
		}
		lease := Lease{Job: job, Token: token, WorkerID: worker, Expires: c.now().Add(c.ttl)}
		c.leases[id] = lease
		c.mu.Unlock()
		return lease, true, nil
~~~

<!-- edit: internal/coord/coord.go -->
~~~go
	var stop []jobs.ID
	for _, h := range held {
		lease, ok := c.leases[h.Job]
		if !ok || lease.Token != h.Token {
			stop = append(stop, h.Job)
			continue
		}
		job, err := c.jobs.Get(ctx, h.Job)
		if err != nil || job.State != jobs.StateRunning {
			delete(c.leases, h.Job)
			stop = append(stop, h.Job)
			continue
~~~

~~~go
	var stop []jobs.ID
	for _, h := range held {
		lease, ok := c.leases[h.Job]
		if !ok || lease.Token != h.Token || lease.WorkerID != worker || !c.now().Before(lease.Expires) {
			stop = append(stop, h.Job)
			continue
		}
		job, err := c.jobs.Get(ctx, h.Job)
		if err != nil && !errors.Is(err, jobs.ErrNotFound) {
			return nil, err // leave the lease for a later heartbeat or reconciliation
		}
		if job.State != jobs.StateRunning {
			delete(c.leases, h.Job)
			stop = append(stop, h.Job)
			continue
~~~

<!-- edit: internal/coord/coord.go -->
~~~go
		return c.jobs.Get(ctx, job)
	}
	lease, ok := c.leases[job]
	if !ok || lease.Token != token {
		return jobs.Job{}, ErrLeaseLost
	}
	finish, cancel := context.WithTimeout(context.WithoutCancel(ctx), c.ttl)
~~~

~~~go
		return c.jobs.Get(ctx, job)
	}
	lease, ok := c.leases[job]
	if !ok || lease.Token != token || !c.now().Before(lease.Expires) {
		return jobs.Job{}, ErrLeaseLost
	}
	finish, cancel := context.WithTimeout(context.WithoutCancel(ctx), c.ttl)
~~~

<!-- edit: internal/coord/coord.go -->
~~~go
		if now.Before(lease.Expires) {
			continue
		}
		delete(c.leases, id)
		if _, err := c.jobs.Requeue(ctx, id); err != nil {
			continue // it isn't running any more: cancelled while its worker was silent
		}
		c.handBack = append(c.handBack, id)
		c.handedBack++
		c.log.Warn("lease expired; job handed back", "job_id", id, "worker", lease.WorkerID)
		select {
~~~

~~~go
		if now.Before(lease.Expires) {
			continue
		}
		_, err := c.jobs.Requeue(ctx, id)
		if errors.Is(err, jobs.ErrInvalidTransition) || errors.Is(err, jobs.ErrNotFound) {
			delete(c.leases, id)
			continue
		}
		if err != nil {
			c.log.Warn("could not requeue expired lease", "job_id", id, "error", err)
			continue
		}
		delete(c.leases, id)
		if c.queued == nil {
			c.handBack = append(c.handBack, id)
		}
		c.handedBack++
		c.log.Warn("lease expired; job handed back", "job_id", id, "worker", lease.WorkerID)
		select {
~~~

<!-- edit: internal/coord/coord.go -->
~~~go
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.Reconcile(ctx)
		}
	}
}
~~~

~~~go
		case <-ctx.Done():
			return
		case <-ticker.C:
			pass, cancel := context.WithTimeout(ctx, c.ttl)
			c.Reconcile(pass)
			cancel()
		}
	}
}
~~~

Edit `cmd/switchyard/main.go`:

<!-- edit: cmd/switchyard/main.go -->
~~~go
	keys := idempotency.NewStore(cfg.IdempotencyTTL, time.Now)
	keyOption := httpapi.WithIdempotency(keys)
	if store != nil {
		coordinator.UseDurableQueue(store)
		keyOption = httpapi.WithDurableIdempotency(service)
	}
	queueDepth := func() float64 {
~~~

~~~go
	keys := idempotency.NewStore(cfg.IdempotencyTTL, time.Now)
	keyOption := httpapi.WithIdempotency(keys)
	if store != nil {
		startup, cancel := context.WithTimeout(ctx, 10*time.Second)
		epoch, recovered, err := store.RecoverInterrupted(startup)
		cancel()
		if err != nil {
			return fmt.Errorf("recover interrupted jobs: %w", err)
		}
		coordinator.UseDurableQueue(store, epoch)
		logger.Info("recovered interrupted jobs", "jobs", recovered, "epoch", epoch)
		keyOption = httpapi.WithDurableIdempotency(service)
	}
	queueDepth := func() float64 {
~~~

The coordinator verifies the token before calling the completion transaction. If that transaction committed but its reply was lost, another completion attempt with the same active token can return the already committed job.

Edit `internal/pgstore/completion.go`:

<!-- edit: internal/pgstore/completion.go -->
~~~go
	if err != nil {
		return jobs.Job{}, err
	}
	if err := job.Complete(now.UTC().Truncate(time.Microsecond)); err != nil {
		return job, err
	}
~~~

~~~go
	if err != nil {
		return jobs.Job{}, err
	}
	// The caller already checked the active token. A previous attempt
	// may have committed even though the connection dropped.
	if job.State == jobs.StateCompleted {
		var exists bool
		err := tx.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM job_effects WHERE job_id = $1)", id).Scan(&exists)
		if err != nil {
			return jobs.Job{}, err
		}
		if exists {
			return job, nil
		}
	}
	if err := job.Complete(now.UTC().Truncate(time.Microsecond)); err != nil {
		return job, err
	}
~~~

### Step 3. Check recovery against a database

The test starts one job and completes another, then simulates the startup recovery pass. It verifies both job states, the recorded effect, and advancement of the sequence.
Create `internal/pgstore/recovery_test.go`:

<!-- file: internal/pgstore/recovery_test.go -->
~~~go
package pgstore_test

import (
	"testing"

	"switchyard/internal/jobs"
)

func TestRecoverInterrupted(t *testing.T) {
	ctx, _, store, svc, running := completionFixture(t)
	finished, err := svc.Create(ctx, "already completed", 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Start(ctx, finished.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Finish(ctx, finished.ID, nil); err != nil {
		t.Fatal(err)
	}
	before, err := store.NextLeaseToken(ctx)
	if err != nil {
		t.Fatal(err)
	}

	epoch, recovered, err := store.RecoverInterrupted(ctx)
	if err != nil || recovered < 1 || epoch <= before {
		t.Fatalf("recover: epoch %d after %d, rows %d, error %v", epoch, before, recovered, err)
	}
	after, err := store.NextLeaseToken(ctx)
	if err != nil || after <= epoch {
		t.Fatalf("next fence: token %d after %d, error %v", after, epoch, err)
	}
	assertCompletion(t, ctx, store, running.ID, jobs.StateQueued, 0)
	assertCompletion(t, ctx, store, finished.ID, jobs.StateCompleted, 1)
	t.Log("restart advanced the fence and left the terminal job alone")
}
~~~

~~~bash
go test -race -v -count=1 -run '^TestRecoverInterrupted$' ./internal/pgstore
~~~

~~~text
=== RUN   TestRecoverInterrupted
    recovery_test.go:34: job is queued with 0 effects
    recovery_test.go:35: job is completed with 1 effects
    recovery_test.go:36: restart advanced the fence and left the terminal job alone
--- PASS: TestRecoverInterrupted (0.08s)
PASS
ok  	switchyard/internal/pgstore	1.114s
~~~

### Step 4. Give the drill a worker that holds its token

The probe registers and leases one job, then exits without reporting completion. You can submit a token later over the same gRPC worker API used by Switchyard's workers.
Create `cmd/leaseprobe/main.go`:

<!-- file: cmd/leaseprobe/main.go -->
~~~go
package main

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"switchyard/internal/grpcapi/workersv1"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	usage := fmt.Errorf("usage: leaseprobe ADDRESS lease | leaseprobe ADDRESS complete JOB TOKEN")
	if len(args) < 2 {
		return usage
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := grpc.NewClient(args[0], grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	defer conn.Close()
	client := workersv1.NewWorkersClient(conn)

	switch args[1] {
	case "lease":
		if len(args) != 2 {
			return usage
		}
		reg, err := client.Register(ctx, &workersv1.RegisterRequest{Name: "leaseprobe"})
		if err != nil {
			return err
		}
		lease, err := client.Lease(ctx, &workersv1.LeaseRequest{WorkerId: reg.GetWorkerId(), WaitMs: 1000})
		if err != nil {
			return err
		}
		if !lease.GetGranted() {
			return fmt.Errorf("no job granted")
		}
		fmt.Println(lease.GetJobId(), lease.GetToken())
	case "complete":
		if len(args) != 4 {
			return usage
		}
		job, err := strconv.ParseInt(args[2], 10, 64)
		if err != nil {
			return err
		}
		token, err := strconv.ParseInt(args[3], 10, 64)
		if err != nil {
			return err
		}
		if _, err := client.Complete(ctx, &workersv1.CompleteRequest{JobId: job, Token: token}); err != nil {
			return err
		}
		fmt.Println("completion accepted")
	default:
		return usage
	}
	return nil
}
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->

### Step 5. Kill the process and try both tokens

Use a fresh lab database with no competing workers. Build `bin/switchyard` and `bin/leaseprobe`. Start the API with `SWITCHYARD_DATABASE_URL` and a long lease for the drill, such as `LEASE_TTL=2m`. In another terminal submit one job, then grant a lease:

~~~bash
curl -fsS -H 'Content-Type: application/json' \
  -d '{"description":"recover this job","duration_ms":0}' http://127.0.0.1:8080/jobs
read -r job old_token <<< "$(./bin/leaseprobe 127.0.0.1:9090 lease)"
~~~

Use `kill -KILL` on the API PID from the shell that started it. Restart the API with the same database and lease TTL. Lease again and compare the job and token:

~~~bash
read -r recovered new_token <<< "$(./bin/leaseprobe 127.0.0.1:9090 lease)"
test "$recovered" = "$job"
test "$new_token" -gt "$old_token"
./bin/leaseprobe 127.0.0.1:9090 complete "$job" "$old_token"
./bin/leaseprobe 127.0.0.1:9090 complete "$job" "$new_token"
curl -fsS "http://127.0.0.1:8080/effects/$job"
~~~

The old report must fail. The replacement report and the effects lookup must succeed.

~~~text
before crash: job 1, running, token 2
after restart: same job 1, token 4
old report: rpc error: code = FailedPrecondition desc = lease lost: the job is no longer yours
new report: completion accepted
{"job_id":1,"effects":1}
~~~

## Check it

Explain why the old worker's registration and token can both become stale, and why the job ID remains the same. Trace what would happen if the process died after changing the job to running but before sending the lease to a worker.

## If it goes wrong

- If a different job is leased, stop other workers and use a database with an empty queue.
- If no rows recover, check that the job was running before killing the API and that the replacement is using the same database.
- If the replacement refuses both reports, compare the configured lease TTL with the time since the second grant.
