# 03 Retrieval over the tenant's runbooks and jobs

**Checked in CI:** Python formatting, lint and offline tests. **Run locally:** Docker, the CPU embedding model, database attacks, retrieval evaluation and query plans. Historical outputs below come from the saved Step 3 lab captures; [the evidence report](../evidence/retrieval/report.md) distinguishes these from the new replay and live checks.


The assistant answers from a tenant's own runbooks and job history. It can't read them all for every question: a small model's context holds a few pages at most. So it **retrieves**: it finds the handful of passages most likely to help, and puts only those in the prompt. That's retrieval-augmented generation (RAG), and this step builds the retrieval half.

Retrieval is where tenant data first meets the model, which puts two rows of the threat model in play straight away: **A7** (retrieval returns another tenant's data) and **A14** (poisoned documents steer the answer). This step attacks A7. Step 7 comes back to A14.

## Embeddings, briefly

An **embedding model** turns a piece of text into a vector: a list of numbers, here 384 of them. It's trained so that texts that mean similar things get vectors pointing in similar directions. "The export timed out waiting for a lock" and "something held a lock during the export" share few words but land close together.

Closeness is measured as **cosine distance**: 0 when two vectors point the same way, 1 for orthogonal vectors, and 2 for opposite vectors. Geometry alone does not establish whether two passages are relevant. To retrieve, you embed the question, then return the stored chunks with the smallest distance to it. That's nearest-neighbour search, and pgvector adds it to PostgreSQL: a `vector` column type and a `<=>` operator for cosine distance.

The model is [bge-small-en-v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5) (MIT licence): a small model that runs on a laptop CPU. It uses the same pinned llama.cpp server image as Phase 8, but the embedding weights are a new dependency to verify. Fetch the GGUF file from [ggml-org](https://huggingface.co/ggml-org/bge-small-en-v1.5-Q8_0-GGUF/tree/main) into your `models` directory. Keep its publisher, repository revision and licence beside it, and run `sha256sum models/bge-small-en-v1.5-q8_0.gguf`. The retained lab asset has this checksum:

~~~text
f046db1dc724cf4f6f0a0c5917e922823b73eb1d27b8f9a9c2797f7866974804  bge-small-en-v1.5-q8_0.gguf
~~~

## Start the database and the embedding model

Phase 3's PostgreSQL image doesn't include pgvector, so this lab runs the pgvector project's image: the same PostgreSQL 17, with the extension built in. Both images are pinned by digest.

<!-- file: experiments/rag/compose.yaml -->
~~~yaml
# Retrieval lab (Phase 9, step 3): PostgreSQL with pgvector, and an
# embedding model on the same pinned llama.cpp server as Phase 8.
#   export MODELS="$PWD/models"
#   docker compose -f experiments/rag/compose.yaml up -d --wait
# Lab-only passwords: never reuse them, and never publish these ports
# beyond 127.0.0.1.
services:
  db:
    image: pgvector/pgvector:0.8.7-pg17-bookworm@sha256:b513c48566e4777cd3370451400000c78eda6a08131d68f4c31d4a76f27bd8fd
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: lab-superuser
      POSTGRES_DB: rag
    ports:
      - "127.0.0.1:15432:5432"
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres", "-d", "rag"]
      interval: 2s
      timeout: 5s
      retries: 20

  embed:
    image: ghcr.io/ggml-org/llama.cpp@sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b
    # bge-small-en-v1.5 (MIT): 33M parameters, 384 dimensions. It was
    # trained to pool on the first ([CLS]) token, so say so.
    command: ["-m", "/models/bge-small-en-v1.5-q8_0.gguf", "--embeddings", "--pooling", "cls",
              "-c", "2048", "-t", "4", "--host", "0.0.0.0", "--port", "8080"]
    volumes:
      - ${MODELS:?set MODELS to the directory with the GGUF files}:/models:ro
    ports:
      - "127.0.0.1:18090:8080"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8080/health"]
      interval: 2s
      timeout: 3s
      retries: 30
~~~

Notice `--pooling cls`. A model like this produces one vector per token, and something must combine them into one vector for the text. bge was trained to use the first token's vector (`[CLS]`), so that's what the server must do; averaging instead gives vectors the model was never trained to produce, and quietly worse retrieval.

~~~bash
export MODELS="$PWD/models"
docker compose -f experiments/rag/compose.yaml up -d --wait
~~~

## The table

One row per **chunk**: a passage small enough to put in a prompt, with its embedding. Two columns matter for security later. `source` says where the text came from, so an answer can cite it (A14). `author` records who wrote it: a runbook comes from the tenant's admins, but a job's description comes from whoever submitted the job, and Step 7 will show why that difference matters.

<!-- file: experiments/rag/schema.sql -->
~~~sql
-- Retrieval's table: one row per chunk of a runbook or job, with its
-- embedding. Run as the superuser:
--   docker compose -f experiments/rag/compose.yaml exec -T db \
--     psql -U postgres -d rag -v ON_ERROR_STOP=1 < experiments/rag/schema.sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE documents (
    id        BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant    TEXT        NOT NULL,
    source    TEXT        NOT NULL, -- runbooks/exports.md#schedule, job/4182
    author    TEXT        NOT NULL, -- who wrote this text: its provenance
    body      TEXT        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 2000),
    model     TEXT        NOT NULL, -- which embedding model made the vector
    embedding vector(384) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant, source)
);

-- An approximate nearest-neighbour index, for cosine distance (<=>).
CREATE INDEX documents_embedding ON documents USING hnsw (embedding vector_cosine_ops);

-- The application's login.
CREATE ROLE rag_app LOGIN PASSWORD 'lab-app';
GRANT SELECT, INSERT, UPDATE, DELETE ON documents TO rag_app;
~~~

The index is **HNSW** (hierarchical navigable small world). Finding the true nearest neighbours means computing the distance to every row. HNSW builds a graph linking each vector to some of its neighbours, and a search walks the graph towards the question, visiting a small fraction of the rows. It's *approximate*: fast, but it can miss a true neighbour. Keep that in mind.

This first version keeps tenants apart the way most applications do: with `WHERE tenant = ...` in each query. You'll attack that.

~~~bash
docker compose -f experiments/rag/compose.yaml exec -T db \
  psql -U postgres -d rag -v ON_ERROR_STOP=1 < experiments/rag/schema.sql
~~~

## The corpus

These are synthetic exports of the tenant's runbooks and job history, not a connection to the live jobs API. Ingestion here is a trusted operator's CLI. `author` is fixture metadata, not an authenticated signature; a hash or source label alone cannot prove who wrote a passage. Indexing upserts current chunks but does not remove obsolete ones. A production importer needs authorized export, deletion handling and versioned provenance.


Two tenants. Acme has four runbooks and some job history; Hooli has two runbooks and three jobs. One of Hooli's runbooks contains something Acme must never see: the code for Hooli's incident bridge.

<!-- file: experiments/rag/corpus/acme/stuck-jobs.md -->
~~~markdown
# Jobs stuck in running

## Symptoms

A job shows `running` for more than ten minutes, and its worker has stopped
sending heartbeats. The job's events end with `claimed` and nothing after it.

## Cause

A worker claimed the job and then died: the process crashed, the pod was
evicted, or the node was drained without a grace period. The claim is a
lease, so nothing is lost; the job is only waiting for the lease to run out.

## Fix

Wait. The sweep returns a job to `queued` five minutes after its lease
expires, and another worker picks it up. Don't cancel it by hand: a
cancelled job is not retried, and its customer sees a failure.

## Escalate

If more than twenty jobs are stuck at once, the workers are failing as a
group. Page the on-call engineer and check the worker deployment first.
~~~

<!-- file: experiments/rag/corpus/acme/exports.md -->
~~~markdown
# Nightly exports

## Schedule

The orders export runs every night at 02:00 UTC and writes one file per
region to the `acme-exports` bucket. It usually takes twelve minutes.

## Timeout waiting for a lock

If an export fails with `timeout waiting for lock`, the monthly reporting
query was holding a lock on the orders table. Retry the export after
03:00 UTC, when the report has finished. Don't kill the report.

## Files too large

An export over 5 GB is split into parts named `orders-<region>-<n>.csv`.
Downstream loaders must read every part; a loader that reads only the
first file silently drops orders.
~~~

<!-- file: experiments/rag/corpus/acme/webhooks.md -->
~~~markdown
# Webhook deliveries failing

## Status 401

The receiver rejected our signature. Its signing secret was rotated and
ours wasn't. Ask the tenant admin to rotate the webhook secret in the
Runway console; deliveries resume with the next event.

## Retries

A failed delivery is retried with exponential backoff for up to 24 hours.
After that it is dropped and recorded as `delivery_abandoned`.

## Status 410

A receiver that answers 410 Gone has asked to be removed. The webhook is
disabled at once, and no further deliveries are attempted until an admin
enables it again.
~~~

<!-- file: experiments/rag/corpus/acme/rate-limits.md -->
~~~markdown
# Too many requests

## Status 429

Each tenant may submit 600 jobs a minute. Above that, the API answers
`429 Too Many Requests` with a `Retry-After` header in seconds.

## What to do

Batch submissions instead of sending one job per request, and honour
`Retry-After`. A client that retries at once only stays limited longer.

## Raising the limit

Limits are raised through a support ticket with a week's traffic graph.
They are never raised during an incident.
~~~

<!-- file: experiments/rag/corpus/acme/jobs.jsonl -->
~~~json
{"id": 4182, "author": "svc-orders", "state": "failed", "description": "nightly export orders eu-west", "failure_reason": "timeout waiting for lock after 300 s"}
{"id": 4183, "author": "svc-orders", "state": "completed", "description": "nightly export orders us-east", "failure_reason": ""}
{"id": 4190, "author": "maria", "state": "failed", "description": "resize product images batch 17", "failure_reason": "worker lost: lease expired"}
{"id": 4201, "author": "svc-billing", "state": "failed", "description": "send invoice webhooks for october", "failure_reason": "receiver answered 401 Unauthorized"}
{"id": 4202, "author": "svc-billing", "state": "completed", "description": "send invoice webhooks for september", "failure_reason": ""}
{"id": 4215, "author": "deploy-bot", "state": "failed", "description": "bulk submit 2000 reindex jobs", "failure_reason": "429 Too Many Requests"}
{"id": 4220, "author": "maria", "state": "running", "description": "rebuild search index", "failure_reason": ""}
{"id": 4231, "author": "svc-orders", "state": "failed", "description": "nightly export orders ap-south", "failure_reason": "timeout waiting for lock after 300 s"}
~~~

<!-- file: experiments/rag/corpus/hooli/incident-bridge.md -->
~~~markdown
# Joining the incident bridge

## When

Join the bridge for any severity 1 or 2 incident, or when paged.

## How

Hooli's incident bridge code is HOOLI-BRIDGE-4471. Dial in and announce
your name and team. The incident commander runs the call.
~~~

<!-- file: experiments/rag/corpus/hooli/stuck-jobs.md -->
~~~markdown
# Stuck jobs at Hooli

## Symptoms

Jobs stay in `running` after their worker stops. The dashboard shows them
in red after fifteen minutes.

## Fix

Restart the worker pool from the Hooli operations console, then wait for
the sweep. If jobs stay stuck, join the incident bridge.
~~~

<!-- file: experiments/rag/corpus/hooli/jobs.jsonl -->
~~~json
{"id": 9001, "author": "gavin", "state": "failed", "description": "compress uploads for nucleus", "failure_reason": "out of memory"}
{"id": 9002, "author": "gavin", "state": "completed", "description": "nightly backup of nucleus", "failure_reason": ""}
{"id": 9010, "author": "svc-signal", "state": "failed", "description": "notify partners of outage", "failure_reason": "receiver answered 401 Unauthorized"}
~~~

## Chunk, embed, store, search

Add the PostgreSQL driver to `serve`:

<!-- edit: serve/pyproject.toml -->
~~~toml
    "numpy>=2",
    "torch>=2.0",
~~~
to:
~~~toml
    "numpy>=2",
    "psycopg[binary]>=3.2",
    "torch>=2.0",
~~~

The lab embeds questions without a query prefix, as allowed by the [BGE model card](https://huggingface.co/BAAI/bge-small-en-v1.5). The publisher recommends evaluating a retrieval instruction for short queries; changing that is an experiment, not a free improvement. Keep the setting fixed for these comparisons.

The module does four things. It **chunks** each runbook by section, starting every chunk with the runbook's title and the section's heading so that a chunk still makes sense alone ("Fix. Wait." means nothing without "Jobs stuck in running"). It **embeds** chunks through the server's OpenAI-style `/v1/embeddings` endpoint. It **stores** them, and it **searches**: by question, and "more like this", the chunks nearest to one the user is already reading.

<!-- file: serve/src/serve/rag.py -->
~~~python
"""Retrieval over a tenant's runbooks and job history.

Every chunk of text stored here was written by someone: a runbook author, a
job submitter, a worker's failure message. It is untrusted input, whoever
wrote it. And the tenant a search runs for always comes from the caller's
verified identity, never from the question, a document, or a model.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import psycopg

MODEL = "bge-small-en-v1.5-q8_0"
DIM = 384
MAX_CHARS = 1200


@dataclass(frozen=True)
class Chunk:
    source: str  # where it came from: runbooks/exports.md#schedule, job/4182
    author: str  # who wrote it
    body: str


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def pack(sentences: list[str], limit: int) -> list[str]:
    """Join sentences into pieces of at most `limit` characters, never splitting one."""
    pieces, current = [], ""
    for s in sentences:
        if current and len(current) + 1 + len(s) > limit:
            pieces.append(current)
            current = s
        else:
            current = f"{current} {s}".strip()
    if current:
        pieces.append(current)
    return pieces


def chunk_runbook(name: str, text: str, author: str, limit: int = MAX_CHARS) -> list[Chunk]:
    """One chunk per "## " section, each starting with the runbook's title and the
    section's heading, so a chunk still makes sense when it's read alone."""
    title, sections = "", []
    for line in text.splitlines():
        if line.startswith("# "):
            title = line[2:].strip()
        elif line.startswith("## "):
            sections.append((line[3:].strip(), []))
        elif sections:
            sections[-1][1].append(line)
    chunks = []
    for heading, lines in sections:
        words = " ".join(" ".join(lines).split())
        if not words:
            continue
        prefix = f"{title}: {heading}."
        sentences = re.split(r"(?<=[.!?])\s+", words)
        for n, piece in enumerate(pack(sentences, limit - len(prefix) - 1), start=1):
            source = f"runbooks/{name}#{slug(heading)}" + (f"/{n}" if n > 1 else "")
            chunks.append(Chunk(source, author, f"{prefix} {piece}"))
    return chunks


def chunk_job(job: dict) -> Chunk:
    body = f"Job {job['id']} ({job['state']}): {job['description']}."
    if job["failure_reason"]:
        body += f" Failure: {job['failure_reason']}."
    return Chunk(f"job/{job['id']}", job["author"], body)


def load_corpus(directory: Path) -> list[Chunk]:
    """Runbooks (*.md) are written by the tenant's admins; jobs by whoever submitted them."""
    chunks = []
    for path in sorted(directory.glob("*.md")):
        chunks += chunk_runbook(path.name, path.read_text(), author="runbook-admin")
    jobs = directory / "jobs.jsonl"
    if jobs.exists():
        chunks += [chunk_job(json.loads(line)) for line in jobs.read_text().splitlines() if line]
    return chunks


class Embedder:
    """Client for an OpenAI-style /v1/embeddings endpoint (llama.cpp's server)."""

    def __init__(self, url: str, batch: int = 32, timeout: float = 30) -> None:
        self.url, self.batch, self.timeout = url.rstrip("/"), batch, timeout

    def __call__(self, texts: list[str]) -> list[list[float]]:
        vectors = []
        for i in range(0, len(texts), self.batch):
            body = json.dumps({"input": texts[i : i + self.batch]}).encode()
            request = urllib.request.Request(
                self.url + "/v1/embeddings", body, {"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                data = json.load(response)["data"]
            vectors += [d["embedding"] for d in sorted(data, key=lambda d: d["index"])]
        if len(vectors) != len(texts) or any(len(v) != DIM for v in vectors):
            raise ValueError(f"expected {len(texts)} vectors of {DIM} dimensions")
        return vectors


def literal(vector: list[float]) -> str:
    """pgvector's text form, '[0.1,0.2,...]'. Passed as a parameter, never pasted into SQL."""
    return "[" + ",".join(f"{x:.6f}" for x in vector) + "]"


def add(conn, tenant: str, chunks: list[Chunk], vectors: list[list[float]]) -> None:
    with conn.transaction():
        for c, v in zip(chunks, vectors, strict=True):
            conn.execute(
                """INSERT INTO documents (tenant, source, author, body, model, embedding)
                   VALUES (%s, %s, %s, %s, %s, %s::vector)
                   ON CONFLICT (tenant, source) DO UPDATE
                   SET author = excluded.author, body = excluded.body,
                       model = excluded.model, embedding = excluded.embedding""",
                (tenant, c.source, c.author, c.body, MODEL, literal(v)),
            )


def search(conn, tenant: str, vector: list[float], k: int = 5) -> list[tuple]:
    """The k nearest chunks by cosine distance: (source, author, body, distance)."""
    with conn.transaction():
        return conn.execute(
            """SELECT source, author, body, embedding <=> %s::vector AS distance
               FROM documents WHERE tenant = %s
               ORDER BY embedding <=> %s::vector LIMIT %s""",
            (literal(vector), tenant, literal(vector), k),
        ).fetchall()


def similar(conn, tenant: str, source: str, k: int = 5) -> list[tuple]:
    """ "More like this": the chunks nearest to one the user is reading."""
    with conn.transaction():
        return conn.execute(
            """SELECT source, author, body,
                      embedding <=> (SELECT embedding FROM documents
                                     WHERE tenant = %s AND source = %s) AS distance
               FROM documents WHERE source <> %s
               ORDER BY distance LIMIT %s""",
            (tenant, source, source, k),
        ).fetchall()


def first_hit(ranked: list[str], want: list[str]) -> int | None:
    """The 1-based rank of the first relevant source, or None if none was returned."""
    for rank, source in enumerate(ranked, start=1):
        if source in want:
            return rank
    return None


def summarise(ranks: list[int | None], k: int) -> dict:
    """hit@1 and hit@k: the share of questions with a right answer that high.
    MRR, mean reciprocal rank: 1 for a first-place hit, 1/2 for second, 0 for a miss."""
    n = len(ranks)
    return {
        "questions": n,
        "hit@1": sum(r == 1 for r in ranks) / n,
        f"hit@{k}": sum(r is not None and r <= k for r in ranks) / n,
        "mrr": sum(1 / r for r in ranks if r) / n,
    }


def show(rows: list[tuple]) -> None:
    for rank, (source, author, body, distance) in enumerate(rows, start=1):
        print(f"{rank}  {distance:.3f}  {source:42} {author:14} {body[:60]}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="serve.rag")
    p.add_argument("--db", default=os.environ.get("RAG_DATABASE_URL", ""))
    p.add_argument("--embed", default=os.environ.get("RAG_EMBED_URL", "http://127.0.0.1:18090"))
    p.add_argument("--tenant", required=True, help="in the lab, you play the verified identity")
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("index", help="chunk, embed and store a tenant's corpus")
    s.add_argument("directory", type=Path)
    s = sub.add_parser("search")
    s.add_argument("question")
    s.add_argument("-k", type=int, default=5)
    s = sub.add_parser("similar")
    s.add_argument("source")
    s.add_argument("-k", type=int, default=5)
    s = sub.add_parser("eval", help="score retrieval against questions with known answers")
    s.add_argument("questions", type=Path)
    s.add_argument("-k", type=int, default=3)
    args = p.parse_args(argv)

    embed = Embedder(args.embed)
    with psycopg.connect(args.db, autocommit=True) as conn:
        if args.command == "index":
            chunks = load_corpus(args.directory)
            started = time.monotonic()
            vectors = embed([c.body for c in chunks])
            add(conn, args.tenant, chunks, vectors)
            print(f"{len(chunks)} chunks in {time.monotonic() - started:.1f} s")
        elif args.command == "search":
            show(search(conn, args.tenant, embed([args.question])[0], args.k))
        elif args.command == "similar":
            show(similar(conn, args.tenant, args.source, args.k))
        elif args.command == "eval":
            rows = [json.loads(line) for line in args.questions.read_text().splitlines() if line]
            ranks = []
            for row, vector in zip(rows, embed([r["q"] for r in rows]), strict=True):
                found = [r[0] for r in search(conn, args.tenant, vector, 10)]
                ranks.append(first_hit(found, row["want"]))
                print(f"{ranks[-1] or '-':>2}  {row['q']}")
            print(json.dumps({k: round(v, 3) for k, v in summarise(ranks, args.k).items()}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
~~~

Two details. Vectors travel to PostgreSQL as a parameter in pgvector's text form, never pasted into the SQL: a vector is data like any other. And the CLI's `--tenant` flag stands in for the verified identity, which Step 4 wires to the token. In this module the tenant is always an argument chosen by the caller, never something found in a question or a document.

<!-- file: serve/tests/test_rag.py -->
~~~python
from serve.rag import chunk_job, chunk_runbook, first_hit, literal, pack, summarise

RUNBOOK = """# Nightly exports

## Schedule

The export runs at 02:00 UTC.
It takes twelve minutes.

## Empty section

## Files too large

Over 5 GB, an export is split into parts.
"""


def test_a_runbook_becomes_one_chunk_per_section_with_its_title():
    chunks = chunk_runbook("exports.md", RUNBOOK, author="runbook-admin")
    assert [c.source for c in chunks] == [
        "runbooks/exports.md#schedule",
        "runbooks/exports.md#files-too-large",
    ]
    assert chunks[0].body == (
        "Nightly exports: Schedule. The export runs at 02:00 UTC. It takes twelve minutes."
    )


def test_a_long_section_is_split_between_sentences():
    text = "# T\n\n## Long\n\n" + " ".join(f"Sentence number {i}." for i in range(100))
    chunks = chunk_runbook("t.md", text, author="a", limit=200)
    assert len(chunks) > 1
    assert all(len(c.body) <= 200 for c in chunks)
    assert chunks[1].source == "runbooks/t.md#long/2"
    assert all(c.body.endswith(".") for c in chunks)


def test_pack_never_splits_a_sentence():
    assert pack(["aaaa.", "bbbb.", "cccc."], limit=11) == ["aaaa. bbbb.", "cccc."]
    assert pack(["a sentence longer than the limit."], limit=5) == [
        "a sentence longer than the limit."
    ]


def test_a_job_keeps_its_submitter_as_author():
    job = {"id": 7, "author": "maria", "state": "failed", "description": "resize"}
    c = chunk_job(job | {"failure_reason": "lease expired"})
    assert (c.source, c.author) == ("job/7", "maria")
    assert c.body == "Job 7 (failed): resize. Failure: lease expired."
    assert chunk_job(job | {"failure_reason": ""}).body == "Job 7 (failed): resize."


def test_vector_literal():
    assert literal([0.5, -0.25]) == "[0.500000,-0.250000]"


def test_scores():
    assert first_hit(["a", "b", "c"], ["c", "x"]) == 3
    assert first_hit(["a", "b"], ["x"]) is None
    s = summarise([1, 2, None, 4], k=3)
    assert s == {"questions": 4, "hit@1": 0.25, "hit@3": 0.5, "mrr": (1 + 0.5 + 0.25) / 4}
~~~

<!-- run: cd serve && uv sync -q && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_rag.py -->

## Index both tenants, and search

~~~bash
export RAG_DATABASE_URL=postgres://rag_app:lab-app@127.0.0.1:15432/rag
rag() { uv run -q --project serve python -m serve.rag "$@"; }
rag --tenant acme index experiments/rag/corpus/acme
rag --tenant hooli index experiments/rag/corpus/hooli
rag --tenant acme search "what does the runbook say about stuck jobs?" -k 3
~~~

~~~text
21 chunks in 0.5 s
7 chunks in 0.2 s
~~~

~~~text
1  0.236  runbooks/stuck-jobs.md#cause               runbook-admin  Jobs stuck in running: Cause. A worker claimed the job and t
2  0.244  runbooks/stuck-jobs.md#symptoms            runbook-admin  Jobs stuck in running: Symptoms. A job shows `running` for m
3  0.245  runbooks/stuck-jobs.md#escalate            runbook-admin  Jobs stuck in running: Escalate. If more than twenty jobs ar
~~~

The columns are rank, cosine distance, source, author and the start of the text. These are candidate passages, not generated answers. Top-k search will return even irrelevant passages when they are the closest available; this step does not calibrate abstention or prove answer correctness.

## Measure retrieval quality

"It found the right thing" on one question proves little. Write questions whose right answers you know, in words that *don't* copy the runbooks, and score them:

<!-- file: experiments/rag/eval.jsonl -->
~~~json
{"q": "a job has said running for twenty minutes and the worker is gone", "want": ["runbooks/stuck-jobs.md#symptoms", "runbooks/stuck-jobs.md#cause"]}
{"q": "why would a worker vanish while it holds a job?", "want": ["runbooks/stuck-jobs.md#cause"]}
{"q": "should I cancel a stuck job?", "want": ["runbooks/stuck-jobs.md#fix"]}
{"q": "lots of jobs are stuck at the same time, who do I call?", "want": ["runbooks/stuck-jobs.md#escalate"]}
{"q": "when does the orders export run?", "want": ["runbooks/exports.md#schedule"]}
{"q": "export failed because something held a lock", "want": ["runbooks/exports.md#timeout-waiting-for-a-lock", "job/4182", "job/4231"]}
{"q": "the downstream load is missing orders after a big export", "want": ["runbooks/exports.md#files-too-large"]}
{"q": "receiver rejects our signature", "want": ["runbooks/webhooks.md#status-401", "job/4201"]}
{"q": "how long do we keep retrying a webhook?", "want": ["runbooks/webhooks.md#retries"]}
{"q": "a customer endpoint returned gone", "want": ["runbooks/webhooks.md#status-410"]}
{"q": "how many jobs can we submit per minute?", "want": ["runbooks/rate-limits.md#status-429"]}
{"q": "our client keeps getting throttled, what should it do?", "want": ["runbooks/rate-limits.md#what-to-do", "runbooks/rate-limits.md#status-429"]}
{"q": "can support increase our quota during an outage?", "want": ["runbooks/rate-limits.md#raising-the-limit"]}
{"q": "which job failed with a lost lease?", "want": ["job/4190"]}
{"q": "the reindex submission was refused", "want": ["job/4215"]}
{"q": "what time is the reporting query finished?", "want": ["runbooks/exports.md#timeout-waiting-for-a-lock"]}
~~~

Three numbers summarise it. **hit@1** is the share of questions whose first result is a right answer. **hit@3** is the share with a right answer somewhere in the top three: what matters when the prompt gets three chunks. **MRR** (mean reciprocal rank) gives 1 for a right answer first, 1/2 for second, 1/3 for third, and 0 for a miss, then averages.

~~~bash
rag --tenant acme eval experiments/rag/eval.jsonl
~~~

~~~text
 1  a job has said running for twenty minutes and the worker is gone
 1  why would a worker vanish while it holds a job?
 1  should I cancel a stuck job?
 1  lots of jobs are stuck at the same time, who do I call?
 1  when does the orders export run?
 1  export failed because something held a lock
 1  the downstream load is missing orders after a big export
 1  receiver rejects our signature
 1  how long do we keep retrying a webhook?
 3  a customer endpoint returned gone
 1  how many jobs can we submit per minute?
 1  our client keeps getting throttled, what should it do?
 1  can support increase our quota during an outage?
 1  which job failed with a lost lease?
 1  the reindex submission was refused
 1  what time is the reporting query finished?
{"questions": 16, "hit@1": 0.938, "hit@3": 1.0, "mrr": 0.958}
~~~

Be suspicious of numbers this good. Sixteen questions is a small sample (one miss moves hit@1 by 0.06), and the same person wrote the runbooks and the questions, so they share a vocabulary real users won't. Treat it as a **regression baseline**: a change that drops these numbers broke something. It isn't proof that retrieval is good.

## Attack: read another tenant's runbooks

The hypothesis comes from how the code is written: isolation lives in each query's `WHERE` clause, so any query that forgets one leaks. Read `similar()` with that in mind, then try it, as Acme:

~~~bash
rag --tenant acme similar "runbooks/stuck-jobs.md#escalate"
~~~

~~~text
1  0.205  runbooks/stuck-jobs.md#symptoms            runbook-admin  Jobs stuck in running: Symptoms. A job shows `running` for m
2  0.219  runbooks/stuck-jobs.md#cause               runbook-admin  Jobs stuck in running: Cause. A worker claimed the job and t
3  0.248  runbooks/stuck-jobs.md#symptoms            runbook-admin  Stuck jobs at Hooli: Symptoms. Jobs stay in `running` after
4  0.255  runbooks/stuck-jobs.md#fix                 runbook-admin  Stuck jobs at Hooli: Fix. Restart the worker pool from the H
5  0.259  runbooks/stuck-jobs.md#fix                 runbook-admin  Jobs stuck in running: Fix. Wait. The sweep returns a job to
~~~

Ranks 3 and 4 are Hooli's: "Stuck jobs at Hooli". Both tenants named their runbook `stuck-jobs.md`, so the sources look like Acme's own; only the text gives them away. `similar()` checks the tenant when it looks up the chunk you started from, and forgets it in the outer query. Ask for everything:

~~~bash
rag --tenant acme similar "runbooks/stuck-jobs.md#escalate" -k 100 | grep -i -e hooli -e bridge
~~~

~~~text
3  0.248  runbooks/stuck-jobs.md#symptoms            runbook-admin  Stuck jobs at Hooli: Symptoms. Jobs stay in `running` after
4  0.255  runbooks/stuck-jobs.md#fix                 runbook-admin  Stuck jobs at Hooli: Fix. Restart the worker pool from the H
17  0.422  runbooks/incident-bridge.md#when           runbook-admin  Joining the incident bridge: When. Join the bridge for any s
27  0.482  runbooks/incident-bridge.md#how            runbook-admin  Joining the incident bridge: How. Hooli's incident bridge co
~~~

Rank 27 is the chunk with Hooli's bridge code, `HOOLI-BRIDGE-4471`, readable by any Acme user. Save the output as evidence.

Notice what the bug *wasn't*. Nobody bypassed authentication or crafted an injection: the attacker used a feature as designed. And notice why it was there to be found: every query had to remember the tenant, so the system was exactly as safe as its most forgetful query. Step 4 will put a model in charge of *choosing* queries.

## Fix it: let PostgreSQL keep tenants apart

Phase 6 solved this for jobs (migration 0007): **row-level security** (RLS). The [PostgreSQL row-security documentation](https://www.postgresql.org/docs/17/ddl-rowsecurity.html) explains how policies constrain visible rows. The serving role must neither own the table nor have superuser or BYPASSRLS privileges; those roles bypass ordinary RLS. This lab keeps schema administration separate. Apply the same design here:

<!-- file: experiments/rag/rls.sql -->
~~~sql
-- The fix for finding R1: PostgreSQL keeps tenants apart, so a query that
-- forgets its tenant filter returns nothing it shouldn't. The same design
-- as Runway's migration 0007 (Phase 6, step 4). Run as the superuser:
--   docker compose -f experiments/rag/compose.yaml exec -T db \
--     psql -U postgres -d rag -v ON_ERROR_STOP=1 < experiments/rag/rls.sql
BEGIN;

-- The role every request switches to. It can't log in, owns nothing, and
-- row-level security applies to it.
CREATE ROLE runway_tenant NOLOGIN NOSUPERUSER NOBYPASSRLS;

-- The tenant this transaction acts for, or an error: a forgotten tenant
-- must fail loudly, not quietly match nothing.
CREATE FUNCTION current_tenant() RETURNS TEXT
LANGUAGE plpgsql STABLE AS $$
DECLARE
    t TEXT := current_setting('app.tenant', true);
BEGIN
    IF t IS NULL OR t = '' THEN
        RAISE EXCEPTION 'app.tenant is not set: no tenant for this transaction';
    END IF;
    RETURN t;
END
$$;

ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON documents TO runway_tenant
    USING (tenant = current_tenant())
    WITH CHECK (tenant = current_tenant());

-- Only the tenant role may touch the table. The application's own login
-- holds no rights on it at all, so a query run outside a tenant fails.
GRANT SELECT, INSERT, UPDATE, DELETE ON documents TO runway_tenant;
REVOKE ALL ON documents FROM rag_app;
-- INHERIT FALSE: rag_app may become runway_tenant, but doesn't hold its
-- rights while it is itself (PostgreSQL 16 and later).
GRANT runway_tenant TO rag_app WITH INHERIT FALSE;

COMMIT;
~~~

~~~bash
docker compose -f experiments/rag/compose.yaml exec -T db \
  psql -U postgres -d rag -v ON_ERROR_STOP=1 < experiments/rag/rls.sql
~~~

The application's login, `rag_app`, now has no rights on `documents` at all. Run the attack again, with the code unchanged:

~~~text
Traceback (most recent call last):
  File "<frozen runpy>", line 198, in _run_module_as_main
  File "<frozen runpy>", line 88, in _run_code
  File "serve/src/serve/rag.py", line 224, in <module>
    sys.exit(main())
             ^^^^^^
  File "serve/src/serve/rag.py", line 211, in main
    show(similar(conn, args.tenant, args.source, args.k))
         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "serve/src/serve/rag.py", line 146, in similar
    return conn.execute(
           ^^^^^^^^^^^^^
  File "serve/.venv/lib/python3.12/site-packages/psycopg/connection.py", line 304, in execute
    raise ex.with_traceback(None)
psycopg.errors.InsufficientPrivilege: permission denied for table documents
(exit 1)
~~~

Refusing everything is the right failure. Now change the code so that every query runs inside one tenant: a transaction that switches to `runway_tenant` and sets `app.tenant`. `SET LOCAL` and `set_config(..., true)` last until the transaction ends, so the state is reset at the end of the outer transaction. A later check explicitly refuses nested transactions and tests reuse after both commit and rollback.

<!-- edit: serve/src/serve/rag.py -->
~~~python
import urllib.request
from dataclasses import dataclass
~~~
to:
~~~python
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
def add(conn, tenant: str, chunks: list[Chunk], vectors: list[list[float]]) -> None:
    with conn.transaction():
~~~
to:
~~~python
@contextmanager
def as_tenant(conn, tenant: str):
    """One transaction, acting for one tenant. PostgreSQL's row-level security
    then hides every other tenant's rows, whatever the query inside says."""
    if not tenant:
        raise ValueError("no tenant: refusing to query")
    with conn.transaction():
        conn.execute("SET LOCAL ROLE runway_tenant")
        conn.execute("SELECT set_config('app.tenant', %s, true)", (tenant,))
        yield conn


def add(conn, tenant: str, chunks: list[Chunk], vectors: list[list[float]]) -> None:
    with as_tenant(conn, tenant):
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
    """The k nearest chunks by cosine distance: (source, author, body, distance)."""
    with conn.transaction():
~~~
to:
~~~python
    """The k nearest chunks by cosine distance: (source, author, body, distance)."""
    with as_tenant(conn, tenant):
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
    """ "More like this": the chunks nearest to one the user is reading."""
    with conn.transaction():
~~~
to:
~~~python
    """ "More like this": the chunks nearest to one the user is reading."""
    with as_tenant(conn, tenant):
~~~

`similar()`'s query is deliberately left as it was, missing filter and all. Run the attack:

~~~bash
rag --tenant acme similar "runbooks/stuck-jobs.md#escalate" -k 100 | grep -i -e hooli -e bridge; echo "grep exit $?"
rag --tenant acme similar "runbooks/stuck-jobs.md#escalate" -k 100 | wc -l
rag --tenant hooli similar "runbooks/stuck-jobs.md#fix" -k 3
~~~

~~~text
grep exit 1
20
~~~

~~~text
1  0.182  runbooks/stuck-jobs.md#symptoms            runbook-admin  Stuck jobs at Hooli: Symptoms. Jobs stay in `running` after
2  0.305  runbooks/incident-bridge.md#how            runbook-admin  Joining the incident bridge: How. Hooli's incident bridge co
3  0.387  runbooks/incident-bridge.md#when           runbook-admin  Joining the incident bridge: When. Join the bridge for any s
~~~

Twenty rows: all of Acme's 21 chunks except the one you started from, and nothing of Hooli's. Hooli still sees its own bridge runbook. The missing filter no longer leaks rows under this restricted role. RLS is the backstop, but the query still needs ordinary correctness checks: later in this step we fix the missing-source behaviour too. Fix the query too, but the lesson is the layer underneath. Keep `search()`'s own `WHERE tenant = %s` as well: two independent checks are better than one.

## Keep the attack

These tests run against the lab database with made-up vectors, so they need PostgreSQL but no model. Without `RAG_DATABASE_URL` they're skipped, which is how CI runs them.

<!-- file: serve/tests/test_rag_live.py -->
~~~python
"""Regression tests for retrieval's findings, against the lab database.

They make their own tenants and made-up vectors, so they need PostgreSQL but
no model. Without RAG_DATABASE_URL they are skipped.
"""

import os
import uuid

import psycopg
import pytest

from serve.rag import Chunk, add, as_tenant, search, similar

DB = os.environ.get("RAG_DATABASE_URL")
live = pytest.mark.skipif(not DB, reason="set RAG_DATABASE_URL to the lab database")


def unit(i: int) -> list[float]:
    v = [0.0] * 384
    v[i] = 1.0
    return v


@pytest.fixture
def two_tenants():
    a, b = f"test-a-{uuid.uuid4().hex[:8]}", f"test-b-{uuid.uuid4().hex[:8]}"
    with psycopg.connect(DB, autocommit=True) as conn:
        add(
            conn,
            a,
            [Chunk("doc/1", "x", "A's first"), Chunk("doc/2", "x", "A's second")],
            [unit(0), unit(1)],
        )
        add(conn, b, [Chunk("doc/7", "x", "B's secret")], [unit(0)])
        yield conn, a, b
        for t in (a, b):
            with as_tenant(conn, t):
                conn.execute("DELETE FROM documents")


@live
def test_more_like_this_never_crosses_tenants(two_tenants):
    conn, a, b = two_tenants
    # B's secret is the nearest possible vector to A's doc/1, and the query
    # has no tenant filter: only row-level security keeps it out.
    rows = similar(conn, a, "doc/1", k=100)
    assert [r[2] for r in rows] == ["A's second"]


@live
def test_search_never_crosses_tenants(two_tenants):
    conn, a, b = two_tenants
    assert [r[2] for r in search(conn, b, unit(0), k=100)] == ["B's secret"]


@live
def test_a_query_outside_a_tenant_is_refused(two_tenants):
    conn, _, _ = two_tenants
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        conn.execute("SELECT count(*) FROM documents")
    with pytest.raises(ValueError, match="no tenant"):
        search(conn, "", unit(0))


@live
def test_the_tenant_role_without_a_tenant_fails_loudly(two_tenants):
    conn, _, _ = two_tenants
    with pytest.raises(psycopg.errors.RaiseException, match="app.tenant is not set"):
        with conn.transaction():
            conn.execute("SET LOCAL ROLE runway_tenant")
            conn.execute("SELECT count(*) FROM documents")


@live
def test_a_tenant_cannot_write_into_another(two_tenants):
    conn, a, b = two_tenants
    with pytest.raises(psycopg.errors.InsufficientPrivilege, match="row-level security"):
        with as_tenant(conn, a):
            conn.execute(
                "INSERT INTO documents (tenant, source, author, body, model, embedding)"
                " VALUES (%s, 'doc/9', 'x', 'planted', 'm', %s::vector)",
                (b, "[" + ",".join(["0"] * 383 + ["1"]) + "]"),
            )
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_rag.py tests/test_rag_live.py -->

Run them against the lab: `cd serve && RAG_DATABASE_URL=$RAG_DATABASE_URL uv run pytest -q tests/test_rag_live.py`. All five pass.

A regression test only counts if it fails without the fix. Check it on a throwaway database with everything from `rls.sql` *except* `ENABLE ROW LEVEL SECURITY`. In the reference run, three tests failed:

FAILED tests/test_rag.py::test_more_like_this_never_crosses_tenants - assert ...
FAILED tests/test_rag.py::test_the_tenant_role_without_a_tenant_fails_loudly
FAILED tests/test_rag.py::test_a_tenant_cannot_write_into_another - Failed: D...
3 failed, 8 passed in 0.41s

The first time this check ran, only two failed. The cross-tenant test passed without RLS because Tenant B's secret had the same source, `doc/1`, as the chunk the query started from, so `source <> 'doc/1'` excluded it by accident. A test that passes for the wrong reason protects nothing; giving B's row its own source fixed it. Always watch a security test fail before trusting it to pass.

## Write the finding

Use Step 2's seven-part record:

<!-- file: docs/security/r1-retrieval-cross-tenant.md -->
~~~markdown
# R1: "more like this" returns other tenants' runbooks

Evidence class: live, against the lab database and embedding model.
Related threat: A7 (retrieval returns another tenant's data). Preconditions:
an authenticated user of any tenant.

1. Threat: a user of one tenant reads another tenant's runbooks and jobs
   through retrieval.
2. Security assumption: every query on `documents` keeps to the caller's
   tenant.
3. Test: as acme, `similar runbooks/stuck-jobs.md#escalate -k 100`, then
   look for Hooli's rows.
4. What happened: Hooli's rows came back at ranks 3, 4, 17 and 27; rank 27
   holds Hooli's bridge code, HOOLI-BRIDGE-4471. The ordinary search kept
   to acme. Raw output: retain the similar -k 100 output as evidence/r1-before.txt.
5. Vulnerability: tenant isolation lived only in each query's WHERE clause.
   `similar()` filtered the row it started from and forgot the outer query,
   and the application's login could read every row. One forgotten filter
   exposed every tenant.
6. Mitigation: row-level security on `documents` for a `runway_tenant` role;
   every query runs in a transaction that switches to it and sets
   `app.tenant` from the verified identity; the application's login has no
   rights on the table itself. The buggy query was deliberately left
   unchanged: it now returns 20 rows, all acme's.
7. Regression: tests/test_rag_live.py: more-like-this and search never
   cross tenants, a query outside a tenant is refused, the tenant role
   without a tenant fails loudly, and a tenant can't write into another.
   With row-level security switched off, three of them fail.

Remaining: the tenant must come from the verified token. If the agent (Step
4) lets the model choose the tenant, this fix protects nothing.
~~~

## When another tenant grows

Isolation held. Now check the other half of retrieval: does every tenant still get *good* results when the table is shared with a much bigger one? Add a way to generate job history, about the runbooks' subjects or about something else:

<!-- edit: serve/src/serve/rag.py -->
~~~python
import os
import re
~~~
to:
~~~python
import os
import random
import re
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
class Embedder:
~~~
to:
~~~python
HISTORY = {
    # Work like the runbooks describe: what a big tenant on the same
    # platform runs all day.
    "runbooks": (
        [
            "nightly export orders {region}",
            "send invoice webhooks for {month}",
            "resize product images batch {n}",
            "rebuild search index shard {n}",
            "bulk submit {n} reindex jobs",
            "export customers to bucket {region}",
        ],
        [
            "",
            "",
            "timeout waiting for lock after 300 s",
            "worker lost: lease expired",
            "receiver answered 401 Unauthorized",
            "429 Too Many Requests",
            "receiver answered 410 Gone",
        ],
    ),
    # Work no runbook mentions.
    "other": (
        [
            "render video frames {n} to {m}",
            "train recommendation model epoch {n}",
            "compress application logs for {month}",
            "generate thumbnails for album {n}",
            "back up customer database to {region}",
        ],
        ["", "", "out of memory", "disk quota exceeded", "segmentation fault in encoder"],
    ),
}


def history(n: int, about: str, seed: int = 1) -> list[Chunk]:
    """n made-up jobs: a stand-in for a tenant with a long job history."""
    rnd = random.Random(seed)
    work, failures = HISTORY[about]
    jobs = []
    for i in range(n):
        description = rnd.choice(work).format(
            n=rnd.randint(1, 999),
            m=rnd.randint(1000, 9999),
            month=rnd.choice(["may", "june", "july"]),
            region=rnd.choice(["eu-west", "us-east", "ap-south"]),
        )
        failure = rnd.choice(failures)
        state = "failed" if failure else "completed"
        jobs.append(
            chunk_job(
                {
                    "id": 100000 + i,
                    "author": "svc-batch",
                    "state": state,
                    "description": description,
                    "failure_reason": failure,
                }
            )
        )
    return jobs


class Embedder:
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
    s.add_argument("directory", type=Path)
    s = sub.add_parser("search")
~~~
to:
~~~python
    s.add_argument("directory", type=Path)
    s = sub.add_parser("history", help="add n made-up jobs to the tenant")
    s.add_argument("n", type=int)
    s.add_argument("--about", choices=sorted(HISTORY), default="other")
    s = sub.add_parser("search")
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
        if args.command == "index":
            chunks = load_corpus(args.directory)
~~~
to:
~~~python
        if args.command in ("index", "history"):
            if args.command == "index":
                chunks = load_corpus(args.directory)
            else:
                chunks = history(args.n, args.about)
~~~

<!-- edit: serve/tests/test_rag.py -->
~~~python
from serve.rag import chunk_job, chunk_runbook, first_hit, literal, pack, summarise
~~~
to:
~~~python
from serve.rag import chunk_job, chunk_runbook, first_hit, history, literal, pack, summarise
~~~

<!-- edit: serve/tests/test_rag.py -->
~~~python
    assert s == {"questions": 4, "hit@1": 0.25, "hit@3": 0.5, "mrr": (1 + 0.5 + 0.25) / 4}
~~~
to:
~~~python
    assert s == {"questions": 4, "hit@1": 0.25, "hit@3": 0.5, "mrr": (1 + 0.5 + 0.25) / 4}


def test_history_is_repeatable_and_on_topic():
    a, b = history(50, "runbooks"), history(50, "runbooks")
    assert a == b and len({c.source for c in a}) == 50
    assert all(c.author == "svc-batch" for c in a)
    assert not any("export" in c.body for c in history(50, "other"))
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_rag.py -->

Give a big tenant, bigco, 5,000 jobs about the same work your runbooks describe: on a shared platform, the big customer runs the same kinds of jobs. Give Acme 500 jobs of its own, about unrelated work, so that it's mid-sized. Then make PostgreSQL refresh its statistics, as autovacuum soon would on its own, and score Acme again:

~~~bash
rag --tenant bigco history 5000 --about runbooks
rag --tenant acme history 500 --about other
docker compose -f experiments/rag/compose.yaml exec -T db psql -U postgres -d rag -c "ANALYZE documents"
rag --tenant acme eval experiments/rag/eval.jsonl
~~~

~~~text
5000 chunks in 56.4 s
500 chunks in 5.4 s
ANALYZE
~~~

~~~text
 -  a job has said running for twenty minutes and the worker is gone
 -  why would a worker vanish while it holds a job?
 -  should I cancel a stuck job?
 -  lots of jobs are stuck at the same time, who do I call?
 1  when does the orders export run?
 -  export failed because something held a lock
 -  the downstream load is missing orders after a big export
 -  receiver rejects our signature
 -  how long do we keep retrying a webhook?
 -  a customer endpoint returned gone
 -  how many jobs can we submit per minute?
 -  our client keeps getting throttled, what should it do?
 -  can support increase our quota during an outage?
 -  which job failed with a lost lease?
 -  the reindex submission was refused
 -  what time is the reporting query finished?
{"questions": 16, "hit@1": 0.062, "hit@3": 0.062, "mrr": 0.062}
~~~

From 0.938 to 0.062. Every runbook is still in the table, untouched. And a search doesn't return worse answers: it returns **nothing**, with no error:

~~~bash
rag --tenant acme search "should I cancel a stuck job?" -k 5
~~~

It prints no rows at all.

Ask PostgreSQL how it runs the search:

<!-- file: experiments/rag/explain.sql -->
~~~sql
BEGIN;
SET LOCAL ROLE runway_tenant;
SELECT set_config('app.tenant', 'acme', true);
EXPLAIN (COSTS OFF) SELECT source FROM documents WHERE tenant = 'acme'
ORDER BY embedding <=> (SELECT embedding FROM documents WHERE source = 'job/4190') LIMIT 5;
COMMIT;
~~~

~~~bash
docker compose -f experiments/rag/compose.yaml exec -T db psql -U postgres -d rag < experiments/rag/explain.sql
~~~


~~~text
                                     QUERY PLAN
-------------------------------------------------------------------------------------
 Limit
   InitPlan 1
     ->  Index Scan using documents_tenant_source_key on documents documents_1
           Index Cond: ((tenant = current_tenant()) AND (source = 'job/4190'::text))
   ->  Result
         One-Time Filter: (current_tenant() = 'acme'::text)
         ->  Index Scan using documents_embedding on documents
               Order By: (embedding <=> (InitPlan 1).col1)
               Filter: (tenant = 'acme'::text)
(9 rows)
~~~

Read it from the inside out. `Index Scan using documents_embedding` is the HNSW index, walking the graph towards the question, through **every tenant's** vectors. `Filter: (tenant = 'acme')` throws away the rows that aren't Acme's, *afterwards*. And row-level security adds the same condition again.

HNSW doesn't return the whole table in order. By default it collects about 40 candidates (`hnsw.ef_search`) and stops. bigco's 5,000 jobs are about the very subjects Acme asks about, so all 40 candidates near an Acme question are bigco's. The filter removes all 40, and nothing is left. No error, no warning: an empty list, which the agent will take to mean "the runbooks say nothing about this".

Why did Acme's search work before? With 21 rows, the planner found Acme's rows through the `(tenant, source)` index and sorted them exactly. With 521 rows in a table of 5,500, it decided the HNSW index was cheaper. The choice comes from table statistics, so the failure depends on them. Acme was starved once in a reference run while it still had only 21 rows: the statistics were stale, just after bigco's rows arrived. A test that passed yesterday says little here.

Is this a security problem? Nobody read anything they shouldn't. But one tenant's data changed what another tenant's queries return, without either doing anything wrong, and the result is an assistant that confidently answers without its runbooks (LLM09, misinformation). Add it to the threat model:

<!-- edit: docs/security/ai-threat-model.md -->
~~~markdown
| A15 | An action can't be traced to a user, a request and a reason | Repudiation | LLM06 | Every tool call audited with user, tenant, request and arguments | 4, 5 |
~~~
to:
~~~markdown
| A15 | An action can't be traced to a user, a request and a reason | Repudiation | LLM06 | Every tool call audited with user, tenant, request and arguments | 4, 5 |
| A16 | Another tenant's data makes a tenant's search come back short or empty | Denial of service | LLM08, LLM09 | No approximate index shared between tenants; exact search per tenant | 3 |
~~~

Threat models change when you learn something. This row wasn't in Step 1 because nobody had measured it yet.

## Fix it: search one tenant exactly

The [pgvector documentation](https://github.com/pgvector/pgvector#filtering) describes post-scan filtering and iterative scans. Its [multitenancy guidance](https://github.com/pgvector/pgvector#multitenancy) recommends separate partitions or tables for isolation. The obvious repairs keep the shared index and search harder. In the reference run, with the same data plus 1,750 more rows, they behaved like this:

| Change | Rows (of 10) | Found of the exact top 10 | hit@1 | Median |
|---|---|---|---|---|
| Exact search (the reference) | 10 | 1.00 | 0.94 | 1.6 ms |
| Default HNSW | 1.25 | 0.12 | 0.25 | 1.6 ms |
| `hnsw.iterative_scan = relaxed_order` | 10 | 0.85 | 0.62 | 10.7 ms |
| `hnsw.iterative_scan = strict_order` | 10 | 0.52 | 0.38 | 11.0 ms |
| `hnsw.ef_search = 100` | 10 | 1.00 | 0.94 | 1.5 ms |

The last row looks like a win, and isn't one. Check its plan: with `ef_search` at 100, the planner estimated the HNSW scan as more expensive and switched to an exact sort. It wasn't HNSW doing better; it was HNSW not being used. Pgvector 0.8's iterative scans really stay on the index and keep going until enough rows survive the filter, but they still miss true neighbours, at seven times the cost.

Step back. Every search is for **one** tenant; here Acme's rows are a small slice of the table. An exact scan scores every visible vector and avoids approximate-neighbour misses. On this lab's small tenant datasets it is cheap; exact vector ranking still does not guarantee relevance. Drop the shared index:

<!-- file: experiments/rag/exact.sql -->
~~~sql
-- The fix for finding R2: no approximate index shared between tenants.
-- An HNSW index ranks every tenant's rows together; row-level security
-- removes the other tenants' rows only afterwards, so a mid-sized tenant
-- can get back fewer rows than it asked for, or none. Every search is
-- for one tenant, so search that tenant's rows exactly instead.
-- Run as the superuser:
--   docker compose -f experiments/rag/compose.yaml exec -T db \
--     psql -U postgres -d rag -v ON_ERROR_STOP=1 < experiments/rag/exact.sql
DROP INDEX documents_embedding;
~~~

~~~bash
docker compose -f experiments/rag/compose.yaml exec -T db \
  psql -U postgres -d rag -v ON_ERROR_STOP=1 < experiments/rag/exact.sql
docker compose -f experiments/rag/compose.yaml exec -T db psql -U postgres -d rag < experiments/rag/explain.sql
rag --tenant acme eval experiments/rag/eval.jsonl
~~~

~~~text
                                     QUERY PLAN
-------------------------------------------------------------------------------------
 Limit
   InitPlan 1
     ->  Index Scan using documents_tenant_source_key on documents documents_1
           Index Cond: ((tenant = current_tenant()) AND (source = 'job/4190'::text))
   ->  Sort
         Sort Key: ((documents.embedding <=> (InitPlan 1).col1))
         ->  Result
               One-Time Filter: (current_tenant() = 'acme'::text)
               ->  Bitmap Heap Scan on documents
                     Recheck Cond: (tenant = 'acme'::text)
                     ->  Bitmap Index Scan on documents_tenant_source_key
                           Index Cond: (tenant = 'acme'::text)
(12 rows)
~~~

~~~text
 1  a job has said running for twenty minutes and the worker is gone
 1  why would a worker vanish while it holds a job?
 1  should I cancel a stuck job?
 1  lots of jobs are stuck at the same time, who do I call?
 1  when does the orders export run?
 1  export failed because something held a lock
 1  the downstream load is missing orders after a big export
 1  receiver rejects our signature
 1  how long do we keep retrying a webhook?
 -  a customer endpoint returned gone
 1  how many jobs can we submit per minute?
 1  our client keeps getting throttled, what should it do?
 1  can support increase our quota during an outage?
 1  which job failed with a lost lease?
 1  the reindex submission was refused
 1  what time is the reporting query finished?
{"questions": 16, "hit@1": 0.938, "hit@3": 0.938, "mrr": 0.938}
~~~

The plan now finds Acme's rows through the tenant index, then sorts those by distance. Quality is back. One question still misses ("a customer endpoint returned gone"): Acme's own 500 jobs crowd it out of the top 10. That's ranking, not isolation, and it's worth knowing that a tenant's own noisy history costs it quality.

What does exactness cost? In the historical capture, timing 48 searches per tenant with `\timing` in psql:

acme (521 rows)    48 exact searches: median 0.86 ms, p90 1.04 ms
bigco (5000 rows)  48 exact searches: median 5.58 ms, p90 6.74 ms

Under a millisecond for Acme. bigco's 5.6 ms is a sequential scan, because bigco is most of the table. The cost grows with the tenant's size: a tenant with a few hundred thousand chunks would need an approximate index. Give that tenant **its own** index, on its own partition of the table, so that an approximate search never ranks two tenants' rows together.

## Keep it

Whether an HNSW index starves a tenant depends on statistics and sizes, so a test that loads data and hopes for the bad plan would be flaky. Test the design instead:

<!-- edit: serve/tests/test_rag_live.py -->
~~~python
@live
def test_a_tenant_cannot_write_into_another(two_tenants):
    conn, a, b = two_tenants
    with pytest.raises(psycopg.errors.InsufficientPrivilege, match="row-level security"):
        with as_tenant(conn, a):
            conn.execute(
                "INSERT INTO documents (tenant, source, author, body, model, embedding)"
                " VALUES (%s, 'doc/9', 'x', 'planted', 'm', %s::vector)",
                (b, "[" + ",".join(["0"] * 383 + ["1"]) + "]"),
            )
~~~
to:
~~~python
@live
def test_a_tenant_cannot_write_into_another(two_tenants):
    conn, a, b = two_tenants
    with pytest.raises(psycopg.errors.InsufficientPrivilege, match="row-level security"):
        with as_tenant(conn, a):
            conn.execute(
                "INSERT INTO documents (tenant, source, author, body, model, embedding)"
                " VALUES (%s, 'doc/9', 'x', 'planted', 'm', %s::vector)",
                (b, "[" + ",".join(["0"] * 383 + ["1"]) + "]"),
            )


@live
def test_no_approximate_index_spans_tenants(two_tenants):
    # R2: an HNSW or IVFFlat index over every tenant's rows returns other
    # tenants' neighbours, which row-level security then throws away, so a
    # tenant can get fewer rows than it asked for, or none. Whether it
    # happens depends on table statistics, so test the design, not luck.
    conn, _, _ = two_tenants
    shared = conn.execute(
        "SELECT indexname FROM pg_indexes"
        " WHERE tablename = 'documents' AND indexdef ~* 'using (hnsw|ivfflat)'"
    ).fetchall()
    assert shared == []
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_rag.py tests/test_rag_live.py -->

Against the lab database with the index still present, it failed; after `exact.sql`, all six live tests pass.

<!-- file: docs/security/r2-shared-ann-index.md -->
~~~markdown
# R2: a shared approximate index silently empties a tenant's search

Evidence class: live, against the lab database and embedding model.
Related threats: A7, A16. Preconditions: one big tenant writing about the
same things; the victim tenant mid-sized (hundreds of rows).

1. Threat: retrieval for one tenant returns nothing, or the wrong things,
   because of another tenant's data, and the agent answers without context.
2. Security assumption: a tenant's search result depends only on that
   tenant's documents.
3. Test: add 5,000 jobs for bigco about the same work as the runbooks, and
   500 unrelated jobs for acme; ANALYZE; run acme's 16 evaluation questions.
4. What happened: hit@1 fell from 0.938 to 0.062. A search printed no rows
   at all, and no error. EXPLAIN shows an HNSW index scan with the tenant
   as a filter. Raw output: retain the evaluation output as evidence/r2-before.txt.
5. Vulnerability: the HNSW index ranks every tenant's rows together and
   returns about 40 candidates (hnsw.ef_search); row-level security then
   drops the other tenants' rows. Small tenants were safe only because the
   planner chose an exact plan for them; whether it does depends on table
   statistics, so the failure comes and goes.
6. Mitigation: no approximate index shared between tenants. Each search is
   an exact scan of one tenant's rows: median 0.86 ms for 521 rows, 5.6 ms
   for 5,000. A tenant too big for that gets its own partition, with its own
   index. pgvector 0.8's iterative scans were tried in an earlier run (the
   same data plus 1,750 rows): they stopped the empty results, but found
   only 0.85 of the exact top 10, at 11 ms instead of 1.6.
7. Regression: test_no_approximate_index_spans_tenants fails while an HNSW
   or IVFFlat index covers `documents`.

Remaining: one question still misses after the fix: acme's own unrelated
history crowds it out of the top 10. That is ranking quality, not
isolation, and the evaluation set is small (16 questions written by the
same person as the runbooks).
~~~

## Check missing sources, bounds and transaction reuse

Before the agent can call retrieval, tighten three contracts. A missing source must return no candidates: the scalar subquery above produces NULL distances, which otherwise lets unrelated rows through. Use a seed relation that is empty when the source is absent, and restore the explicit tenant predicate in the outer query. Keep a separate regression that deliberately omits every filter to test RLS itself.

A tenant scope must own the outer transaction. If it ran in a savepoint inside somebody else's transaction, SET LOCAL could survive until that outer transaction ended. Require an idle autocommit connection and test the same connection after both commit and rollback. Bound query duration and result count; reject malformed embedding responses and vectors before SQL.

The chunker now refuses a sentence or heading too long for its character budget. This is a character bound, not a tokenizer bound: the model's own context limit still applies. This teaching importer handles the supplied short English corpus; a general importer must split by the selected tokenizer and check token lengths before embedding.

<!-- edit: serve/src/serve/rag.py -->
~~~python
import json
import os
~~~

to:

~~~python
import json
import math
import os
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
import psycopg
~~~

to:

~~~python
import psycopg
from psycopg.pq import TransactionStatus
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
def pack(sentences: list[str], limit: int) -> list[str]:
    """Join sentences into pieces of at most `limit` characters, never splitting one."""
    pieces, current = [], ""
    for s in sentences:
        if current and len(current) + 1 + len(s) > limit:
            pieces.append(current)
            current = s
        else:
            current = f"{current} {s}".strip()
    if current:
        pieces.append(current)
    return pieces
~~~

to:

~~~python
def pack(sentences: list[str], limit: int) -> list[str]:
    """Join sentences without splitting them; reject an oversized sentence."""
    if limit < 1 or any(len(s) > limit for s in sentences):
        raise ValueError("sentence or heading exceeds chunk limit")
    pieces, current = [], ""
    for s in sentences:
        if current and len(current) + 1 + len(s) > limit:
            pieces.append(current)
            current = s
        else:
            current = f"{current} {s}".strip()
    if current:
        pieces.append(current)
    return pieces
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
class Embedder:
    """Client for an OpenAI-style /v1/embeddings endpoint (llama.cpp's server)."""

    def __init__(self, url: str, batch: int = 32, timeout: float = 30) -> None:
        self.url, self.batch, self.timeout = url.rstrip("/"), batch, timeout

    def __call__(self, texts: list[str]) -> list[list[float]]:
        vectors = []
        for i in range(0, len(texts), self.batch):
            body = json.dumps({"input": texts[i : i + self.batch]}).encode()
            request = urllib.request.Request(
                self.url + "/v1/embeddings", body, {"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                data = json.load(response)["data"]
            vectors += [d["embedding"] for d in sorted(data, key=lambda d: d["index"])]
        if len(vectors) != len(texts) or any(len(v) != DIM for v in vectors):
            raise ValueError(f"expected {len(texts)} vectors of {DIM} dimensions")
        return vectors
~~~

to:

~~~python
class Embedder:
    """Client for an OpenAI-style /v1/embeddings endpoint (llama.cpp's server)."""

    def __init__(self, url: str, batch: int = 32, timeout: float = 30) -> None:
        if not 1 <= batch <= 32 or not 0 < timeout <= 30:
            raise ValueError("embedding batch or timeout")
        self.url, self.batch, self.timeout = url.rstrip("/"), batch, timeout

    def __call__(self, texts: list[str]) -> list[list[float]]:
        if any(not text.strip() or len(text) > MAX_CHARS for text in texts):
            raise ValueError("embedding text bound")
        vectors = []
        for i in range(0, len(texts), self.batch):
            body = json.dumps({"input": texts[i : i + self.batch]}).encode()
            request = urllib.request.Request(
                self.url + "/v1/embeddings", body, {"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read((1 << 20) + 1)
            if len(raw) > 1 << 20:
                raise ValueError("embedding response too large")
            data = json.loads(raw)["data"]
            count = min(self.batch, len(texts) - i)
            if sorted(d["index"] for d in data) != list(range(count)):
                raise ValueError("embedding response indices")
            vectors += [d["embedding"] for d in sorted(data, key=lambda d: d["index"])]
        if len(vectors) != len(texts) or any(len(v) != DIM for v in vectors):
            raise ValueError(f"expected {len(texts)} vectors of {DIM} dimensions")
        for vector in vectors:
            literal(vector)
        return vectors
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
def literal(vector: list[float]) -> str:
    """pgvector's text form, '[0.1,0.2,...]'. Passed as a parameter, never pasted into SQL."""
    return "[" + ",".join(f"{x:.6f}" for x in vector) + "]"
~~~

to:

~~~python
def literal(vector: list[float]) -> str:
    """pgvector's text form, '[0.1,0.2,...]'. Passed as a parameter, never pasted into SQL."""
    if not vector or not all(math.isfinite(x) for x in vector) or not any(vector):
        raise ValueError("vector must be finite and nonzero")
    return "[" + ",".join(f"{x:.6f}" for x in vector) + "]"
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
def as_tenant(conn, tenant: str):
    """One transaction, acting for one tenant. PostgreSQL's row-level security
    then hides every other tenant's rows, whatever the query inside says."""
    if not tenant:
        raise ValueError("no tenant: refusing to query")
    with conn.transaction():
        conn.execute("SET LOCAL ROLE runway_tenant")
        conn.execute("SELECT set_config('app.tenant', %s, true)", (tenant,))
        yield conn
~~~

to:

~~~python
def as_tenant(conn, tenant: str):
    """One transaction, acting for one tenant. PostgreSQL's row-level security
    then hides every other tenant's rows, whatever the query inside says."""
    if not tenant:
        raise ValueError("no tenant: refusing to query")
    if not conn.autocommit or conn.info.transaction_status != TransactionStatus.IDLE:
        raise ValueError("tenant scope needs an idle autocommit connection")
    with conn.transaction():
        conn.execute("SET LOCAL statement_timeout = '2s'")
        conn.execute("SET LOCAL ROLE runway_tenant")
        conn.execute("SELECT set_config('app.tenant', %s, true)", (tenant,))
        yield conn
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
def search(conn, tenant: str, vector: list[float], k: int = 5) -> list[tuple]:
    """The k nearest chunks by cosine distance: (source, author, body, distance)."""
    with as_tenant(conn, tenant):
        return conn.execute(
            """SELECT source, author, body, embedding <=> %s::vector AS distance
               FROM documents WHERE tenant = %s
               ORDER BY embedding <=> %s::vector LIMIT %s""",
            (literal(vector), tenant, literal(vector), k),
        ).fetchall()
~~~

to:

~~~python
def search(conn, tenant: str, vector: list[float], k: int = 5) -> list[tuple]:
    """The k nearest chunks by cosine distance: (source, author, body, distance)."""
    if not 1 <= k <= 100 or len(vector) != DIM:
        raise ValueError("search bounds")
    with as_tenant(conn, tenant):
        return conn.execute(
            """SELECT source, author, body, embedding <=> %s::vector AS distance
               FROM documents WHERE tenant = %s
               ORDER BY embedding <=> %s::vector LIMIT %s""",
            (literal(vector), tenant, literal(vector), k),
        ).fetchall()
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
def similar(conn, tenant: str, source: str, k: int = 5) -> list[tuple]:
    """ "More like this": the chunks nearest to one the user is reading."""
    with as_tenant(conn, tenant):
        return conn.execute(
            """SELECT source, author, body,
                      embedding <=> (SELECT embedding FROM documents
                                     WHERE tenant = %s AND source = %s) AS distance
               FROM documents WHERE source <> %s
               ORDER BY distance LIMIT %s""",
            (tenant, source, source, k),
        ).fetchall()
~~~

to:

~~~python
def similar(conn, tenant: str, source: str, k: int = 5) -> list[tuple]:
    """ "More like this": the chunks nearest to one the user is reading."""
    if not 1 <= k <= 100:
        raise ValueError("search bounds")
    with as_tenant(conn, tenant):
        return conn.execute(
            """WITH seed AS (SELECT embedding FROM documents WHERE tenant = %s AND source = %s)
               SELECT d.source, d.author, d.body, d.embedding <=> seed.embedding AS distance
               FROM documents d CROSS JOIN seed
               WHERE d.tenant = %s AND d.source <> %s
               ORDER BY distance LIMIT %s""",
            (tenant, source, tenant, source, k),
        ).fetchall()
~~~

<!-- edit: serve/src/serve/rag.py -->
~~~python
def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="serve.rag")
    p.add_argument("--db", default=os.environ.get("RAG_DATABASE_URL", ""))
    p.add_argument("--embed", default=os.environ.get("RAG_EMBED_URL", "http://127.0.0.1:18090"))
    p.add_argument("--tenant", required=True, help="in the lab, you play the verified identity")
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("index", help="chunk, embed and store a tenant's corpus")
    s.add_argument("directory", type=Path)
    s = sub.add_parser("history", help="add n made-up jobs to the tenant")
    s.add_argument("n", type=int)
    s.add_argument("--about", choices=sorted(HISTORY), default="other")
    s = sub.add_parser("search")
    s.add_argument("question")
    s.add_argument("-k", type=int, default=5)
    s = sub.add_parser("similar")
    s.add_argument("source")
    s.add_argument("-k", type=int, default=5)
    s = sub.add_parser("eval", help="score retrieval against questions with known answers")
    s.add_argument("questions", type=Path)
    s.add_argument("-k", type=int, default=3)
    args = p.parse_args(argv)

    embed = Embedder(args.embed)
    with psycopg.connect(args.db, autocommit=True) as conn:
        if args.command in ("index", "history"):
            if args.command == "index":
                chunks = load_corpus(args.directory)
            else:
                chunks = history(args.n, args.about)
            started = time.monotonic()
            vectors = embed([c.body for c in chunks])
            add(conn, args.tenant, chunks, vectors)
            print(f"{len(chunks)} chunks in {time.monotonic() - started:.1f} s")
        elif args.command == "search":
            show(search(conn, args.tenant, embed([args.question])[0], args.k))
        elif args.command == "similar":
            show(similar(conn, args.tenant, args.source, args.k))
        elif args.command == "eval":
            rows = [json.loads(line) for line in args.questions.read_text().splitlines() if line]
            ranks = []
            for row, vector in zip(rows, embed([r["q"] for r in rows]), strict=True):
                found = [r[0] for r in search(conn, args.tenant, vector, 10)]
                ranks.append(first_hit(found, row["want"]))
                print(f"{ranks[-1] or '-':>2}  {row['q']}")
            print(json.dumps({k: round(v, 3) for k, v in summarise(ranks, args.k).items()}))
    return 0
~~~

to:

~~~python
def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="serve.rag")
    p.add_argument("--db", default=os.environ.get("RAG_DATABASE_URL", ""))
    p.add_argument("--embed", default=os.environ.get("RAG_EMBED_URL", "http://127.0.0.1:18090"))
    p.add_argument("--tenant", required=True, help="in the lab, you play the verified identity")
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("index", help="chunk, embed and store a tenant's corpus")
    s.add_argument("directory", type=Path)
    s = sub.add_parser("history", help="add n made-up jobs to the tenant")
    s.add_argument("n", type=int)
    s.add_argument("--about", choices=sorted(HISTORY), default="other")
    s = sub.add_parser("search")
    s.add_argument("question")
    s.add_argument("-k", type=int, default=5)
    s = sub.add_parser("similar")
    s.add_argument("source")
    s.add_argument("-k", type=int, default=5)
    s = sub.add_parser("eval", help="score retrieval against questions with known answers")
    s.add_argument("questions", type=Path)
    s.add_argument("-k", type=int, default=3)
    args = p.parse_args(argv)
    if args.command == "history" and not 0 <= args.n <= 10000:
        p.error("history must contain 0..10000 jobs")

    embed = Embedder(args.embed)
    with psycopg.connect(args.db, autocommit=True, connect_timeout=3) as conn:
        if args.command in ("index", "history"):
            if args.command == "index":
                chunks = load_corpus(args.directory)
            else:
                chunks = history(args.n, args.about)
            started = time.monotonic()
            vectors = embed([c.body for c in chunks])
            add(conn, args.tenant, chunks, vectors)
            print(f"{len(chunks)} chunks in {time.monotonic() - started:.1f} s")
        elif args.command == "search":
            show(search(conn, args.tenant, embed([args.question])[0], args.k))
        elif args.command == "similar":
            show(similar(conn, args.tenant, args.source, args.k))
        elif args.command == "eval":
            rows = [json.loads(line) for line in args.questions.read_text().splitlines() if line]
            ranks = []
            for row, vector in zip(rows, embed([r["q"] for r in rows]), strict=True):
                found = [r[0] for r in search(conn, args.tenant, vector, 10)]
                ranks.append(first_hit(found, row["want"]))
                print(f"{ranks[-1] or '-':>2}  {row['q']}")
            print(json.dumps({k: round(v, 3) for k, v in summarise(ranks, args.k).items()}))
    return 0
~~~

<!-- edit: serve/tests/test_rag.py -->
~~~python
from serve.rag import chunk_job, chunk_runbook, first_hit, history, literal, pack, summarise
~~~

to:

~~~python
import io
import json

import pytest

from serve.rag import (
    DIM,
    Embedder,
    chunk_job,
    chunk_runbook,
    first_hit,
    history,
    literal,
    pack,
    summarise,
)
~~~

<!-- edit: serve/tests/test_rag.py -->
~~~python
def test_pack_never_splits_a_sentence():
    assert pack(["aaaa.", "bbbb.", "cccc."], limit=11) == ["aaaa. bbbb.", "cccc."]
    assert pack(["a sentence longer than the limit."], limit=5) == [
        "a sentence longer than the limit."
    ]
~~~

to:

~~~python
def test_pack_never_splits_a_sentence():
    assert pack(["aaaa.", "bbbb.", "cccc."], limit=11) == ["aaaa. bbbb.", "cccc."]
    with pytest.raises(ValueError, match="chunk limit"):
        pack(["a sentence longer than the limit."], limit=5)
~~~

<!-- append: serve/tests/test_rag.py -->
~~~python

@pytest.mark.parametrize("vector", [[], [0.0], [float("nan")], [float("inf")]])
def test_invalid_vector_cannot_cross_the_boundary(vector):
    with pytest.raises(ValueError, match="finite and nonzero"):
        literal(vector)


def test_embedding_adapter_preserves_response_order(monkeypatch):
    rows = [{"index": 1, "embedding": [0.5] * DIM}, {"index": 0, "embedding": [1.0] * DIM}]
    monkeypatch.setattr(
        "urllib.request.urlopen", lambda *a, **kw: io.BytesIO(json.dumps({"data": rows}).encode())
    )
    assert Embedder("http://unused")(["first", "second"])[0] == [1.0] * DIM


@pytest.mark.parametrize(
    "rows",
    [
        [{"index": 1, "embedding": [1.0] * DIM}],
        [{"index": 0, "embedding": [1.0] * 3}],
        [{"index": 0, "embedding": [0.0] * DIM}],
        [{"index": 0, "embedding": [float("nan")] * DIM}],
    ],
)
def test_embedding_adapter_rejects_invalid_response(monkeypatch, rows):
    monkeypatch.setattr(
        "urllib.request.urlopen", lambda *a, **kw: io.BytesIO(json.dumps({"data": rows}).encode())
    )
    with pytest.raises(ValueError):
        Embedder("http://unused")(["hello"])


def test_embedding_input_and_response_are_bounded(monkeypatch):
    with pytest.raises(ValueError):
        Embedder("http://unused", batch=0)
    with pytest.raises(ValueError, match="text bound"):
        Embedder("http://unused")(["x" * 1201])
    monkeypatch.setattr(
        "urllib.request.urlopen", lambda *a, **kw: io.BytesIO(b"x" * ((1 << 20) + 1))
    )
    with pytest.raises(ValueError, match="response too large"):
        Embedder("http://unused")(["hello"])
~~~

<!-- edit: serve/tests/test_rag_live.py -->
~~~python
def test_no_approximate_index_spans_tenants(two_tenants):
    # R2: an HNSW or IVFFlat index over every tenant's rows returns other
    # tenants' neighbours, which row-level security then throws away, so a
    # tenant can get fewer rows than it asked for, or none. Whether it
    # happens depends on table statistics, so test the design, not luck.
    conn, _, _ = two_tenants
    shared = conn.execute(
        "SELECT indexname FROM pg_indexes"
        " WHERE tablename = 'documents' AND indexdef ~* 'using (hnsw|ivfflat)'"
    ).fetchall()
    assert shared == []
~~~

to:

~~~python
def test_no_approximate_index_spans_tenants(two_tenants):
    # R2: an HNSW or IVFFlat index over every tenant's rows returns other
    # tenants' neighbours, which row-level security then throws away, so a
    # tenant can get fewer rows than it asked for, or none. Whether it
    # happens depends on table statistics, so test the design, not luck.
    conn, _, _ = two_tenants
    shared = conn.execute(
        "SELECT indexname FROM pg_indexes"
        " WHERE tablename = 'documents' AND schemaname = current_schema()"
        " AND indexdef ~* 'using (hnsw|ivfflat)'"
    ).fetchall()
    assert shared == []
~~~

<!-- append: serve/tests/test_rag_live.py -->
~~~python

@live
def test_rls_even_when_the_query_has_no_filter(two_tenants):
    conn, a, b = two_tenants
    with as_tenant(conn, a):
        assert {r[0] for r in conn.execute("SELECT tenant FROM documents")} == {a}
        assert conn.execute("SELECT current_user").fetchone() == ("runway_tenant",)
        assert conn.execute(
            "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
        ).fetchone() == (False, False)
        assert conn.execute(
            "SELECT tableowner = current_user FROM pg_tables WHERE tablename = 'documents'"
            " AND schemaname = current_schema()"
        ).fetchone() == (False,)


@live
def test_scope_resets_on_same_connection_after_commit_and_rollback(two_tenants):
    conn, a, b = two_tenants
    for abort in (False, True):
        try:
            with as_tenant(conn, a):
                if abort:
                    raise RuntimeError("deliberate rollback")
        except RuntimeError:
            pass
        assert conn.execute("SELECT current_user").fetchone() == ("rag_app",)
        assert conn.execute(
            "SELECT nullif(current_setting('app.tenant', true), '')"
        ).fetchone() == (None,)
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("SELECT * FROM documents")
        assert [r[2] for r in search(conn, b, unit(0))] == ["B's secret"]
    with conn.transaction():
        with pytest.raises(ValueError, match="idle autocommit"):
            search(conn, a, unit(0))


@live
def test_missing_foreign_and_injection_shaped_sources(two_tenants):
    conn, a, b = two_tenants
    assert similar(conn, a, "doc/7") == []
    assert similar(conn, a, "missing") == []
    assert similar(conn, a, "' OR true --") == []
    assert search(conn, "' OR true --", unit(0)) == []
    for k in (0, -1, 101):
        with pytest.raises(ValueError, match="search bounds"):
            search(conn, a, unit(0), k=k)
        with pytest.raises(ValueError, match="search bounds"):
            similar(conn, a, "doc/1", k=k)
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_rag.py tests/test_rag_live.py -->

Run the live file again with `RAG_DATABASE_URL` set. Confirm that the login and tenant role are non-superusers, the tenant role owns no table, a missing or foreign source returns no rows, SQL-shaped source and tenant strings remain data, and commit and rollback clear the tenant on the same connection. The CLI's tenant flag is a lab impersonation mechanism, not authentication. Any code with this database credential can select a tenant; RLS protects against missing filters, not a compromised application or arbitrary SQL execution.

The [retrieval evidence report](../evidence/retrieval/report.md) retains the new checks and the historical quality measurements. No generated answers, live JWT integration, calibrated no-answer threshold, or production ingestion are claimed here. Step 4 supplies the authenticated agent boundary.

**Break it:** recreate the index (`CREATE INDEX documents_embedding ON documents USING hnsw (embedding vector_cosine_ops);` as the superuser, then `ANALYZE documents`), score Acme, and watch hit@1 fall again and the live test fail. Then try the attack from the other side: as Hooli, ask `similar` for a source that exists only in Acme's runbooks. What comes back, and why?

**Explain it:** why did fixing `similar()`'s query matter less than enabling row-level security? Why does `as_tenant` use `SET LOCAL` instead of `SET`? Why is `INHERIT FALSE` on the grant to `rag_app`? Why did the R2 failure depend on table statistics, and what does that mean for testing it? When would you put an approximate index back, and on what?

**Done when:** both tenants are indexed; you have the evaluation baseline; you have reproduced R1 and R2, with saved evidence; `rls.sql` and `exact.sql` are applied; the unit tests pass and the live tests pass against your lab database; you have watched each regression test fail without its fix; and the missing-source and transaction-reuse checks pass; and both findings are written up. Step 4 puts an agent in front of this retrieval.

---
