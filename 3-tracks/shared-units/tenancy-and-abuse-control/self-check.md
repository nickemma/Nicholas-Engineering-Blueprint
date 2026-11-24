# Tenancy and abuse control · Self-check

1. Which token claims come from provisioning, and which checks establish that a request carries the right access token?
2. In what order do you publish, activate, and retire signing keys? What state would a production issuer need to retain across restarts?
3. Which decision returns 401, 403, and 404? Why can identical job IDs resolve to different rows?
4. Where does the runtime login get its tenant context, and when does PostgreSQL clear it?
5. What do the RLS USING and WITH CHECK expressions protect? Which kinds of login can bypass RLS?
6. What happens to one tenant's allowance when you add a replica using a local bucket? Why is the Redis debit atomic?
7. Why does the protected route return 503 when Redis is unavailable? Where should that differ from 429, and what changes if you allow requests during the outage?

## From memory

Draw the path from client credentials to a tenant-scoped query. Label the component that decides each refusal and the evidence you would collect when a decision is wrong.

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
