# 00 Before you start

> Inference gateway capstone · Setup

Continue from [A Rust inference gateway](../../03-rust-inference-gateway/README.md). The capstone keeps the parser, tokenizer client, quota, and HTTP deadline from that build. It adds a documented chat API profile, paired benchmarks, and a source package that can be reviewed independently.

<!-- continue: ../../03-rust-inference-gateway -->

Use Linux, Rust 1.94 or later, Cargo, rustfmt, Clippy, Bash, and Python 3. The loopback correctness gate uses a local model fixture. The real model benchmark additionally uses Docker and the Qwen/llama.cpp assets pinned in the serving lesson. [CPU serving setup](../../02-serving-and-scaling-models/lessons/02-a-real-model-and-honest-streaming-measurements.md)

From the Blueprint root, replay the prerequisite and keep its scratch directory.

~~~bash
export blueprint="$PWD"
python3 scripts/replay_lessons.py --keep 3-tracks/ai-infrastructure/03-rust-inference-gateway
~~~

Enter the directory printed by the replay. Keep one copy per experiment if you change the workload.
