# 00 Before you start

Use Linux with Rust 1.89+, Cargo, Go 1.26.6+, and Python 3.11+. Start with your finished Rust storage engine and the Go module built in the Event streams unit. The audit feed reuses the event decoder and Kafka commit driver from that unit.

- [Rust storage engine](../../03-rust-storage-engine/README.md)
- [Event streams](../../../shared-units/event-streams/README.md)
- [Tenant authorization](../../../shared-units/tenancy-and-abuse-control/README.md)

<!-- continue: ../../03-rust-storage-engine into storage -->
<!-- continue: ../../../shared-units/event-streams into audit -->

## Setup card

From the Blueprint checkout, save its absolute path. In a fresh learner workspace, copy the finished storage engine to `storage/` and the finished Go event-stream module to `audit/`. Copy the source and manifests. Cargo and Go use their own build outputs.

~~~bash
export BLUEPRINT_ROOT="$PWD"
cd "$HOME/switchyard-integrity"
test -f storage/Cargo.toml && test -f audit/go.mod
rustc --version && go version && python3 --version
~~~

The crypto libraries are pinned in the lesson lock files. The first build needs access to the configured registries or a prepared cache. For the live audit check, use a disposable Kafka broker on which the test may create a topic and consumer groups. Use temporary directories for keys, the writer’s log, and the witness state. The two signing roles must use separate keys.

Start with [Keep storage operations inside a tenant namespace](01-scope-keys-to-a-tenant.md).
