# Phase 9 Step 3: retrieval assessment

This assessment separates historical lab captures, recovered from the author's
scratch directory, from fresh validation on 2026-11-14 Pacific time. The lesson
contains the code, fixtures and commands; this folder retains the observations.
The starting repository revision was `b077937`, with Step 2 already present as
uncommitted work. No changes have been committed during this assessment.

This capture predates the remaining agent steps. The [completion report](../completion/report.md) records the full fourteen-step lab; this assessment retains its original retrieval-specific results and replay count.

## Environment and scope

- PostgreSQL 17 with pgvector, image
  `pgvector/pgvector@sha256:b513c48566e4777cd3370451400000c78eda6a08131d68f4c31d4a76f27bd8fd`.
- CPU embedding service, image
  `ghcr.io/ggml-org/llama.cpp@sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b`,
  CLS pooling, four threads, context 2048.
- `bge-small-en-v1.5-q8_0.gguf`, SHA-256
  `f046db1dc724cf4f6f0a0c5917e922823b73eb1d27b8f9a9c2797f7866974804`.
  The local file's checksum was verified again. Upstream model:
  [BAAI](https://huggingface.co/BAAI/bge-small-en-v1.5); GGUF publisher:
  [ggml-org](https://huggingface.co/ggml-org/bge-small-en-v1.5-Q8_0-GGUF).
  The original download revision was not retained, so the checksum identifies
  the measured bytes; this is not a complete provenance attestation.
- Synthetic corpus: Acme has 21 chunks; Hooli has seven. Sixteen hand-written
  questions evaluate Acme's retrieval. The larger experiment adds 5,000
  deterministic synthetic jobs for bigco and 500 for Acme.
- Fresh validation used its own disposable database container on loopback and
  reused the existing local embedding service. Existing lab databases were
  not changed. Local fixture credentials are synthetic.

The CLI impersonates a tenant. It does not verify JWTs, connect to the live job
API, generate answers or invoke tools. The tests demonstrate database and
retrieval properties, not an end-to-end authenticated assistant.

## Historical captures

Files `01-up.txt` through `24-exact-latency.txt` retain the earlier lab run used
for the lesson's sample output. Local absolute paths were replaced with
`<scratch>` where necessary. The useful portion of the old permission-denied
traceback is inline in the lesson; that traceback was not copied here.

- R1: the initial `similar` query returned Hooli's synthetic bridge code to
  Acme. See [the attack](07-similar-all.txt). After RLS, the query returned
  only Acme's other 20 chunks; see [the fixed result](10-similar-fixed.txt).
- R2: after adding the larger tenants and refreshing statistics, hit@1 fell
  from 15/16 to 1/16 with the shared HNSW index. See
  [baseline](05-eval.txt), [HNSW](16-eval-hnsw.txt) and
  [exact search](21-eval-exact.txt). Exact search restored hit@1 to 15/16.
- [Iterative scan exploration](probe-iterative-settings.txt) used a different
  dataset size and is labelled separately in the guide. It must not be
  compared as if it were the same run. [Latency](24-exact-latency.txt) is a
  historical measurement, not a new performance benchmark.
- The old [RLS negative control](regression-without-rls.txt) and
  [index negative control](regression-r2-before.txt) are summaries from the
  earlier test version. Fresh tests below check the final code separately.

## Fresh validation

The new `new-*.json` files retain per-question rankings as well as aggregate
scores. Query plans are saved separately so the claimed HNSW path can be
checked instead of inferred from an empty response.

- [R1 before](new-r1-before.json): the deliberately weak query exposed the
  synthetic bridge code. [R1 after](new-r1-after.json): 20 Acme chunks,
  with no Hooli passage.
- [Small corpus](new-quality-small.json), [shared index](new-quality-shared-hnsw.json)
  and [exact scan](new-quality-exact.json) repeat the 16-question evaluation.
- [HNSW plan](new-plan-hnsw.txt) and [exact plan](new-plan-exact.txt)
  retain the actual optimizer choices.
- [Negative control](new-regression-without-rls.txt) disables RLS in the
  disposable database and requires the isolation assertions to fail. RLS is
  restored before the [final live suite](new-live-tests.txt).

Fresh results reproduced the historical ranking change exactly:

| Corpus and search | hit@1 | hit@3 | MRR (first ten results) |
|---|---|---|---|
| Acme 21 chunks; initial corpus | 15/16 | 16/16 | 0.9583 |
| Acme 521 chunks; bigco 5,000; shared HNSW | 1/16 | 1/16 | 0.0625 |
| Same larger corpus; exact search | 15/16 | 15/16 | 0.9375 |

The [new index negative control](new-regression-shared-index.txt) recreates
HNSW and requires the index-policy assertion to fail, then drops it again.
The [combined final retrieval suite](new-final-tests.txt) records the restored
state. The RLS negative control produced two expected failures; the index
negative control produced one expected failure.

The final code also checks unknown and foreign source IDs, SQL-shaped source
and tenant strings, result bounds, missing context, restricted role privileges,
and reuse of the same connection after commit and rollback. Tenant scopes
reject an already-open transaction rather than leaking SET LOCAL state through
an outer transaction. The tests deliberately query without a tenant filter to
exercise RLS independently of the application's explicit filter.

## Validation results

- Full guide replay, including the Phase 8 prerequisite: **142 extracted
  actions passed**. See [replay output](guide-replay.txt).
- Final retrieval tests: **17 offline and nine live tests passed**. The
  replayed retrieval module and both test files match the live-tested files
  byte for byte.
- Negative controls: **two expected RLS failures** and **one expected
  shared-index failure**; enforcement was restored afterward.
- Site build and internal-link checks passed. These verify rendering and
  navigation, not the live service behaviour.

The disposable validation container was removed after evidence capture;
existing embedding and database services were left running.

## Reproduce

From the repository root, replay all inline code and offline checks:

~~~bash
python3 scripts/check_guides.py --keep lessons/09-secure-ai-layer/TEACHING.md
~~~

In the retained scratch directory, follow Step 3's Docker setup, schema,
indexing, attack, RLS and exact-search commands in order. Run the live tests
against the resulting disposable lab:

~~~bash
cd serve
RAG_DATABASE_URL=postgres://rag_app:lab-app@127.0.0.1:15432/rag \
  uv run pytest -q tests/test_rag.py tests/test_rag_live.py
~~~

For a negative control, use only a disposable copy of this database. Disable
RLS on `documents` as its administrator, run
`tests/test_rag_live.py -k 'rls_even_when_the_query_has_no_filter or a_tenant_cannot_write_into_another'`
and require failures. Re-enable RLS and require the full suite to pass.
Recreate the shared HNSW index to watch the index-policy test fail, then drop
it again before finishing. Planner-dependent starvation is an observation to
record, not a deterministic assertion for every environment.

## Limits

Sixteen queries written by the corpus author are a regression set, not an
independent quality estimate. No no-answer threshold, generated-answer
faithfulness or production SLO is established. An exact vector search can
rank an irrelevant passage first. Character bounds do not establish token
bounds for arbitrary languages. The importer upserts fixtures and does not
synchronize deletions or verify author identities. RLS relies on trusted
application code choosing the tenant: possession of the shared database
credential or arbitrary SQL execution defeats that assumption. The role is
restricted, but schema owners and superusers remain trusted administrators.
