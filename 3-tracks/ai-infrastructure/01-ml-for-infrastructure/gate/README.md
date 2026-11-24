# ML for infrastructure gate

From the Blueprint checkout, rebuild the lessons and check the real loopback prediction path.

~~~bash
SWITCHYARD_ML_LIVE=1 python3 scripts/replay_lessons.py 3-tracks/ai-infrastructure/01-ml-for-infrastructure
~~~

From the completed learner directory, run the same gate directly.

~~~bash
SWITCHYARD_ML_LIVE=1 bash "$blueprint/3-tracks/ai-infrastructure/01-ml-for-infrastructure/gate/run.sh" "$PWD"
~~~

The gate uses Linux x86-64, CPython 3.14, and a locked CPU-only PyTorch environment. Initial dependency setup can download packages. With the cache populated, set `UV_OFFLINE=1` for a network-free dependency replay. The live flag starts one loopback port and checks real HTTP requests. Without it, the gate still runs the direct prediction, drift, and rollback checks.

## Pass conditions

1. The pipeline publishes 20 Parquet shards and handles one duplicate and two quarantined rows. The private fixture marker is absent from the published rows and quarantine. A conflicting event ID blocks publication.
2. The dataset contains 640 train, 256 validation, and 384 holdout rows. The late label does not enter training.
3. The model beats the stronger reference by at least 15% on holdout MAE. Each worker pool stays within its 5 ms regression margin. A baseline-quality challenger leaves the active alias unchanged.
4. The endpoint matches the offline prediction and refuses a target field in the request. A changed weights file fails its digest check.
5. The steady fixture window leaves the drift alert clear. The shifted window raises it. Moving the alias back restores the previous version and prediction on the same endpoint.

See the [reference results](../evidence/README.md).

## Run the lab manually

Run from the learner directory with the files from the lessons. Create a fresh area for each run.

~~~bash
run=$(mktemp -d)
uv run --locked python -m ml_lab fixture "$run/jobs.jsonl"
uv run --locked python -m ml_lab ingest "$run/jobs.jsonl" "$run/dataset"
champion=$(uv run --locked python -m ml_lab fit "$run/dataset" "$run/registry" --kind median | python3 -c 'import json,sys; print(json.load(sys.stdin)["artifact"])')
candidate=$(uv run --locked python -m ml_lab fit "$run/dataset" "$run/registry" --kind candidate | python3 -c 'import json,sys; print(json.load(sys.stdin)["artifact"])')
uv run --locked python -m ml_lab bootstrap "$run/registry" "$champion"
uv run --locked python -m ml_lab promote "$run/registry" "$candidate" --generation 1
uv run --locked python -m ml_lab report "$run/registry" "$run/dataset"
uv run --locked python -m ml_lab serve "$run/registry" --port 8080
~~~

In a second shell, send a request with admission-time values. Use the same registry directory printed by `printf '%s\n' "$run/registry"` in the first shell if you need to copy its path.

~~~bash
curl --max-time 4 --json '{"work_units":200,"queue_depth":3,"pool":"slow"}' http://127.0.0.1:8080/predict
uv run --locked python -m ml_lab rollback /path/to/run/registry --generation 2
curl --max-time 4 --json '{"work_units":200,"queue_depth":3,"pool":"slow"}' http://127.0.0.1:8080/predict
~~~

The second response identifies the original artifact. Use `state` to confirm generation 3. Stop the loopback server with Ctrl+C.
