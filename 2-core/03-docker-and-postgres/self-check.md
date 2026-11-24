# Self-check · Docker and Postgres

Answer in your own words. Use the logs, queries, and results from your own runs.

## Explain it

### 01 What disappears on restart

1. What did a Switchyard restart remove? What did a Docker container restart preserve?
2. How did the client container find PostgreSQL? What would `localhost` point to from that client?

### 02 A schema you can change

1. Why do a migration and its history insert share one transaction?
2. What did the query planner do before and after the partial index? Why might a tiny table produce a different plan?
3. Explain how the quote in a job description reaches the database as data.

### 03 One contract for two repositories

1. What happened to the two competing writes? Where does each repository enforce the condition?
2. Why should the PostgreSQL create operation return the timestamp it actually stored?

### 04 A connection pool has a limit

1. How did the test exhaust the pool without guessing at a request rate?
2. How could you distinguish queue overload from pool exhaustion using the API and metrics?
3. Which deadline applies while acquiring a connection, and which applies while using it?

### 05 Complete a job in one transaction

1. Draw the failure that left a completed job with zero effects in the broken run. Which statement moved the visibility boundary?
2. Which row did cancellation compete for, and why does a losing writer have to read it again?

### 06 A retried submission survives a restart

1. What is the fingerprint made from? Why store the original response snapshot when you already have the job ID?
2. What does a retried key do when admission is full? How does the database keep two simultaneous submissions from claiming the last slot?
3. What happens if the client loses its reply before commit? After commit?

### 07 Pick up unfinished jobs after a crash

1. Which state is repaired before the API starts? What happens to a row that is already completed?
2. Why can a worker still have a token after the control plane that issued it is gone? How did you prove the old token could not finish the job?
3. Which change would be needed before permitting two active control planes against one database?

### 08 Run the stack and measure it

1. Which Compose dependency waits for migrations, and what does it wait for?
2. Which settings did you match across both backends? How would send lag, refused requests, or a cold run bias the result?
3. Name the files and records you would keep for someone reproducing your comparison.

## From memory

1. Draw the tables and transaction for an idempotent submission. Label the steps that have to commit together and the steps that can be retried.
2. Write a conditional update and a concurrent test that fails if both callers report success.
3. Design a worker recovery drill with a real process kill. Specify how you will know the old lease was granted, the replacement ran, and the effect was recorded once.
4. Sketch a Compose stack with a migration job and a named database volume. Explain how you would prove replacement preserved the data.

For more questions and a place to record your evidence, use the [extended review](extended-review.md).
