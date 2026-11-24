# Gate

Run the gate against the Switchyard checkout you rebuilt from memory. It needs Go, Docker with Compose, `psql`, and Python 3. From this repository:

~~~bash
bash 2-core/03-docker-and-postgres/gate/run.sh /path/to/your/switchyard
~~~

The gate builds the two Linux binaries, starts a separate Compose project, and creates a disposable contract-test database. It checks the memory and PostgreSQL repository contracts, holds every pool connection, and forces rollback after the job state changes. Go formatting, vet, and the race detector also run.

An HTTP client submits a keyed job. A gRPC probe holds its lease while the gate kills the API with SIGKILL. The restarted API has to return the stored submission response, give the same job a new lease, and refuse completion with the old token. The replacement lease can complete and retry with exactly one recorded effect.

The gate then replaces the PostgreSQL container and checks the replacement's container ID. It reads the same committed job, effect, and retry record from the original volume. Finally it starts a Compose worker and checks that the worker can finish new work.

A failure exits nonzero and prints the relevant check and Compose logs. Each invocation cleans up only its own project and volumes. The [evidence index](../evidence/README.md) links to passing and deliberately broken runs.

The broken run disables the token comparison in `Coordinator.Complete` for the PostgreSQL backend. The restarted API then accepts the obsolete report. The gate flags that response before checking container replacement.
