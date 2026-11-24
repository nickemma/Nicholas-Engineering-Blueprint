# Caching · Self-check

1. What does PostgreSQL own? What should the application do on a Redis hit, a miss, and a timeout?
2. Why delete after the database commit? Draw an interleaving where a delayed cache fill can still publish an earlier revision.
3. When does the TTL start? Which stale interval does it bound?
4. Why check the cache again inside singleflight? What happens when two different keys miss?
5. What happens to the other waiters when the first caller cancels? What deadline bounds the fill?
6. Why does a cache timeout leave a committed database write successful? How do you find out that invalidation failed?
7. Which result from the gate depends on sharing a Go process? What could happen to PostgreSQL load when Redis stalls across many replicas?

## From memory

Draw and label both the healthy and paused Redis read paths. Predict the number of PostgreSQL reads for a cold read, a warm read, and 32 overlapping misses inside one process. Run the gate and compare.

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
