# 06 Share a bucket across API instances

> Tenancy and abuse control · Week 3

## The problem

Two API instances with their own local buckets each spend the full burst. The total budget then grows with the number of instances.

## The mental model

~~~text
API instance A ─┐
                ├─ Redis key for this tenant → refill, debit, expire atomically
API instance B ─┘
~~~

## The pattern

Run the update as one Redis script. Use Redis time for the refill calculation so API clocks do not determine the quota. Expire idle buckets after they can fully refill. A failed quota lookup returns 503 on this protected route. That choice preserves the cap and trades availability for a clear overload boundary.

## Build it

### Apply the token-bucket transition in Redis

Store the token balance and last refill time together. Give the client a short deadline and return the retry duration from the same script.

Create `internal/quota/redis.go`.

<!-- file: internal/quota/redis.go -->
~~~go
package quota

import (
	"context"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
)

// Redis owns both the clock and each bucket's atomic state transition.
var take = redis.NewScript(`
local burst = tonumber(ARGV[1])
local interval = tonumber(ARGV[2])
local time = redis.call('TIME')
local now = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)
local state = redis.call('HMGET', KEYS[1], 'tokens', 'at')
local last = tonumber(state[2]) or now
local clock = math.max(now, last)
local tokens = math.min(burst, (tonumber(state[1]) or burst) + (clock - last) / interval)
local allowed = 0
local retry = 0
if tokens >= 1 then
  tokens = tokens - 1
  allowed = 1
else
  retry = math.ceil((1 - tokens) * interval + clock - now)
end
redis.call('HSET', KEYS[1], 'tokens', tostring(tokens), 'at', tostring(clock))
redis.call('PEXPIRE', KEYS[1], burst * interval + clock - now + 1)
return {allowed, retry}
`)

type Shared struct {
	Client   *redis.Client
	Prefix   string
	Burst    int
	Interval time.Duration
}

func OpenRedis(url string) (*redis.Client, error) {
	opts, err := redis.ParseURL(url)
	if err != nil {
		return nil, err
	}
	opts.DialTimeout = 300 * time.Millisecond
	opts.ReadTimeout = 300 * time.Millisecond
	opts.WriteTimeout = 300 * time.Millisecond
	opts.PoolTimeout = 300 * time.Millisecond
	opts.ContextTimeoutEnabled = true
	opts.MaxRetries = -1
	return redis.NewClient(opts), nil
}

func (s Shared) Take(ctx context.Context, tenant string) (Decision, error) {
	if s.Burst < 1 || s.Interval.Milliseconds() < 1 {
		return Decision{}, errors.New("invalid bucket configuration")
	}
	attempt, cancel := context.WithTimeout(ctx, 300*time.Millisecond)
	defer cancel()
	reply, err := take.Run(attempt, s.Client, []string{s.Prefix + tenant}, s.Burst, s.Interval.Milliseconds()).Int64Slice()
	if err != nil {
		return Decision{}, err
	}
	if len(reply) != 2 || (reply[0] != 0 && reply[0] != 1) || reply[1] < 0 {
		return Decision{}, errors.New("invalid bucket reply")
	}
	return Decision{Allowed: reply[0] == 1, Retry: time.Duration(reply[1]) * time.Millisecond}, nil
}
~~~

## Check it

~~~bash
go vet ./... && go test -race -count=1 ./...
~~~

<!-- run: go vet ./... && go test -race -count=1 ./... -->


The gate uses two server instances with independent Redis clients. Across both, a burst of 16 authorized reads from one tenant admits two and rejects fourteen. The other tenant still receives its own allowance.
