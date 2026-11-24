# Postgres in depth gate

From the repository root, rebuild the experiment and run the live checks.

~~~bash
SWITCHYARD_PG_DEPTH_LIVE=1 python3 scripts/replay_lessons.py 3-tracks/storage-engines/01-postgres-in-depth
~~~

From your learner directory, use the gate directly.

~~~bash
SWITCHYARD_PG_DEPTH_LIVE=1 bash "$blueprint/3-tracks/storage-engines/01-postgres-in-depth/gate/run.sh" "$PWD"
~~~

The runner creates a fresh `postgres:17` container on a random loopback port. Its restore tests use the container's own data, a separate logical database, and a separate physical target data directory and socket. It removes the container and its anonymous volume after the run. The environment flag enables the database tests. Without it, the gate runs formatting, vet, and the race-enabled build.

## Pass conditions

1. Read Committed permits the deliberately stale application write. The atomic update preserves both increments. Repeatable Read rejects the same-row conflict, and Serializable protects the cross-row invariant with a fresh retry.
2. The indexed plan returns the same ordered 16 IDs with fewer shared buffer accesses. To capture both JSON plans, set `STORAGE_EVIDENCE_DIR` to an existing absolute directory before running the gate.
3. The second worker claims another row while the first transaction still holds its row lock. Only the replacement token can complete an expired and reclaimed job. The negative control changes the claim selector in a fresh database and must fail with SQLSTATE 55P03.
4. SIGKILL preserves the acknowledged marker and discards the open transaction. A logical snapshot restores the earlier row set and omits a later acknowledged write.
5. A physical restore reaches the named target using archived WAL. The pre-delete marker reappears and the subsequent write remains outside the restored timeline.

The [reference](../evidence/README.md) records the exact assertions and plan JSON. Watch which work happens on the source and which happens on a restore target before using the procedure with important data.
