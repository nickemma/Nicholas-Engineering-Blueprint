# Storage engines and types

"Which database?" is two questions:
- **What shape is the data, and how is it queried?** That decides the type.
- **Are writes or reads more important, and at what size?** That decides the engine.

## Types

| Type | Shape | Strong at | Examples |
|---|---|---|---|
| **Relational** | Tables, joins, constraints | Transactions, flexible queries, integrity | PostgreSQL, MySQL |
| **Key-value** | Key → blob | Simple, fast lookups at scale | Redis, DynamoDB, etcd |
| **Wide-column** | Partition key → sorted rows | Huge write volumes, time-ordered data per key | Cassandra, Bigtable |
| **Document** | Key → nested document | Self-contained objects, flexible schema | MongoDB |
| **Time-series** | (series, time) → value | Metrics, compression, downsampling | Prometheus, InfluxDB |
| **Search** | Inverted index | Full-text and faceted search | OpenSearch, Elasticsearch |
| **Object storage** | Bucket/key → large immutable blob | Cheap, durable, huge; not low-latency | S3, GCS |
| **Columnar / analytical** | Columns stored together | Scans and aggregates over billions of rows | Parquet + DuckDB, ClickHouse, BigQuery |

**Default to PostgreSQL** until a requirement rules it out, and say which requirement did.

## Indexes start with the query

Write the query first. For a tenant's recent jobs filtered by status, try a B-tree on `(tenant_id, status, created_at)` and check whether PostgreSQL uses it to filter and return results in order. Compare `EXPLAIN (ANALYZE, BUFFERS)` on representative data and measure inserts or updates too. An index uses space and adds maintenance to writes. A sequential scan can be cheaper when the query returns much of the table. [Index lab](../../2-core/03-docker-and-postgres/lessons/02-a-schema-you-can-change.md#step-4-add-an-index-for-pending-work)

## Engines: B-tree or LSM tree

| | **B-tree** (PostgreSQL, MySQL InnoDB) | **LSM tree** (RocksDB, Cassandra, Pebble) |
|---|---|---|
| Writes | Update pages in place, plus a write-ahead log | Append to a log and a memory table; flush sorted files; merge them later (compaction) |
| Reads | One path down the tree | May check several files (Bloom filters help) |
| Best for | Read-heavy, mixed workloads | Write-heavy workloads |
| Cost | Random writes, page splits | Compaction uses disk bandwidth; read and space amplification |

## Durability

- A write is durable once it's in the **write-ahead log** and the log is `fsync`ed. Before that, it's in the page cache and dies with the power.
- Replication protects against a lost machine; **backups** protect against a bad `DELETE`. Test restores, not just backups.

## In an interview

Pick the type from the access pattern, and say why: *"Jobs are looked up by ID and listed by tenant and status: relational, with an index on (tenant, status, created_at)."* Name the index for every query you rely on.

## Where you built it

- [Core 04](../../2-core/04-rust-foundations/README.md): an append-only log with checksums that survives torn writes.
- [Core 03](../../2-core/03-docker-and-postgres/README.md): PostgreSQL with migrations and connection pooling.
- [Postgres in depth](../../3-tracks/storage-engines/01-postgres-in-depth/README.md): indexes and `EXPLAIN ANALYZE`; B-trees against LSM trees; the WAL and `fsync`; backup and restore.
- [AWS and Terraform](../../3-tracks/shared-units/aws-and-terraform/README.md): S3 on AWS.
- [ML for infrastructure](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/README.md): Parquet.
