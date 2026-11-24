# Programmable edge proxy gate

Run with Linux, Rust and Cargo 1.94 or newer, rustfmt, Clippy, Go 1.26 or newer, a C compiler for the Go race detector, Bash, and Python 3. Start in the assembled learner workspace.

~~~bash
module="$BLUEPRINT_ROOT/3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy"
bash "$module/gate/run.sh" "$PWD"
~~~

| Check | Required evidence |
|---|---|
| Handoff and rollback | A held response finishes at the original origin. A separate request sent after the acknowledgement reaches the new origin before the held response is released. Verify both directions. |
| Paced requests | All 240 scheduled requests return correct HTTP/1.1 payloads. The origin matches the measured publication windows. The unhealthy candidate leaves the preceding generation and route active. |
| Negative control | A disposable build fails the held request with HTTP 503 when its route changes. The handoff test detects that exact interruption. |
| Standalone export | Locked source builds in a fresh extraction and passes its own portable gate. |

The portable gate runs the control-plane tests with Go's race detector. It uses TCP loopback and Unix sockets. The Docker benchmark and CPU profile are separate commands. [Benchmark procedure](../lessons/03-measure-throughput-and-memory.md) · [Profile procedure](../lessons/04-profile-the-origin-uri-path.md)

## Export and verify

~~~bash
release=$(mktemp -d)
bash "$module/gate/export.sh" "$PWD" "$release/switchyard-edge-capstone.tar.gz"
tar -xzf "$release/switchyard-edge-capstone.tar.gz" -C "$release"
cd "$release/switchyard-edge-capstone"
bash gate/run.sh "$PWD"
~~~

The export includes locked source, the runnable gate, benchmark and profile scripts, a decision record, and the reference captures. [Evidence and release archive](../evidence/README.md)
