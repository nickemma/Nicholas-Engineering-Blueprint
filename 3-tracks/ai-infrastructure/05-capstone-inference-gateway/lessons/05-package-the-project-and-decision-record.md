# 05 Package the project and decision record

> Inference gateway capstone · Week 2

## The problem

Measurements depend on the code, dependencies, and workload that produced them. A reviewer needs a way to reproduce the build and understand the decisions.

## The mental model

~~~text
source and lock + benchmark recipe + evidence + decision record
    → shareable project with reproduction commands
~~~

## Build it

### Give the standalone project an entry point

Document setup, supported requests, reproducible analysis, and the reference artifacts.

Create or update `README.md`.

<!-- file: README.md -->
~~~~text
# Switchyard inference gateway capstone

A bounded Rust HTTP/1 gateway for local streaming chat inference. It supports bearer-authenticated model discovery and streaming text chat for the `switchyard` alias. Each request reserves prompt tokens plus the requested output limit. The streaming body owns the model response and active slot.

## Run locally

Use Linux and Rust 1.94 or later with Cargo, rustfmt, Clippy, Bash, and Python 3. The real-model benchmark uses Docker. Use the llama.cpp server image and the Qwen GGUF digest pinned in `bench/local_model.py`. The fixture gate and parser replay can run without the GGUF.

~~~bash
cargo test --locked
cargo test --locked --test loopback -- --ignored --nocapture
(cd bench && python3 -m unittest -v)
~~~

For an existing llama.cpp server on loopback, set `GATEWAY_MODEL_ADDR` to its IP and port. Serve the model as `switchyard`. Generate two 48-character hex fixture credentials and set `GATEWAY_A_TOKEN` and `GATEWAY_B_TOKEN`. Set `GATEWAY_LISTEN` to a loopback address or use its default, `127.0.0.1:8080`.

~~~bash
cargo run --locked --bin switchyard-inference
~~~

Use the bearer credential with `GET /v1/models` and `POST /v1/chat/completions`. Chat requests supply `model`, text `messages`, `stream: true`, and one of `max_completion_tokens` or `max_tokens`. Optional temperature is zero. Optional `stream_options.include_usage` controls whether usage reaches the caller. Upstream usage remains mandatory for completion. The scope is one streamed text choice.

## Reproduce the measurements

~~~bash
bash bench/build.sh ./dist
python3 bench/local_model.py /path/to/model.gguf ./dist/gateway-eager ./dist/gateway-typed ./model-run
./dist/profile-eager 180000 ./flame-before.svg
./dist/profile-typed 180000 ./flame-after.svg
for variant in eager typed typed eager; do ./dist/profile-$variant 50000 -; done
~~~

The model matrix uses two blocks per variant and concurrency, in A/B/B/A order. The parser replay uses the same input and release settings in each build. The `eager-json` feature reproduces the baseline. The profiling feature enables the user-space CPU sampler and is optional for normal operation.

See [Design decisions](ADR.md) and the [reference evidence](evidence/README.md).
~~~~

### Record the design decisions

Explain the trade-offs behind capacity, cancellation, completion, and the evaluation scope.

Create or update `ADR.md`.

<!-- file: ADR.md -->
~~~text
# ADR · Keep generation ownership and benchmark evidence explicit

## Context

An inference gateway needs to account for work before it reaches a model, preserve completed-token evidence under failures, and release upstream resources when clients leave. A single parser speedup can be hidden by inference time. The capstone uses the same model, prompts, and connection policy for both whole-request variants and a fixed replay to isolate parser work.

## Decisions

- **Streaming profile.** Expose authenticated `GET /v1/models` and `POST /v1/chat/completions` for a fixed text-chat model alias. Translate either output-limit field to the model server's `max_tokens`. Check usage internally even when the client suppresses its downstream frame.
- **Ownership.** Acquire an admission permit before parsing and tokenization. Move it into the stream alongside the upstream response. Start HTTP/1 connections with fixed header and exchange deadlines. Closing the client drops the upstream transport and frees the permit.
- **Tenant capacity.** Use fixed, generated identities and weighted per-process buckets. Charge prompt tokens plus the requested output budget once generation is attempted. Keep reservations on failure and cancellation. This bounds admitted generation in one process and conservatively overestimates actual generated work.
- **Completion.** Require a valid content event, matching prompt usage, bounded completion usage, and the terminal marker. Malformed or truncated streams carry a terminal SSE error and contribute zero valid tokens to throughput.
- **Parsing.** Retain the framing state machine. Deserialize typed JSON once and preserve the validated single-line body when possible. Compact validated multiline JSON before writing it downstream. Keep the eager tree-copy and serialization version behind a benchmark feature.
- **Measurement.** Compare paired gateway builds on the same pinned CPU model with fresh gateway processes, warmup excluded, fixed prompts, and A/B/B/A blocks at concurrency one and two. Capture every outcome. Profile the same fixed parser input separately with sampled CPU stacks.

## Consequences

A POST can time out after headers have already been committed. Use the final event to interpret it. Model-side batching and decoding contribute to client latency. The parser replay and model run provide separate evidence. The short two-block matrix characterizes this host and workload.

The executable binds to loopback and the model is chosen by the operator. A deployment across hosts needs the transport and identity boundary from the core and shared units. Separate replica processes also need a shared budget or explicitly partitioned allowance. Generation reclaim on a model host needs its own runtime evidence.
~~~

### Keep local outputs out of a public checkout

Exclude compiled outputs, caches, model weights, and environment files.

Create or update `.gitignore`.

<!-- file: .gitignore -->
~~~text
/target/
/dist/
/model-run/
__pycache__/
*.gguf
*.env
~~~

## Check it

Export the code and evidence without compiled binaries, working weights, credential files, or repository internals. Review the archive manifest before publishing or deploying the project. Follow the [gate guide](../gate/README.md) to produce the archive.

<!-- run: test -s README.md && test -s ADR.md && test -s .gitignore -->
