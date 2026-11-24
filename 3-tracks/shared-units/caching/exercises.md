# Caching · Exercises

## Cache warehouse balances

Build an inventory read path that caches the current quantity and revision per SKU. PostgreSQL holds the authoritative balances. Add a cache adapter, a timeout, versioned keys, and a way to count database reads from your test.

### Acceptance

- Two sequential reads of one cold SKU produce one PostgreSQL read. Two different SKUs return their own balances.
- A write commits a new revision and removes the cached copy. The next read observes the new value and records a database read.
- Use a deterministic 32-request burst to show that a cold SKU loads once per process. Repeat with request sharing removed and capture the changed read count.
- Pause Redis and show that a read and write still use PostgreSQL. Record the elapsed time, effective deadline, and the logged invalidation result.
- Draw a schedule where a reader fills the old revision after a newer write deletes its key. Show that your configured TTL expires that copy, then record the revision the next read gets.

## Measure the process boundary

Run two independent instances of your inventory repository against the same Redis server. Block both origin loads until both instances have missed. Release the loads and record the database read count. Explain which coordination belongs to Redis and which coordination is local to the application process.
