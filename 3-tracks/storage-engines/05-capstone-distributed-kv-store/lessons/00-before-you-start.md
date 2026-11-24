# 00 Before you start

Use Linux with Go 1.26.6+, Rust 1.89+, Cargo, Python 3.11+, JDK 21, and curl. Start with the completed Consensus in depth workspace and the storage crate from Integrity and encryption. Keep your lab directories on a local filesystem.

- [Consensus in depth](../../02-consensus-in-depth/README.md)
- [Integrity and encryption](../../04-integrity-and-encryption/README.md)

<!-- continue: ../../02-consensus-in-depth -->
<!-- continue: ../../04-integrity-and-encryption into integrity -->
<!-- run: mkdir -p storage/klog && cp integrity/storage/Cargo.toml integrity/storage/Cargo.lock storage/ && cp -R integrity/storage/src storage/ && cp integrity/storage/klog/Cargo.toml integrity/storage/klog/Cargo.lock storage/klog/ && cp -R integrity/storage/klog/src storage/klog/ -->

## Setup card

From the Blueprint checkout, save its absolute path. Work in a copy of the Go consensus project. Copy the Rust engine’s manifest, lockfile, and source into `storage/` there, with its local `klog` crate under `storage/klog/`. Leave the consensus writer’s original `klog/` crate at the project root.

~~~bash
export BLUEPRINT_ROOT="$PWD"
cd "$HOME/switchyard-kv-capstone"
test -f go.mod && test -f klog/Cargo.toml && test -f storage/klog/Cargo.toml
go version && rustc --version && python3 --version && java -version && javac -version
~~~

The first build fetches pinned dependencies. The test harness creates its own temporary directories, loopback listeners, Unix sockets, and credential files. The full profiling run samples the optimized Rust process. Benchmarking uses the public client API on localhost.

Start with [Define the replicated client contract](01-define-the-replicated-client-contract.md).
