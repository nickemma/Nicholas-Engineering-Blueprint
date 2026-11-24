# Exercise · Build a fenced work queue

Build a small queue in a separate repository. Workers claim items, process them outside the queue, and publish results to a protected store. A paused worker can wake after another worker took over the same item. Your store must keep the newer worker's result.

## Finished behavior

Use one command-line script runner or a test harness that exposes these operations.

| Operation | Expected behavior |
|---|---|
| `enqueue(job)` | Records a job that can be claimed. |
| `claim(job, worker, ttl)` | Issues a larger token than any prior grant for that job if the old grant has expired. An active grant blocks a second claim. |
| `renew(job, worker, token, ttl)` | Extends an active matching grant while keeping its token. It rejects expired grants and mismatched owners or tokens. |
| `publish(job, token, value)` | Rejects a token below the protected store's highest accepted token. The comparison and value update occur in one atomic operation. |
| `advance(ticks)` | Moves the exercise clock by a specified amount. Use this in automated tests to reproduce expiry without waiting or sleeping. |
| `restart(issuer)` or `restart(resource)` | Reopens that component from durable state. Durability can use a transactional database or your own checked file format. |

Put time under test control. If you use a monotonic virtual clock, carry its progress across issuer restart. Persist the grant and the token before returning a claim. The store must persist the token together with the result. Keep the issuer's decision and the resource's validation as distinct operations so the tests can pause a worker between them.

## Acceptance checks

1. Enqueue a job. Worker A claims it and pauses before publish. Advance past expiry. Worker B claims it with a larger token and successfully publishes.
2. Resume A. Its late write is rejected, and reading the result still returns B's value.
3. Restart the protected store. A's token is still rejected.
4. Restart the issuer. After B expires, grant C a token larger than B's. Test that a restart before B's expiry still prevents another grant.
5. At the expiry boundary, renewal fails. A valid renewal keeps the token and extends the deadline. A concurrent claim test sees one grant.
6. Temporarily remove the check at the protected store. Show the same pause test overwriting B's result, then restore the check.
7. Record the acceptance run and explain the step that first makes A's token stale at the resource. If using Go, run `go test -race ./...`.

## Stretch

Back the issuer with the Core 07 peers. Kill the leader after committing a grant. Retry from a fresh client and check that a new grant, when permitted, advances the token. Explain whether your client can tell if a timed-out grant took effect.
