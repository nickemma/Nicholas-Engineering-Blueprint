# Phase 7: Evaluate utility, privacy, and usability

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: full code in `steps/`, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This self-study lesson tests whether local-first sharing helps the stated users enough to justify its latency, bandwidth, operational work, and privacy trade-offs. The main path is a reproducible systems experiment. A short, separate Python/AI sampler provides high-level career breadth without making AI a requirement of KESTREL.

## The goal

Another person should be able to run the same workload, reproduce the comparison, regenerate the measurements, and understand the limits. The centralized baseline must receive a fair comparison. A distributed design does not win by definition.

## Before you start

Finish Phases 0–6. Use the same synthetic or public dataset and query contract as the previous phase. If domain feedback is available, document who provided it and what question it informs. Do not recruit human participants or use sensitive data without the required consent and research-ethics process.

In `lessons/07-utility-evaluation`, create the experiment workspace:

~~~bash
mkdir -p practice/experiment/raw practice/experiment/plots
mkdir -p practice/cmd/experiment
cd practice
go mod init kestrel-phase7
~~~

Keep this workspace separate from the optional AI sampler and from Kestrel transfer work.

## 1. Turn a need into a testable question

Write one question in this form: “For [user] making [decision], does [local-first design] provide [useful result] within [freshness/latency goal] under [network condition], compared with [baseline]?”

Separate four things:

- observed user need;
- hypothesis about the system;
- workload used to test the hypothesis;
- result that would count against the hypothesis.

Example: “For a site operator checking weekly service capacity, can a locally computed aggregate provide a useful answer within one hour during a six-hour link outage, compared with a centralized query that cannot reach the site?” Replace the example only when your evidence supports a different question.

## 2. Define a fair baseline and measures

Build the simplest centralized baseline that answers the same query from the same synthetic records. Then compare it with local summaries plus the cross-site query path. Keep input records, query parameters, machine resources, and run duration comparable.

For the baseline, load the same site-a and site-b synthetic rows into one central table. Apply the minimum-group rule per site, then combine only approved category counts. This makes the central and local-first response semantics match: site-a capacity 12 and site-b capacity 20 combine to capacity 32; site-a access 9 is suppressed and site-b access 14 is released. For local-first, query each site's own store and combine only those approved summaries. Do not claim the two designs have identical privacy exposure; measuring that difference is part of the result.

There is an important limit in this training checkout: Phase 6's runnable harness stores both synthetic site IDs in one PostgreSQL instance to make policy and audit behavior testable. That harness can measure each site-ID query path and its failure behavior, but it cannot prove that two sites retain custody of separate databases. For the full architecture comparison, run the same manifest against the two separately configured site stores and cross-site combiner in your Kestrel implementation and against the central baseline. If your Kestrel implementation does not yet have two real site stores and a cross-site summary path, report the local harness measurements only and mark data-custody and multi-site availability as not measured; do not describe the harness as a federation result.

The Phase 6 fixture already contains the central baseline's synthetic rows. From Phase 7 practice, run this query through the disposable Phase 3 database; it computes the per-site suppression rule first, then combines released counts:

~~~bash
docker compose -f ../../03-durable-auditable-data/practice/compose.yaml exec db psql -U kestrel -d kestrel -c "WITH per_site AS (SELECT site_id, category, COUNT(*) AS n FROM synthetic_records WHERE site_id IN ('site-a', 'site-b') AND occurred_at >= DATE '2026-01-01' AND occurred_at < DATE '2026-02-01' GROUP BY site_id, category HAVING COUNT(*) >= 10) SELECT category, SUM(n) AS count FROM per_site GROUP BY category ORDER BY category;"
~~~

Expect `capacity 32` and `access 14`. The local-first equivalent is one approved response from each site's own API and a combiner that adds only returned groups, so it also reports capacity 32 and access 14. Compare that output to your Kestrel implementation only after verifying that its site databases are separate. The local SQL result alone is a centralized baseline, not proof of local-first custody.

Define before running:

| Measure | Operational definition |
|---|---|
| Utility | Does the output support the named decision, judged against a written rubric or domain feedback? |
| Freshness | Time between the newest source change and the summary that includes it. |
| Availability | Fraction of valid queries that return a valid answer during the stated window. |
| Latency | Time from request start to complete response; report p50 and p95. |
| Bandwidth | Bytes transferred for the workload, including protocol overhead you can measure. |
| Privacy exposure | Which fields and number of records cross the boundary; include query-combination risks. |
| Operator effort | Number of manual recovery steps and time needed to restore service. |

Do not combine these into one score unless you explain the weights and why they match the decision.

## 3. Make the experiment reproducible

Store a machine-readable manifest with code commit, dataset version, query mix, number of records, client concurrency, duration, network profile, random seed, and tool versions. Keep raw output immutable; write analysis code that derives summary tables from those raw files.

Save it as `practice/experiment/manifest.json` with these keys: `code_commit`, `dataset_version`, `target_sites`, `records_per_site`, `query_mix`, `requests_per_condition`, `concurrency`, `request_rate_per_second`, `request_timeout_ms`, `duration_seconds`, `conditions`, `repetitions`, `random_seed`, `tool_versions`, and `primary_paper_comparison`. Set `target_sites` to `site-a` and `site-b`. Record four run types: `normal`, `constrained`, `partition`, and `recovery`. For `constrained`, record Phase 5's 50 ms delay, 1% loss, and 1 Mbit/s rate on each veth end. Use 1,000 requests per site for normal/constrained repetitions and 100 per site for partition/recovery repetitions, 20 concurrent clients, a fixed 20 requests/second start rate, a 5-second request timeout, three repetitions, and a recorded seed. State why the outage samples are shorter: each request intentionally waits for the timeout. You may lower the request count while debugging, but mark those runs as debug output and do not use them in the final plots.

Write each request result as one JSON object per line in `practice/experiment/raw/<condition>-<site-id>-<repetition>.jsonl`. Include request ID, site ID, condition, request start time, elapsed milliseconds, HTTP status (0 on connection failure), error category, request bytes, response bytes, and a `summary_counts` map keyed by category. To measure freshness, insert one new synthetic marker row with its creation time recorded, then poll the approved summary until that row is included; freshness is the time from insertion to the first response containing it. Use a unique nonce for every request. Preserve timeout and failure rows instead of dropping them.

Implement the runner in `practice/cmd/experiment/main.go` with flags `-endpoint`, `-site-id`, `-condition`, `-repetition`, `-requests`, `-concurrency`, `-rate`, `-timeout`, `-seed`, `-ca-cert`, `-client-cert`, `-client-key`, and `-output`. Use Go's `net/http` client with the stated timeout and TLS client certificate. For every request, generate a new request ID and nonce; send a JSON body with the Phase 6 fields `request_id`, `site_id`, `purpose: "service-planning"`, `query_type: "count_by_category"`, `window_start`, `window_end`, `expires_at`, and `nonce`; parse every item in the returned `counts` array into `summary_counts`; and append one JSONL result even when the request fails. Construct the path as `/v1/sites/` plus the URL-escaped site ID plus `/summary`. Use the fixed synthetic window `2026-01-01` through `2026-02-01` so it includes the Phase 6 fixture rows. Set each request expiry to the current UTC time plus one minute. Use `crypto/rand` for unique nonces; use `-seed` only for reproducible workload selection. The `-rate` flag spaces request starts evenly; set it to `20/s` for formal runs. The runner reads `practice/experiment/manifest.json` by default and prints that path and its output filename at startup.

For network measurements, use the disposable veth pair from Phase 5, with TLS port 8443. Create the pair from Phase 7's practice directory:

First run `ip netns list` and confirm that `kestrel-net` is absent; if it remains from Phase 5, finish that phase's cleanup before creating it again.

~~~bash
sudo ip netns add kestrel-net
sudo ip link add veth-host type veth peer name veth-client
sudo ip link set veth-client netns kestrel-net
sudo ip addr add 10.203.0.1/24 dev veth-host
sudo ip link set veth-host up
sudo ip netns exec kestrel-net ip addr add 10.203.0.2/24 dev veth-client
sudo ip netns exec kestrel-net ip link set lo up
sudo ip netns exec kestrel-net ip link set veth-client up
~~~

In a second terminal, enter Phase 6 practice, start its database if needed, and start the API bound only to the host side of this pair:

~~~bash
cd lessons/06-safe-shared-queries/practice
export DATABASE_URL='postgres://kestrel:lesson-only@127.0.0.1:55432/kestrel?sslmode=disable'
docker compose -f ../../03-durable-auditable-data/practice/compose.yaml up -d --wait db
KESTREL_ENABLE_TEST_IDENTITY=1 LISTEN_ADDR=10.203.0.1:8443 go run ./cmd/siteapi
~~~

The Phase 6 server certificate includes `10.203.0.1` as an IP subject alternative name. Confirm reachability and mutual TLS from the namespace before running the Go workload:

~~~bash
sudo ip netns exec kestrel-net curl --cacert ../../06-safe-shared-queries/practice/certs/ca.crt --cert ../../06-safe-shared-queries/practice/certs/client.crt --key ../../06-safe-shared-queries/practice/certs/client.key https://10.203.0.1:8443/health
~~~

This path crosses the veth pair, so `tc netem` changes the measured client-to-API path. Keep the API process in the second terminal and the namespace alive across runs. From `lessons/07-utility-evaluation/practice`, compile the runner once with `mkdir -p bin && go build -o bin/experiment ./cmd/experiment`. From there, the normal-link command is:

~~~bash
sudo ip netns exec kestrel-net ./bin/experiment -endpoint https://10.203.0.1:8443 -site-id site-a -condition normal -repetition 1 -requests 1000 -concurrency 20 -rate 20/s -timeout 5s -seed 7 -ca-cert ../../06-safe-shared-queries/practice/certs/ca.crt -client-cert ../../06-safe-shared-queries/practice/certs/client.crt -client-key ../../06-safe-shared-queries/practice/certs/client.key -output experiment/raw/normal-site-a-1.jsonl
~~~

The namespace command runs as root to enter the namespace, so the output file is root-owned; after each run, return ownership to your account with `sudo chown "$(id -u):$(id -g)" experiment/raw/normal-site-a-1.jsonl` (substitute the actual output filename). The request handler must use the local test identity fixture described in Phase 6; this client-certificate experiment measures the local API/network path, not a production OIDC identity integration. The API listens only on the disposable veth address, not the host's other interfaces. For each repetition, run the same condition once with `-site-id site-a` and once with `-site-id site-b`; change the output filename to include the site and change repetition number for later runs. Use condition `constrained`, `partition`, or `recovery` as appropriate. The partition and recovery samples use 100 requests per site; all other fixed-load runs use 1,000 per site.

Run the normal condition before impairment. For the constrained condition, use `replace` so this works on the first repetition and after a previous cleanup: `sudo tc qdisc replace dev veth-host root netem delay 50ms loss 1% rate 1mbit` and `sudo ip netns exec kestrel-net tc qdisc replace dev veth-client root netem delay 50ms loss 1% rate 1mbit`. For a partition, replace both profiles with `sudo tc qdisc replace dev veth-host root netem loss 100%` and `sudo ip netns exec kestrel-net tc qdisc replace dev veth-client root netem loss 100%`, run 100 requests, then remove both qdiscs with `sudo tc qdisc del dev veth-host root` and `sudo ip netns exec kestrel-net tc qdisc del dev veth-client root` before running 100 recovery requests. Set `-condition partition` for the first run and `-condition recovery` for the second. Repeat normal, constrained, partition, and recovery at least three times; change the repetition number and output filename for each run. After each run, return ownership of its raw file with `sudo chown "$(id -u):$(id -g)" experiment/raw/<filename>`. Preserve failed rows and explain any exclusion. The runner appends one raw JSONL row per request. After the final run, remove the namespace and veth pair using the Phase 5 cleanup commands.

To measure freshness separately, first remove any `tc` qdiscs so this trial uses the normal link. Start one slow poll run with `-requests 30 -concurrency 1 -rate 1/s`. While it runs, insert a capacity marker from the Phase 6 practice directory with `docker compose -f ../../03-durable-auditable-data/practice/compose.yaml exec db psql -U kestrel -d kestrel -c "INSERT INTO synthetic_records (site_id, category, occurred_at) VALUES ('site-a', 'capacity', DATE '2026-01-15') RETURNING record_id, statement_timestamp();"`. Record the returned timestamp and ID. The pre-insert capacity count is 12; the first raw response with `summary_counts.capacity` equal to 13 is the first summary containing the marker. Subtract the returned insert timestamp from that request's `request_start` plus `elapsed_ms`. Tag this run as a freshness trial and exclude it from the fixed-load latency comparison. After the trial, replace `<marker-id>` with the returned integer ID and run `docker compose -f ../../03-durable-auditable-data/practice/compose.yaml exec db psql -U kestrel -d kestrel -c 'DELETE FROM synthetic_records WHERE record_id = <marker-id>;'`. This restores the fixture count for the next repetition.

Use Python only where it clarifies analysis. A notebook is a document containing code, output, and explanation. Keep the raw data outside the notebook and make the notebook load it by a relative path. Record package versions in a lockfile.

## 4. Analyze results and uncertainty

Plot freshness, p95 latency, success rate, and bytes transferred for each condition. Compare repeated runs; report range or a confidence interval appropriate to the data. Explain warm-up, cache effects, and outliers. If the centralized baseline wins under normal connectivity, report that. If local-first wins only during outages, state the condition and its cost.

Read the evaluation section of one related systems paper after your method is written. Identify what its authors measured that you did not and whether adding that measure would change your conclusion.

## 5. Get bounded usability feedback

Create three short scenarios and ask a qualified reviewer to interpret the output: one useful answer, one stale answer, and one denied answer. Ask what decision they would make, what is unclear, and what information they think is missing. Keep notes without personal details. If this becomes systematic human-subject research or uses real stakeholders as participants, stop and obtain the required ethics review and consent before proceeding.

Report feedback as evidence from the people and context observed, not as proof about all organizations.

## 6. Optional high-level Python, AI/ML, and infrastructure sampler

This is a bounded career sampler, not an AI feature requirement and not deep ML training. Use a public, permitted dataset unrelated to real patients.

### Python and data analysis

Create a separate project and add only the packages used in this sampler:

~~~bash
mkdir -p practice
cd practice
uv init kestrel-ai-sampler
cd kestrel-ai-sampler
uv add numpy pandas matplotlib scikit-learn fastapi uvicorn joblib
~~~

uv creates an isolated Python project and records exact dependencies in uv.lock. Read the matching Python tutorial sections on values, lists/dictionaries, functions, imports, and exceptions before continuing. Add MLflow only for the model-tracking sampler with `uv add mlflow`; it is not needed for the core experiment analysis.

Create `analysis.py` in this sampler project that locates the experiment files with `Path(__file__).resolve().parent.parent / "experiment" / "raw"`, reads the JSONL files, groups rows by condition, prints median latency and success rate for each condition, and saves a plot comparing availability by condition. Treat status 200 as success and include failed rows in the denominator. The result should be a table with one row per condition and a labeled plot with units. Use pandas for the table and matplotlib for the plot. Run it with `uv run python analysis.py`. Keep the raw data unchanged and save both the script and lockfile.

### One simple model and FastAPI

Create `train.py`. Load scikit-learn's built-in Iris dataset, split it into train/test sets with `test_size=0.25`, `random_state=42`, and `stratify=y`, fit `LogisticRegression(max_iter=500, random_state=42)` on the training split only, print a classification report for the held-out test split, and save a bundle containing the fitted model, target names, and `model_version="iris-logreg-v1"` as `model.joblib`. Do not use the test split to fit or tune the model. Expect a report with precision/recall/F1 for three classes; exact values may vary slightly with library versions.

Create `api.py` with a FastAPI app and a Pydantic request model containing exactly four numeric features. Load the `model.joblib` bundle. Add POST `/predict`; it should call the model and return the predicted class name plus model version. Pydantic's four-item constraint should reject a list with the wrong number of values. Start it with:

~~~bash
uv run uvicorn api:app --host 127.0.0.1 --port 8000
~~~

In another terminal, send one valid JSON request and one request with only three features:

~~~bash
curl -i -X POST http://127.0.0.1:8000/predict -H 'Content-Type: application/json' -d '{"features":[5.1,3.5,1.4,0.2]}'
curl -i -X POST http://127.0.0.1:8000/predict -H 'Content-Type: application/json' -d '{"features":[5.1,3.5,1.4]}'
~~~

Expect 200 with a prediction and model version for the first, 422 for the invalid shape. Open `/docs` and `/openapi.json` and identify the generated API description. Compare this with the Phase 0 Go handler: both receive HTTP requests, while FastAPI derives request documentation from Python types.

### Deep learning and computer vision overview

Follow the linked official PyTorch/TorchVision transfer-learning tutorial on its public sample images. Identify the tensor, dataset/DataLoader, model, loss, optimizer, training loop, and evaluation set. Run the tutorial in its hosted notebook or on CPU; do not install a GPU stack for this short sampler or invent an architecture. Explain a false positive, false negative, and one dataset limitation. This is an introduction to deep learning and computer vision, not qualification to build a clinical vision model.

### AI infrastructure at a high level

Draw the lifecycle: versioned data → training job → tracked metrics/artifacts → model registry/version → packaged runtime → inference API → monitoring and rollback. In MLflow, record one experiment run and model version. Read KServe's overview and identify where Kubernetes schedules inference, where model artifacts are loaded, and where health/metrics appear. Label CPU/GPU, batching, queueing, artifact storage, model-serving latency, drift, and rollback on the diagram.

Do not deploy KServe or operate GPUs as a core gate. Explain which operational problem each component solves and what new cost or failure mode it adds. FastAPI, MLflow, and KServe are survey tools here; they do not replace the Go KESTREL core.

### AI security and responsible use

Record data provenance and license, intended use, excluded uses, model version, evaluation population, and privacy exposure. Consider memorization, model extraction, unsafe input, dependency risk, and a model producing confident but wrong outputs. A model prediction is not a clinical decision. Do not connect the sampler to real KESTREL records.

## Evidence gate

Save the question, baseline, manifest, raw runs, analysis source, plots, reviewer notes or reason none were collected, and a limitations section. If you completed the optional AI sampler, also save its public-data source, model card/summary, test metrics, FastAPI contract, and infrastructure diagram. Complete learned.md and rebuild the experiment runner in Kestrel without copying analysis code.

## Read beside the evaluation

For the systems experiment, read *Site Reliability Engineering*, Chapter 6, while defining availability and latency, then Kurose & Ross, 8th ed., §2.4 and §§4.1–4.3 while defining DNS, IP, and the network condition. Once your hypothesis is fixed, choose one primary systems paper with a similar workload and read its evaluation section. Write the paper title, why its workload is comparable, and which methodological difference limits the comparison into your manifest. There is no fixed “best” paper before the question is known.

For the optional Python and AI sampler, follow these exact pieces in order:

| When | Read | Carry this question into the exercise |
|---|---|---|
| Before writing the CSV analysis | Python Tutorial, Chapters 3–5 and 7 | Which values and data structures represent each measurement row? |
| Before exposing the toy classifier | FastAPI tutorial, “First Steps,” “Request Body,” and “Response Model” | How does a type declaration become validation and an API schema? |
| Before running the image-classification example | PyTorch Tutorials, “Transfer Learning for Computer Vision” | Which images train the model, and which unseen images measure it? |
| While recording a model run | MLflow Tracking documentation, “Tracking Experiments” | Which parameters, metrics, and artifacts identify one experiment? |
| During the infrastructure diagram | KServe overview, “Model Serving” | Which parts schedule inference, load a model, and report its health? |

Official material: [Python Tutorial](https://docs.python.org/3/tutorial/), [FastAPI Tutorial](https://fastapi.tiangolo.com/tutorial/), [PyTorch Tutorials](https://docs.pytorch.org/tutorials/), [TorchVision transfer learning](https://docs.pytorch.org/tutorials/beginner/transfer_learning_tutorial), [MLflow tracking](https://mlflow.org/docs/latest/ml/tracking/), and [KServe overview](https://kserve.github.io/website/docs/admin-guide/overview).
