# Distributed KV capstone · Exercises

Work on a separate branch from your reference build.

## Move the reply boundary

Create one additional deterministic recovery schedule with a put followed by a delete. Interrupt the process after applying the delete and before returning its result.

- Retry the delete under the same mutation identity after another peer is elected.
- Verify a missing-key read for that tenant and check that a second tenant’s identical key survived.
- Save the client intervals and say which response was indeterminate.

## Explain restart work

Measure local reconstruction time with two snapshot sizes and a fixed committed suffix.

- Keep each run’s applied index, snapshot index, and key count.
- Identify the first point at which the restarted group can serve a fresh read.
- Explain what a disk-resident projection cache would need to validate before reusing its files.

## Change one benchmark variable

Repeat both read paths with a different key distribution or number of client threads. Apply the change to both paths.

- Report successful and failed operations, throughput, and read p95 and p99.
- Compare the results with the isolated CPU profiles. Describe which costs the YCSB client includes.
- Record the input config and exact run order alongside the raw output.

See the [gate and export instructions](gate/README.md).
