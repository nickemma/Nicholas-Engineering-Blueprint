# Core 06 gate

Run the gate from the Blueprint repository against the finished course checkout. The checkout contains `wire/control`, `wire/klog`, and the scripts from lesson 14.

~~~bash
bash 2-core/06-linux-networking-and-profiling/gate/run.sh /path/to/core-06-checkout
~~~

The native run uses Linux, Go, Rust with Rustfmt and Clippy, a C compiler and `ar`, and Python 3. It builds both Go checksum variants. For each, it tests real TCP and Unix sockets, split frames, corrupt-frame refusal, the HTTP body bound, and the trace parent and child.

## Measure the fix

The extended run uses Docker with NET_ADMIN inside its disposable lab container, Linux `taskset`, the Core 02 `kload` executable, Perl, and the FlameGraph scripts from lesson 03. Build the image from `wire/tools` as in lesson 10. The default image name is `switchyard-wire-tools:lab`; use `WIRE_NET_IMAGE` for an equivalent image. Set `WIRE_PROFILE_OUT` to a new directory.

~~~bash
export KLOAD=/path/to/kload
export FLAMEGRAPH_DIR=/path/to/FlameGraph
export WIRE_PROFILE_OUT="$(mktemp -d)/wire-profile"
bash 2-core/06-linux-networking-and-profiling/gate/run.sh /path/to/core-06-checkout --extended
~~~

The run requires successful replies at the offered rate, actual qdisc drops, a running CPU competitor, and a baseline CPU profile that identifies the checksum. It stores both profiles and flame graphs. The p99 improvement check requires a confidence interval below zero for fast minus slow.

Host contention and network variance can change the result. The `--pilot` mode of `wire/profile_gate.py` lets you compare rates before fixing an experiment configuration. Keep the same settings for both builds and report an interval that includes zero as unresolved.

See the [evidence](../evidence/README.md) for the observed run and its settings.
