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

- [Rust Bridge](../../lessons/rust-bridge/README.md): an append-only log with checksums that survives torn writes.
- [Phase 3](../../lessons/03-durable-auditable-data/README.md): PostgreSQL with migrations, indexes and `EXPLAIN ANALYZE`; B-trees against LSM trees; the WAL and `fsync`; backup and restore.
- [Phase 5](../../lessons/05-constrained-operations/README.md): S3 on AWS.
- [Phase 7](../../lessons/07-utility-evaluation/README.md): Parquet and DuckDB.
