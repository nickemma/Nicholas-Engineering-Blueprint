# 00 Before you start

> The proxy's control plane · Builds on A Rust edge proxy

Use Linux with Rust and Cargo 1.94 or later, rustfmt, Clippy, Go 1.26 or later, Python 3, and Bash. The portable checks need TCP loopback and Unix domain sockets. For the two live profiles, also use Docker. The OpenBao fixture uses curl and OpenSSL on the host. The XDP profile requires a kernel and daemon that permit attaching a BPF program inside a disposable container.

Start with the workspace built in Part 02. The replay builds that part first, then adds a new `managed` mode to its Rust binary. Keep the Blueprint checkout path in `BLUEPRINT_ROOT`.

<!-- continue: ../../02-rust-edge-proxy -->

To assemble a fresh workspace automatically, run this from the Blueprint checkout and use the scratch path it prints.

~~~bash
export BLUEPRINT_ROOT="$PWD"
python3 scripts/replay_lessons.py --keep 3-tracks/cloud-and-network/02-rust-edge-proxy
~~~

Draw two separate paths. Application requests go directly to the Rust listener. Management requests go from the Go controller through the Go sidecar and then over a private Unix socket to Rust. Controller, sidecar, and data-plane process use the lab's shared local user. Use a short private directory for the socket.

The Rust process starts with generation zero and two configured origin slots. It keeps the applied generation in memory. Retain the desired configuration in the controller or your lab runbook and republish it after a proxy restart.

Continue to [Push a versioned route snapshot](01-push-a-versioned-snapshot.md).
