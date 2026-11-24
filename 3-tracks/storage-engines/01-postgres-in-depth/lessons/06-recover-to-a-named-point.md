# 06 Recover to a named point

> Postgres in depth · Week 3

## The problem

The last logical dump is older than the change you want to recover. You need an available base backup, all relevant WAL segments, and a precise stopping point.

## The mental model

~~~text
base backup ── wanted committed row ── restore point ── delete + new row
     restore copy + archived WAL ────────────────┘
~~~

## The pattern

Take a physical base backup with the WAL needed to make it consistent. Enable archiving on the source, commit a marker, and make a named restore point. Change the source after that point, force a segment switch, and check that the segment has been archived. Recover the base backup into a separate data directory with a distinct socket. Use `restore_command` to fetch archived segments and promote at the named target. [pg_basebackup](https://www.postgresql.org/docs/17/app-pgbasebackup.html) · [Point-in-time recovery](https://www.postgresql.org/docs/17/continuous-archiving.html)

## Build it

Trace `point_in_time` in the recovery driver. Mark the source and recovery sockets so you can query them independently. The gate's archive writes a complete temporary file before publishing it, and verifies a repeated segment against the already archived bytes.

The local trial stores source and backup on the same host to reproduce the sequence. Durable backup operations also need separately retained, monitored copies and a test that permissions and archive retention cover the recovery window.

## Check it

The recovered database must contain the pre-delete marker and exclude the later marker. The source still reflects the delete and later commit. An available restored server must report that it has left recovery before the gate queries it. Read the [capture](../evidence/README.md) for the observed LSN and readiness time.
