# 00 Before you start

> Programmable edge proxy capstone · Builds on the Cloud and network track

Use Linux with Rust and Cargo 1.94 or later, rustfmt, Clippy, Go 1.26 or later, a C compiler for the Go race detector, Bash, Python 3, and GNU tar. The portable gate uses local TCP and Unix sockets and Linux process RSS data. The matched Envoy run also needs Linux Docker with host networking. The earlier networking labs explain the measurement setup. [Networking in depth](../../01-networking-in-depth/README.md) · [Rust proxy](../../02-rust-edge-proxy/README.md) · [Control plane](../../03-proxy-control-plane/README.md)

<!-- continue: ../../03-proxy-control-plane -->

Continue in the Part 03 learner workspace. If you need a fresh one, run this from the Blueprint checkout and enter the scratch directory it prints.

~~~bash
export BLUEPRINT_ROOT="$PWD"
python3 scripts/replay_lessons.py --keep 3-tracks/cloud-and-network/03-proxy-control-plane
~~~

The capstone fixture starts the real Rust proxy and the Go mTLS sidecar with temporary keys and two instrumented origins. Keep the Blueprint checkout path available in `BLUEPRINT_ROOT` until you export the standalone project. Use fresh output paths for each capture.

Continue to [Define the reload contract](01-define-the-reload-contract.md).
