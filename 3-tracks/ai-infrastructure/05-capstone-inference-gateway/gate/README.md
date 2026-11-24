# Inference gateway capstone gate

From the Blueprint checkout, rebuild the Rust gateway prerequisite and capstone in a fresh directory.

~~~bash
SWITCHYARD_GATEWAY_LIVE=1 SWITCHYARD_CAPSTONE_LIVE=1 \
  python3 scripts/replay_lessons.py --keep 3-tracks/ai-infrastructure/05-capstone-inference-gateway
~~~

From the completed learner directory, run the capstone checks directly.

~~~bash
SWITCHYARD_CAPSTONE_LIVE=1 bash "$blueprint/3-tracks/ai-infrastructure/05-capstone-inference-gateway/gate/run.sh" "$PWD"
~~~

The gate requires formatting, Clippy, the Rust unit tests in both decoder builds, and the Python benchmark tests. The live flag adds the two sets of socket tests. The gate uses fixtures, so it can run before acquiring model assets. It requires the same API and stream outcome checks in both variants. The early-EOF benchmark case must contribute zero completed tokens.

## Reproduce the model matrix

Use the CPU llama.cpp image and [Qwen publisher GGUF](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/blob/main/qwen2.5-0.5b-instruct-q4_k_m.gguf) pinned by [the serving lesson](../../02-serving-and-scaling-models/lessons/02-a-real-model-and-honest-streaming-measurements.md). Load the matching image into the local Docker daemon. The runner verifies the file digest, mounts the model read-only, and removes the container it started. Use a fresh output path for every run.

~~~bash
bash bench/build.sh ./dist
python3 bench/local_model.py /path/to/model.gguf ./dist/gateway-eager ./dist/gateway-typed ./model-run
~~~

The bounded runs use eight requests per block for each variant at concurrency one and two, with two blocks per variant. Both gateways use the same model server, request payload, and slot limit. The benchmark waits for readiness and warms each gateway before recording samples.

If the matching server is already running on loopback, run `bench/matrix.py` with the model origin and the two binary paths instead. Run `bench/sdk_smoke.py` against a gateway origin with a Python environment containing OpenAI SDK 3.57.0 and its local bearer credential in `GATEWAY_A_TOKEN`.

## Reproduce the CPU flame graphs

Use the same release binaries and repeat equal input lengths. Run the profiler separately from the whole-model matrix.

~~~bash
./dist/profile-eager 180000 ./flame-before.svg
./dist/profile-typed 180000 ./flame-after.svg
for variant in eager typed typed eager; do ./dist/profile-$variant 50000 -; done
~~~

The first two commands sample actual user-space CPU stacks. The loop measures elapsed time on an identical unprofiled replay. The [evidence report](../evidence/README.md) records both.

## Export for review

From the source directory printed by the clean replay, write the source package to a new path. The exporter includes source, tests, dependency lock, decision record, and reference evidence.

~~~bash
bash "$blueprint/3-tracks/ai-infrastructure/05-capstone-inference-gateway/gate/export.sh" "$PWD" "$PWD/switchyard-inference-capstone.tar.gz"
tar -tzf "$PWD/switchyard-inference-capstone.tar.gz"
~~~

Use your reviewed package as the basis for the public repository or workplace deployment. The reference package is built locally. The gateway uses local fixture credentials and a per-process quota. Deployment onto multiple hosts needs the identity, transport, and shared allowance decisions described in the ADR.
