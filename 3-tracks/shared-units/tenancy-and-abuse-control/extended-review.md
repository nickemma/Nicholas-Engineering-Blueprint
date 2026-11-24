# Tenancy and abuse control · Extended review

More questions on this module, beyond the [self-check](self-check.md). Answer from memory, then check yourself against the lessons. Write each "predict" answer before running anything.

## Questions

### Lesson 01: Issue a tenant access token

1. What is a JWT made of? What can anyone holding one read?
2. Predict: you remove the audience check. Which test fails, with what error, and what could an attacker now do?
3. How does a key rotation proceed without breaking any valid token? What are the two waiting periods?

### Lesson 02: Verify the token at the API boundary

4. Why does an asymmetric signature suit an API that many services verify?

### Lesson 03: Rotate signing keys with overlap

5. List the five checks in `Verify`, in order, and the attack each stops.

### Lesson 04: Scope PostgreSQL to the tenant

6. Why is `404` the right answer for another tenant's job?

### Lesson 05: Authorize routes and budget each tenant

7. Why does the limiter charge only requests the policy allowed?

### Lesson 06: Share a bucket across API instances

8. Explain a token bucket without a timer. Why does the Redis version run as one Lua script?

## Evidence worksheet

Fill this in as you go, with evidence: commands and their output, test names, captures. Keep your filled-in copy in your own repository.

### Explain it

| Lesson | Question | My answer | Evidence |
|---|---|---|---|
| 01 | Why does the API verify with a public key, and what would a shared HMAC secret allow? | | |
| 02 | Why did removing the algorithm check not let `alg: none` through, and why keep it? | | |
| 02 | Why does the key-set client limit how often it refetches? | | |
| 03 | What does each of the five checks in `Verify` stop? | | |
| 05 | Decision point vs enforcement point: why one decision point? | | |
| 08 | Why does the tenant come from the token, and why `404` rather than `403`? | | |
| 08 | List every place Switchyard keys data by job ID, and how each is scoped to a tenant | | |

### Evidence checklist

| Claim | Command, test or capture | Result |
|---|---|---|
| A token for another audience refused; the test that fails without the check | | |
| A rotated signing key: old and new tokens both accepted | | |
| A reader refused a write; the denial logged with its reason | | |
| Another tenant's job: `404` from the API; refused by RLS with no `WHERE` | | |
| One shared bucket shown with a new connection per request | | |

### Rebuild from memory

- What I rebuilt without help:
- What I had to look up:
- How my design differs from the lessons, and why:
- What is still unclear:
